//! Small file-system helpers shared by the Clean tools. Paths stay plain strings so they round-trip
//! exactly between the scan, the window and the removal (prefix checks rely on that).

use std::collections::HashSet;
use std::fs::Metadata;
use std::path::Path;

pub const SEP: char = std::path::MAIN_SEPARATOR;

pub fn home() -> String {
    dirs::home_dir().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|| SEP.to_string())
}

/// `base` + `relative`, where `relative` is written with "/" on every platform.
pub fn join(base: &str, relative: &str) -> String {
    let mut out = base.trim_end_matches(SEP).to_string();
    for part in relative.split('/').filter(|p| !p.is_empty()) {
        out.push(SEP);
        out.push_str(part);
    }
    out
}

pub fn parent(path: &str) -> String {
    Path::new(path).parent().map(|p| p.to_string_lossy().into_owned()).unwrap_or_default()
}

pub fn name(path: &str) -> String {
    Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string())
}

pub fn extension(path: &str) -> String {
    Path::new(path).extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default()
}

/// True when `path` is `base` itself or inside it.
pub fn within(path: &str, base: &str) -> bool {
    let (path, base) = (key(path), key(base));
    path == base || path.starts_with(&(base.trim_end_matches(SEP).to_string() + &SEP.to_string()))
}

/// True when `path` is strictly inside `base`.
pub fn inside(path: &str, base: &str) -> bool {
    within(path, base) && key(path) != key(base)
}

/// Comparison key: Windows paths ignore case.
pub fn key(path: &str) -> String {
    if cfg!(windows) { path.to_lowercase() } else { path.to_string() }
}

/// Resolves links (/tmp → /private/tmp on macOS) without Windows' \\?\ prefix.
pub fn real_path(path: &str) -> String {
    match std::fs::canonicalize(path) {
        Ok(p) => {
            let s = p.to_string_lossy().into_owned();
            match s.strip_prefix(r"\\?\") {
                Some(rest) if !rest.starts_with("UNC\\") => rest.to_string(),
                _ => s,
            }
        }
        Err(_) => path.to_string(),
    }
}

/// lstat: describes a link itself rather than what it points to.
pub fn info(path: &str) -> Option<Metadata> {
    std::fs::symlink_metadata(path).ok()
}

pub fn exists(path: &str) -> bool {
    info(path).is_some()
}

pub fn is_dir(path: &str) -> bool {
    info(path).is_some_and(|m| m.is_dir())
}

pub fn list_names(dir: &str) -> Vec<String> {
    std::fs::read_dir(dir)
        .map(|entries| entries.flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect())
        .unwrap_or_default()
}

pub fn modified_secs(meta: &Metadata) -> i64 {
    meta.modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0)
}

/// Identifies a file across hard links (Unix); None where links aren't tracked.
#[cfg(unix)]
pub fn file_id(meta: &Metadata) -> Option<(u64, u64)> {
    use std::os::unix::fs::MetadataExt;
    (meta.nlink() > 1).then(|| (meta.dev(), meta.ino()))
}
#[cfg(not(unix))]
pub fn file_id(_meta: &Metadata) -> Option<(u64, u64)> {
    None
}

/// The volume a folder is on, so scans stay on one disk (Unix). Windows has no cheap equivalent;
/// junctions and links, the usual way onto another volume, are skipped instead.
#[cfg(unix)]
pub fn device(meta: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.dev()
}
#[cfg(not(unix))]
pub fn device(_meta: &Metadata) -> u64 {
    0
}

/// Bytes the entry takes on disk, like `du`. Cloud placeholders (OneDrive files not downloaded) take none.
#[cfg(unix)]
pub fn disk_size(meta: &Metadata) -> u64 {
    use std::os::unix::fs::MetadataExt;
    meta.blocks() * 512
}
#[cfg(windows)]
pub fn disk_size(meta: &Metadata) -> u64 {
    use std::os::windows::fs::MetadataExt;
    const OFFLINE: u32 = 0x1000;
    const RECALL_ON_OPEN: u32 = 0x40000;
    const RECALL_ON_DATA_ACCESS: u32 = 0x400000;
    if meta.file_attributes() & (OFFLINE | RECALL_ON_OPEN | RECALL_ON_DATA_ACCESS) != 0 {
        return 0;
    }
    meta.len()
}

/// A folder to walk into: a real directory, not a link or junction to somewhere else.
pub fn is_real_dir(meta: &Metadata) -> bool {
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return false;
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        const REPARSE_POINT: u32 = 0x400;
        if meta.file_attributes() & REPARSE_POINT != 0 {
            return false;
        }
    }
    true
}

/// Total size on disk of a file or folder: hard links count once and other volumes are skipped.
pub fn allocated_size(path: &str) -> u64 {
    let Some(top) = info(path) else { return 0 };
    if !is_real_dir(&top) {
        return disk_size(&top);
    }
    let device = device(&top);
    let mut total = 0;
    let mut seen = HashSet::new();
    let mut pending = vec![path.to_string()];
    while let Some(dir) = pending.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if meta.is_dir() {
                if is_real_dir(&meta) && self::device(&meta) == device {
                    pending.push(entry.path().to_string_lossy().into_owned());
                }
            } else if file_id(&meta).is_none_or(|id| seen.insert(id)) {
                total += disk_size(&meta);
            }
        }
    }
    total
}

/// A directory on a different device from its parent: something is mounted on it right now.
pub fn is_mount_point(path: &str) -> bool {
    #[cfg(unix)]
    {
        let (Some(me), Some(up)) = (info(path), info(&parent(path))) else { return false };
        me.is_dir() && device(&me) != device(&up)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        false
    }
}

#[cfg(unix)]
pub fn owner(path: &str) -> Option<u32> {
    use std::os::unix::fs::MetadataExt;
    info(path).map(|m| m.uid())
}

#[cfg(unix)]
pub fn my_uid() -> u32 {
    unsafe { libc::getuid() }
}

/// "3 days ago", for notes about when something was last touched.
pub fn relative(secs: i64, now: i64) -> String {
    let d = (now - secs).max(0);
    let unit = |n: i64, word: &str| format!("{n} {word}{} ago", if n == 1 { "" } else { "s" });
    match d {
        0..60 => "just now".into(),
        60..3600 => unit(d / 60, "minute"),
        3600..86400 => unit(d / 3600, "hour"),
        86400..172800 => "yesterday".into(),
        172800..1209600 => unit(d / 86400, "day"),
        1209600..5184000 => unit(d / 604800, "week"),
        5184000..31536000 => unit(d / 2592000, "month"),
        _ => unit(d / 31536000, "year"),
    }
}

pub fn now_secs() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

/// True when `word` appears in `text` with no letter or digit right before or after it (ignoring
/// case), so "Paste" matches "Paste Helper" and "com.x.paste" but not "PasteBar".
pub fn contains_word(text: &str, word: &str) -> bool {
    let hay = text.to_lowercase().into_bytes();
    let needle = word.to_lowercase().into_bytes();
    if needle.is_empty() || hay.len() < needle.len() {
        return false;
    }
    let is_word = |b: u8| b.is_ascii_lowercase() || b.is_ascii_digit();
    (0..=hay.len() - needle.len()).any(|start| {
        let end = start + needle.len();
        hay[start..end] == needle[..] && (start == 0 || !is_word(hay[start - 1])) && (end == hay.len() || !is_word(hay[end]))
    })
}

/// Like `contains_word` but case-sensitive: "Home" shouldn't match every $HOME.
#[cfg_attr(windows, allow(dead_code))]
pub fn contains_word_exact(text: &str, word: &str) -> bool {
    if word.is_empty() {
        return false;
    }
    let is_word = |c: char| c.is_alphanumeric();
    let mut from = 0;
    while let Some(found) = text[from..].find(word) {
        let start = from + found;
        let end = start + word.len();
        let before = text[..start].chars().next_back();
        let after = text[end..].chars().next();
        if !before.is_some_and(is_word) && !after.is_some_and(is_word) {
            return true;
        }
        from = end;
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn words() {
        assert!(contains_word("Paste Helper", "paste"));
        assert!(contains_word("com.x.paste", "Paste"));
        assert!(!contains_word("PasteBar", "Paste"));
        assert!(contains_word_exact("export PATH=/opt/Docker/bin", "Docker"));
        assert!(!contains_word_exact("$HOME/x", "Home"));
    }

    #[test]
    fn relative_times() {
        assert_eq!(relative(0, 30), "just now");
        assert_eq!(relative(0, 3 * 86400), "3 days ago");
        assert_eq!(relative(0, 86400 + 5), "yesterday");
        assert_eq!(relative(0, 400 * 86400), "1 year ago");
    }

    #[test]
    fn joins_and_prefixes() {
        let base = format!("{SEP}home{SEP}me");
        assert_eq!(join(&base, ".cache/pip"), format!("{base}{SEP}.cache{SEP}pip"));
        assert!(within(&join(&base, "a"), &base));
        assert!(!within(&format!("{base}x"), &base));
        assert!(!inside(&base, &base));
    }
}
