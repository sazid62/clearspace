//! Moves items to the Trash (Recycle Bin on Windows) or deletes them, and retries the ones the
//! account may not touch behind the system's administrator prompt.

use super::fsx;
use serde::{Deserialize, Serialize};
use std::io;

#[derive(Clone, Copy, Debug, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Mode {
    Trash,
    Permanent,
}

#[derive(Debug)]
pub struct Failure {
    pub message: String,
    pub needs_admin: bool,
}

impl From<io::Error> for Failure {
    fn from(e: io::Error) -> Self {
        Failure { needs_admin: e.kind() == io::ErrorKind::PermissionDenied, message: e.to_string() }
    }
}

/// Removes `path`. The Trash (and Windows' temp folder) is emptied rather than removed.
pub fn remove(path: &str, mode: Mode) -> Result<(), Failure> {
    if super::temp::emptied_folders().iter().any(|f| fsx::key(f) == fsx::key(path)) {
        return empty(path);
    }
    match mode {
        Mode::Trash => to_trash(path),
        Mode::Permanent => delete(path),
    }
}

/// Deletes everything inside `dir`, carrying on past items that are in use.
fn empty(dir: &str) -> Result<(), Failure> {
    let mut failed = 0;
    let mut last: Option<Failure> = None;
    for name in fsx::list_names(dir) {
        if let Err(e) = delete(&fsx::join(dir, &name)) {
            failed += 1;
            last = Some(e);
        }
    }
    match last {
        None => Ok(()),
        Some(e) => Err(Failure { message: format!("{failed} item{} inside couldn't be removed: {}", if failed == 1 { "" } else { "s" }, e.message), needs_admin: e.needs_admin }),
    }
}

fn to_trash(path: &str) -> Result<(), Failure> {
    #[allow(unused_mut)]
    let mut ctx = trash::TrashContext::default();
    #[cfg(target_os = "macos")]
    {
        // NSFileManager, like the native build: no Finder automation prompt.
        use trash::macos::{DeleteMethod, TrashContextExtMacos};
        ctx.set_delete_method(DeleteMethod::NsFileManager);
    }
    ctx.delete(path).map_err(|e| {
        let message = trash_message(&e);
        let lower = message.to_lowercase();
        let needs_admin = ["permission", "not permitted", "access is denied", "access denied", "don’t have permission", "don't have permission"].iter().any(|w| lower.contains(w));
        Failure { message, needs_admin }
    })
}

fn trash_message(e: &trash::Error) -> String {
    match e {
        trash::Error::Unknown { description } => description.clone(),
        trash::Error::Os { description, .. } => description.clone(),
        other => other.to_string(),
    }
}

pub fn delete(path: &str) -> Result<(), Failure> {
    let attempt = || if fsx::is_dir(path) { std::fs::remove_dir_all(path) } else { std::fs::remove_file(path) };
    match attempt() {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == io::ErrorKind::PermissionDenied || cfg!(windows) => {
            // Read-only items (Go's module cache, files marked read-only on Windows) go once writable.
            make_writable(path);
            attempt().map_err(Failure::from)
        }
        Err(e) => Err(e.into()),
    }
}

fn make_writable(path: &str) {
    let mut pending = vec![path.to_string()];
    while let Some(p) = pending.pop() {
        let Some(meta) = fsx::info(&p) else { continue };
        if meta.file_type().is_symlink() {
            continue;
        }
        let mut perms = meta.permissions();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            perms.set_mode(perms.mode() | 0o700);
        }
        #[cfg(not(unix))]
        #[allow(clippy::permissions_set_readonly_false)]
        perms.set_readonly(false);
        let _ = std::fs::set_permissions(&p, perms);
        if fsx::is_real_dir(&meta) {
            pending.extend(fsx::list_names(&p).into_iter().map(|n| fsx::join(&p, &n)));
        }
    }
}

#[derive(Debug, Serialize, PartialEq)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum AdminResult {
    Completed,
    Cancelled,
    Failed { message: String },
}

/// Runs the removal with administrator rights behind the system prompt. Callers re-check which
/// paths are gone afterwards; one failing item doesn't stop the rest.
pub fn as_admin(paths: &[String], mode: Mode) -> AdminResult {
    #[cfg(target_os = "macos")]
    return mac_admin(paths, mode);
    #[cfg(target_os = "linux")]
    return linux_admin(paths, mode);
    #[cfg(windows)]
    return windows_admin(paths, mode);
}

#[cfg_attr(windows, allow(dead_code))]
pub fn shell_quoted(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}

/// A free name in `dir` for `path`'s file, skipping names already taken or reserved.
#[cfg(unix)]
fn free_name(dir: &str, path: &str, reserved: &mut std::collections::HashSet<String>) -> String {
    let name = fsx::name(path);
    let mut candidate = name.clone();
    let mut copy = 2;
    while fsx::exists(&fsx::join(dir, &candidate)) || reserved.contains(&candidate) {
        candidate = format!("{name} {copy}");
        copy += 1;
    }
    reserved.insert(candidate.clone());
    candidate
}

#[cfg(target_os = "macos")]
fn mac_admin(paths: &[String], mode: Mode) -> AdminResult {
    let trash = super::temp::trash().unwrap_or_default();
    let mut reserved = Default::default();
    let commands: Vec<String> = paths
        .iter()
        .map(|p| match mode {
            Mode::Permanent => format!("/bin/rm -rf {}", shell_quoted(p)),
            Mode::Trash => format!("/bin/mv -n {} {}", shell_quoted(p), shell_quoted(&fsx::join(&trash, &free_name(&trash, p, &mut reserved)))),
        })
        .collect();
    let escaped = commands.join("; ").replace('\\', r"\\").replace('"', "\\\"");
    super::mac::run_admin_script(&format!("do shell script \"{escaped}\" with administrator privileges"))
}

#[cfg(target_os = "linux")]
fn linux_admin(paths: &[String], mode: Mode) -> AdminResult {
    let mut script = String::from("set +e\n");
    match mode {
        Mode::Permanent => {
            for p in paths {
                script += &format!("rm -rf -- {}\n", shell_quoted(p));
            }
        }
        Mode::Trash => {
            // Into the user's Trash with the .trashinfo file the file manager needs to show and restore it.
            let trash = super::temp::trash().unwrap_or_default();
            let (files, info) = (fsx::join(&trash, "files"), fsx::join(&trash, "info"));
            let _ = std::fs::create_dir_all(&files);
            let _ = std::fs::create_dir_all(&info);
            let mut reserved = Default::default();
            let date = std::process::Command::new("date").arg("+%Y-%m-%dT%H:%M:%S").output().map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string()).unwrap_or_default();
            let owner = format!("{}:{}", fsx::my_uid(), unsafe { libc::getgid() });
            for p in paths {
                let name = free_name(&files, p, &mut reserved);
                let encoded: String = p.bytes().map(|b| if b.is_ascii_alphanumeric() || b"/-_.~".contains(&b) { (b as char).to_string() } else { format!("%{b:02X}") }).collect();
                let dest = fsx::join(&files, &name);
                script += &format!(
                    "mv -n -- {src} {dest} && chown -R {owner} {dest} && printf '[Trash Info]\\nPath=%s\\nDeletionDate=%s\\n' {enc} {date} > {info} && chown {owner} {info}\n",
                    src = shell_quoted(p),
                    dest = shell_quoted(&dest),
                    enc = shell_quoted(&encoded),
                    date = shell_quoted(&date),
                    info = shell_quoted(&fsx::join(&info, &format!("{name}.trashinfo"))),
                );
            }
        }
    }
    match std::process::Command::new("pkexec").args(["sh", "-c", &script]).output() {
        // pkexec: 126 = the prompt was dismissed, 127 = not authorized.
        Ok(out) if out.status.code() == Some(126) => AdminResult::Cancelled,
        Ok(out) if out.status.code() == Some(127) => AdminResult::Failed { message: "Not authorized.".into() },
        Ok(_) => AdminResult::Completed,
        Err(e) => AdminResult::Failed { message: format!("Couldn't ask for administrator rights (pkexec: {e}).") },
    }
}

#[cfg(windows)]
fn windows_admin(paths: &[String], mode: Mode) -> AdminResult {
    let ps = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let mut inner = String::from("Add-Type -AssemblyName Microsoft.VisualBasic; $ErrorActionPreference = 'Continue'\n");
    for p in paths {
        inner += &match mode {
            Mode::Permanent => format!("Remove-Item -LiteralPath {} -Recurse -Force\n", ps(p)),
            Mode::Trash if fsx::is_dir(p) => format!("[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory({}, 'OnlyErrorDialogs', 'SendToRecycleBin')\n", ps(p)),
            Mode::Trash => format!("[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile({}, 'OnlyErrorDialogs', 'SendToRecycleBin')\n", ps(p)),
        };
    }
    let outer = format!(
        "try {{ Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','{}' }} catch {{ Write-Output 'CANCELLED'; exit 2 }}",
        crate::pty::encode_utf16_base64(&inner)
    );
    use std::os::windows::process::CommandExt;
    const NO_WINDOW: u32 = 0x0800_0000;
    match std::process::Command::new("powershell.exe").args(["-NoProfile", "-EncodedCommand", &crate::pty::encode_utf16_base64(&outer)]).creation_flags(NO_WINDOW).output() {
        Ok(out) if out.status.code() == Some(2) => AdminResult::Cancelled,
        Ok(_) => AdminResult::Completed,
        Err(e) => AdminResult::Failed { message: e.to_string() },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deletes_read_only_folders() {
        let dir = std::env::temp_dir().join(format!("cs-rm-{}", std::process::id()));
        std::fs::create_dir_all(dir.join("ro")).unwrap();
        std::fs::write(dir.join("ro/file"), "x").unwrap();
        let mut perms = std::fs::metadata(dir.join("ro")).unwrap().permissions();
        perms.set_readonly(true);
        std::fs::set_permissions(dir.join("ro"), perms).unwrap();
        let path = dir.to_string_lossy().into_owned();
        delete(&path).unwrap();
        assert!(!fsx::exists(&path));
    }

    #[test]
    fn quotes_for_sh() {
        assert_eq!(shell_quoted("it's"), r"'it'\''s'");
    }
}
