//! Where each platform keeps temporary files and the Trash.

use super::fsx;

/// The machine-wide temp folder (/tmp, really /private/tmp on macOS). Tools, test runs and
/// Claude Code sessions leave folders here.
#[cfg(unix)]
pub fn shared_temp() -> String {
    fsx::real_path("/tmp")
}

/// macOS's per-user temp root (the parent of DARWIN_USER_TEMP_DIR), which holds T/, C/ and X/.
#[cfg(target_os = "macos")]
pub fn user_temp_root() -> String {
    let mut buf = vec![0 as libc::c_char; libc::PATH_MAX as usize];
    let len = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr(), buf.len()) };
    let temp = if len > 0 {
        unsafe { std::ffi::CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned()
    } else {
        std::env::temp_dir().to_string_lossy().into_owned()
    };
    fsx::real_path(&fsx::parent(temp.trim_end_matches('/')))
}

/// The user's Trash folder, which is emptied rather than removed.
pub fn trash() -> Option<String> {
    #[cfg(target_os = "macos")]
    return Some(fsx::join(&fsx::home(), ".Trash"));
    #[cfg(target_os = "linux")]
    return Some(
        std::env::var("XDG_DATA_HOME")
            .ok()
            .filter(|d| !d.is_empty())
            .map(|d| fsx::join(&d, "Trash"))
            .unwrap_or_else(|| fsx::join(&fsx::home(), ".local/share/Trash")),
    );
    #[cfg(windows)]
    return None;
}

/// %LOCALAPPDATA% / %APPDATA% / %PROGRAMDATA%.
#[cfg(windows)]
pub fn env_dir(name: &str, fallback: &str) -> String {
    std::env::var(name).ok().filter(|d| !d.is_empty()).unwrap_or_else(|| fsx::join(&fsx::home(), fallback))
}

/// Folders that are emptied, never removed: the Trash, and Windows' temp folder.
pub fn emptied_folders() -> Vec<String> {
    let mut out: Vec<String> = trash().into_iter().collect();
    #[cfg(windows)]
    out.push(fsx::join(&env_dir("LOCALAPPDATA", "AppData/Local"), "Temp"));
    out.retain(|p| !p.is_empty());
    out
}
