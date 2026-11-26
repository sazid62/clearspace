//! How slimming works on macOS (see `slim.rs` for what it is).
//!
//! An app's code signature seals its files, and macOS refuses or warns about an app whose seal is
//! broken. Only files the signature treats as code (each signed on its own, per architecture) can
//! lose their Intel half without breaking it. So the work is done on a copy, the copy's signature
//! is verified, and only then does it take the app's place. The original goes to the Trash.

use super::fsx;
use super::slim::{Event, SlimApp};
use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};

const FAT_MAGIC: u32 = 0xCAFE_BABE;
const FAT_MAGIC_64: u32 = 0xCAFE_BABF;
const CPU_ARM64: u32 = 0x0100_000C;
/// A 64-bit Mach-O file, and a static library, as their first bytes.
const MACH_O_64: [u8; 4] = [0xCF, 0xFA, 0xED, 0xFE];
const ARCHIVE: &[u8; 8] = b"!<arch>\n";

#[derive(Debug, Clone, PartialEq)]
struct Slice {
    cpu: u32,
    offset: u64,
    size: u64,
}

/// The architectures inside a universal file; None for anything else. Java class files start
/// with the same four bytes, so the rest of the header has to make sense too.
fn slices(path: &str) -> Option<Vec<Slice>> {
    let mut file = std::fs::File::open(path).ok()?;
    let length = file.metadata().ok()?.len();
    let mut head = [0u8; 8];
    file.read_exact(&mut head).ok()?;
    let magic = u32::from_be_bytes(head[..4].try_into().ok()?);
    let count = u32::from_be_bytes(head[4..].try_into().ok()?);
    if !(magic == FAT_MAGIC || magic == FAT_MAGIC_64) || count == 0 || count > 8 {
        return None;
    }
    let wide = magic == FAT_MAGIC_64;
    let mut out = vec![];
    for _ in 0..count {
        let mut entry = [0u8; 32];
        let entry = &mut entry[..if wide { 32 } else { 20 }];
        file.read_exact(entry).ok()?;
        let word = |at: usize| u32::from_be_bytes(entry[at..at + 4].try_into().unwrap()) as u64;
        let long = |at: usize| u64::from_be_bytes(entry[at..at + 8].try_into().unwrap());
        let (offset, size) = if wide { (long(8), long(16)) } else { (word(8), word(12)) };
        if size < 8 || offset.checked_add(size)? > length {
            return None;
        }
        out.push(Slice { cpu: word(0) as u32, offset, size });
    }
    Some(out)
}

/// The Apple silicon slice of a universal file that also holds something else, and the bytes
/// that go when only that slice is kept.
fn removable(path: &str) -> Option<(Slice, u64)> {
    let all = slices(path)?;
    let mut arm = all.iter().filter(|s| s.cpu == CPU_ARM64);
    let (keep, None) = (arm.next()?, arm.next()) else { return None };
    if all.len() < 2 {
        return None;
    }
    let length = fsx::info(path)?.len();
    Some((keep.clone(), length.saturating_sub(keep.size)))
}

/// Replaces a universal file with its Apple silicon slice alone. Returns the bytes saved.
fn thin(path: &str) -> std::io::Result<u64> {
    let Some((keep, saved)) = removable(path) else { return Ok(0) };
    let mut source = std::fs::File::open(path)?;
    source.seek(SeekFrom::Start(keep.offset))?;
    let mut start = [0u8; 8];
    source.read_exact(&mut start)?;
    if start[..4] != MACH_O_64 && &start != ARCHIVE {
        return Ok(0); // not code after all
    }
    source.seek(SeekFrom::Start(keep.offset))?;
    let partial = format!("{path}.clearspace-thin");
    let mut target = std::fs::File::create(&partial)?;
    let copied = std::io::copy(&mut source.by_ref().take(keep.size), &mut target)?;
    drop(target);
    if copied != keep.size {
        let _ = std::fs::remove_file(&partial);
        return Err(std::io::Error::other("short read"));
    }
    std::fs::set_permissions(&partial, std::fs::metadata(path)?.permissions())?;
    std::fs::rename(&partial, path)?;
    Ok(saved)
}

/// What each code signature inside a bundle seals, read once.
#[derive(Default)]
struct Seals {
    /// Folder holding `_CodeSignature` → the sealed files (`files2` of CodeResources), if any.
    read: HashMap<String, Option<plist::Dictionary>>,
}

impl Seals {
    fn files(&mut self, dir: &str) -> Option<&plist::Dictionary> {
        self.read
            .entry(dir.to_string())
            .or_insert_with(|| {
                let seal = plist::Value::from_file(fsx::join(dir, "_CodeSignature/CodeResources")).ok()?;
                seal.into_dictionary()?.remove("files2")?.into_dictionary()
            })
            .as_ref()
    }

    /// True when `path` may lose its Intel half without breaking a seal: the nearest signature
    /// around it treats it as code of its own (or it is that bundle's main program), and no
    /// signature further out sealed it byte for byte as a plain resource.
    fn may_thin(&mut self, path: &str, top: &str) -> bool {
        let mut dir = fsx::parent(path);
        let mut nearest = true;
        let mut allowed = false;
        while fsx::within(&dir, top) {
            let relative = path[dir.len() + 1..].to_string();
            if let Some(files) = self.files(&dir) {
                let entry = files.get(&relative);
                let as_code = entry.is_some_and(|e| e.as_dictionary().is_some_and(|d| d.contains_key("cdhash")));
                if nearest {
                    allowed = if entry.is_some() { as_code } else { main_programs(&dir).iter().any(|p| p == path) };
                    nearest = false;
                } else if entry.is_some() && !as_code {
                    return false;
                }
                if !allowed {
                    return false;
                }
            }
            dir = fsx::parent(&dir);
        }
        allowed
    }
}

/// Where a bundle's main program can be, given the folder its signature lives in (`Contents`
/// for apps, the version folder for frameworks).
fn main_programs(seal_dir: &str) -> Vec<String> {
    ["Info.plist", "Resources/Info.plist"]
        .iter()
        .filter_map(|rel| plist::Value::from_file(fsx::join(seal_dir, rel)).ok())
        .filter_map(|info| info.as_dictionary()?.get("CFBundleExecutable")?.as_string().map(String::from))
        .flat_map(|name| [fsx::join(seal_dir, &format!("MacOS/{name}")), fsx::join(seal_dir, &name)])
        .collect()
}

/// Every universal file in the bundle that may be thinned, with the bytes each would give back.
fn thinnable(bundle: &str) -> Vec<(String, u64)> {
    let mut seals = Seals::default();
    let mut out = vec![];
    let mut pending = vec![bundle.to_string()];
    while let Some(dir) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else { continue };
            let path = entry.path().to_string_lossy().into_owned();
            if kind.is_dir() {
                pending.push(path);
            } else if kind.is_file() {
                if let Some((_, saved)) = removable(&path) {
                    if saved > 0 && seals.may_thin(&path, bundle) {
                        out.push((path, saved));
                    }
                }
            }
        }
    }
    out
}

/// Only Apple silicon Macs have an Intel half to spare.
pub fn supported() -> bool {
    let mut value: i32 = 0;
    let mut size = std::mem::size_of::<i32>();
    let name = c"hw.optional.arm64";
    let ok = unsafe { libc::sysctlbyname(name.as_ptr(), (&mut value as *mut i32).cast(), &mut size, std::ptr::null_mut(), 0) } == 0;
    ok && value == 1
}

/// App Store apps are updated piece by piece against what Apple delivered, so they stay whole.
fn from_app_store(bundle: &str) -> bool {
    fsx::exists(&fsx::join(bundle, "Contents/_MASReceipt"))
}

fn writable(path: &str) -> bool {
    let Ok(c) = std::ffi::CString::new(path) else { return false };
    unsafe { libc::access(c.as_ptr(), libc::W_OK) == 0 }
}

/// Apps with Intel code worth removing (1 MB and up), as they are found.
pub fn list(send: &dyn Fn(Event)) {
    if supported() {
        for app in super::apps::mac::bundles() {
            if from_app_store(&app) || !writable(&app) || !writable(&fsx::parent(&app)) {
                continue;
            }
            let files = thinnable(&app);
            let intel: u64 = files.iter().map(|(_, saved)| saved).sum();
            if intel >= 1 << 20 {
                let name = fsx::name(&app);
                send(Event::Found { app: SlimApp { name: name.strip_suffix(".app").unwrap_or(&name).to_string(), id: app, intel, files: files.len() } });
            }
        }
    }
    send(Event::Listed);
}

/// How well a signature checks out.
#[derive(Clone, Copy, Debug, PartialEq, PartialOrd)]
enum Seal {
    Broken,
    /// Valid, though the strict check objects to something (a stray Finder attribute, say).
    Valid,
    Strict,
}

fn seal_of(bundle: &str) -> Seal {
    let verify = |strict: bool| {
        let mut args = vec!["--verify", "--deep"];
        if strict {
            args.push("--strict");
        }
        args.push(bundle);
        std::process::Command::new("/usr/bin/codesign").args(args).output().is_ok_and(|o| o.status.success())
    };
    if verify(true) {
        Seal::Strict
    } else if verify(false) {
        Seal::Valid
    } else {
        Seal::Broken
    }
}

/// Whether Gatekeeper would let the app open (it checks the signature against notarization).
fn gatekeeper_accepts(bundle: &str) -> bool {
    std::process::Command::new("/usr/sbin/spctl").args(["--assess", "--type", "execute", bundle]).output().is_ok_and(|o| o.status.success())
}

/// True when the bundle's main program still runs on Apple silicon.
fn runs_on_arm(bundle: &str) -> bool {
    main_programs(&fsx::join(bundle, "Contents")).iter().any(|program| {
        let mut head = [0u8; 8];
        let read = std::fs::File::open(program).and_then(|mut f| f.read_exact(&mut head)).is_ok();
        read && head[..4] == MACH_O_64 && u32::from_le_bytes(head[4..].try_into().unwrap()) == CPU_ARM64
    })
}

/// Slims one app. Returns the bytes its Intel half took.
pub fn slim(bundle: &str) -> Result<u64, String> {
    if !supported() {
        return Err("Only Apple silicon Macs have Intel code to spare.".into());
    }
    if from_app_store(bundle) {
        return Err("It came from the App Store, which updates it against what Apple delivered.".into());
    }
    if !super::mac::pids_inside(bundle).is_empty() {
        return Err("It's running. Quit it, then try again.".into());
    }
    let before = seal_of(bundle);
    if before == Seal::Broken {
        return Err("Its signature doesn't check out as it is, so it's left alone.".into());
    }
    let work = fsx::join(&fsx::parent(bundle), &format!(".clearspace-slim-{}", std::process::id()));
    let copy = fsx::join(&work, &fsx::name(bundle));
    let _ = std::fs::remove_dir_all(&work);
    std::fs::create_dir_all(&work).map_err(|e| format!("Couldn't make room beside it: {e}"))?;
    let result = slim_copy(bundle, &copy, before);
    let _ = std::fs::remove_dir_all(&work);
    result
}

/// The slimmed copy must check out exactly as well as the original did.
fn slim_copy(bundle: &str, copy: &str, before: Seal) -> Result<u64, String> {
    // -c clones on APFS, so the copy takes no space until files change; -p keeps dates and flags.
    let copied = std::process::Command::new("/bin/cp").args(["-cRp", bundle, copy]).output().map_err(|e| e.to_string())?;
    if !copied.status.success() {
        return Err(format!("Couldn't copy it: {}", String::from_utf8_lossy(&copied.stderr).trim()));
    }
    let mut freed = 0;
    for (path, _) in thinnable(copy) {
        freed += thin(&path).map_err(|e| format!("Couldn't rewrite {}: {e}", fsx::name(&path)))?;
    }
    if freed == 0 {
        return Err("Nothing in it could be slimmed safely.".into());
    }
    if seal_of(copy) < before || !runs_on_arm(copy) || (gatekeeper_accepts(bundle) && !gatekeeper_accepts(copy)) {
        return Err("Its signature wouldn't survive, so it was left as it is.".into());
    }
    super::remove::remove(bundle, super::remove::Mode::Trash).map_err(|f| format!("Couldn't move the original to the Trash: {}", f.message))?;
    std::fs::rename(copy, bundle).map_err(|e| format!("The original is in the Trash, but the slimmed copy couldn't take its place ({e}). Put the original back from the Trash."))?;
    Ok(freed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fat(parts: &[(u32, &[u8])]) -> Vec<u8> {
        let mut out = FAT_MAGIC.to_be_bytes().to_vec();
        out.extend((parts.len() as u32).to_be_bytes());
        let mut offset = 8 + 20 * parts.len() as u32;
        for (cpu, data) in parts {
            for word in [*cpu, 0, offset, data.len() as u32, 0] {
                out.extend(word.to_be_bytes());
            }
            offset += data.len() as u32;
        }
        parts.iter().for_each(|(_, data)| out.extend(*data));
        out
    }

    fn program(marker: u8) -> Vec<u8> {
        let mut out = MACH_O_64.to_vec();
        out.extend(CPU_ARM64.to_le_bytes());
        out.extend([marker; 40]);
        out
    }

    fn folder(name: &str) -> String {
        let dir = std::env::temp_dir().join(format!("cs-slim-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.to_string_lossy().into_owned()
    }

    #[test]
    fn keeps_only_the_apple_silicon_slice() {
        let dir = folder("thin");
        let path = fsx::join(&dir, "tool");
        let (arm, intel) = (program(1), vec![9u8; 100]);
        std::fs::write(&path, fat(&[(0x0100_0007, &intel), (CPU_ARM64, &arm)])).unwrap();
        assert_eq!(slices(&path).unwrap().len(), 2);
        assert_eq!(thin(&path).unwrap(), 8 + 40 + 100);
        assert_eq!(std::fs::read(&path).unwrap(), arm);
        // Already thin: nothing to do.
        assert_eq!(thin(&path).unwrap(), 0);
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn leaves_other_files_alone() {
        let dir = folder("other");
        let class = fsx::join(&dir, "Main.class");
        // A Java class: same first four bytes, then the version (52) where the count would be.
        std::fs::write(&class, [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 52, 0, 1, 2, 3]).unwrap();
        assert_eq!(slices(&class), None);
        let intel_only = fsx::join(&dir, "intel");
        std::fs::write(&intel_only, fat(&[(0x0100_0007, &[9u8; 64]), (7, &[8u8; 64])])).unwrap();
        assert_eq!(removable(&intel_only), None);
        let truncated = fsx::join(&dir, "cut");
        let mut bytes = fat(&[(0x0100_0007, &[9u8; 64]), (CPU_ARM64, &program(1))]);
        bytes.truncate(bytes.len() - 10);
        std::fs::write(&truncated, bytes).unwrap();
        assert_eq!(slices(&truncated), None);
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Dev aid: `APP=/path/to/a/copy.app cargo test slims_a_copy -- --ignored --nocapture` slims
    /// the copy in place and says whether its signature survived.
    #[test]
    #[ignore]
    fn slims_a_copy() {
        let app = std::env::var("APP").expect("APP=<a copy of an app>");
        let files = thinnable(&app);
        let expected: u64 = files.iter().map(|(_, saved)| saved).sum();
        let freed: u64 = files.iter().map(|(path, _)| thin(path).unwrap()).sum();
        println!("{} files, {} MB, signature: {:?}, Gatekeeper accepts: {}, runs on Apple silicon: {}", files.len(), freed >> 20, seal_of(&app), gatekeeper_accepts(&app), runs_on_arm(&app));
        assert_eq!(freed, expected);
    }

    fn seal(dir: &str, files: &[(&str, bool)]) {
        let mut sealed = plist::Dictionary::new();
        for (path, code) in files {
            let mut entry = plist::Dictionary::new();
            entry.insert(if *code { "cdhash" } else { "hash2" }.into(), plist::Value::Data(vec![1, 2, 3]));
            sealed.insert((*path).into(), plist::Value::Dictionary(entry));
        }
        let mut root = plist::Dictionary::new();
        root.insert("files2".into(), plist::Value::Dictionary(sealed));
        std::fs::create_dir_all(fsx::join(dir, "_CodeSignature")).unwrap();
        plist::Value::Dictionary(root).to_file_xml(fsx::join(dir, "_CodeSignature/CodeResources")).unwrap();
    }

    #[test]
    fn thins_only_what_the_signatures_treat_as_code() {
        let app = fsx::join(&folder("seal"), "Demo.app");
        let contents = fsx::join(&app, "Contents");
        let universal = fat(&[(0x0100_0007, &[9u8; 64]), (CPU_ARM64, &program(1))]);
        let inner = fsx::join(&contents, "Resources/Agent.app/Contents");
        for rel in ["MacOS/Demo", "MacOS/helper", "Frameworks/libcode.dylib", "Resources/plain.dylib", "Resources/Agent.app/Contents/MacOS/Agent"] {
            let path = fsx::join(&contents, rel);
            std::fs::create_dir_all(fsx::parent(&path)).unwrap();
            std::fs::write(&path, &universal).unwrap();
        }
        let info = |dir: &str, name: &str| {
            let mut d = plist::Dictionary::new();
            d.insert("CFBundleExecutable".into(), name.into());
            plist::Value::Dictionary(d).to_file_xml(fsx::join(dir, "Info.plist")).unwrap();
        };
        info(&contents, "Demo");
        info(&inner, "Agent");
        // The outer signature seals the agent's program byte for byte, as Chrome's updater does.
        seal(&contents, &[("MacOS/helper", true), ("Frameworks/libcode.dylib", true), ("Resources/plain.dylib", false), ("Resources/Agent.app/Contents/MacOS/Agent", false)]);
        seal(&inner, &[]);
        let mut found: Vec<String> = thinnable(&app).into_iter().map(|(path, _)| path[contents.len() + 1..].to_string()).collect();
        found.sort();
        assert_eq!(found, ["Frameworks/libcode.dylib", "MacOS/Demo", "MacOS/helper"]);
        std::fs::remove_dir_all(fsx::parent(&app)).unwrap();
    }
}
