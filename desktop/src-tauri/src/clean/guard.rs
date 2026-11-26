//! Refuses Disk Cleaner deletes that would damage the system or the account: whole top-level
//! folders, anything inside the keychain or ~/.ssh, anything in /tmp owned by someone else, and
//! anything outside the scanned folders.

use super::fsx::{self, SEP};
use std::collections::HashSet;

pub struct Guard {
    roots: Vec<String>,
    protected: HashSet<String>,
    never_inside: Vec<String>,
    #[cfg(unix)]
    shared_temp: String,
}

impl Guard {
    pub fn new(roots: &[String]) -> Self {
        let home = fsx::home();
        let mut folders: Vec<&str> = vec![".ssh", "Documents", "Desktop", "Downloads", "Pictures", "Music"];
        let mut secret: Vec<&str> = vec![".ssh"];
        let mut paths: Vec<String> = vec![home.clone()];
        #[cfg(target_os = "macos")]
        {
            folders.extend([
                "Movies", "Library", "Library/Application Support", "Library/Caches", "Library/Preferences", "Library/Keychains",
                "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Mobile Documents", "Library/CloudStorage",
            ]);
            secret.push("Library/Keychains");
            let temp = super::temp::user_temp_root();
            paths.extend(["T", "C", "X", "0"].map(|d| fsx::join(&temp, d)));
            paths.extend(["/Applications".to_string(), temp]);
        }
        #[cfg(target_os = "linux")]
        {
            folders.extend(["Videos", ".config", ".local", ".local/share", ".cache", ".gnupg", ".local/share/keyrings"]);
            secret.extend([".gnupg", ".local/share/keyrings"]);
        }
        #[cfg(windows)]
        {
            folders.extend(["Videos", "OneDrive", "AppData", "AppData/Local", "AppData/Roaming", "AppData/LocalLow", "AppData/Local/Temp"]);
            secret.extend(["AppData/Roaming/Microsoft/Credentials", "AppData/Local/Microsoft/Credentials", "AppData/Roaming/Microsoft/Protect"]);
        }
        #[cfg(unix)]
        paths.push(super::temp::shared_temp());
        paths.extend(folders.iter().map(|f| fsx::join(&home, f)));
        paths.extend(roots.iter().cloned());
        paths.extend(own_install());
        Guard {
            roots: roots.iter().map(|r| fsx::real_path(r)).collect(),
            protected: paths.iter().map(|p| fsx::key(&fsx::real_path(p))).collect(),
            never_inside: secret.iter().map(|s| fsx::real_path(&fsx::join(&home, s))).collect(),
            #[cfg(unix)]
            shared_temp: super::temp::shared_temp(),
        }
    }

    /// Why `path` may not be removed, or None when it may.
    pub fn refusal(&self, path: &str) -> Option<String> {
        if !fsx::exists(path) {
            return Some("It no longer exists.".into());
        }
        // The emptied folders (Trash, Windows temp) are allowed: they're emptied, not removed.
        let emptied = super::temp::emptied_folders().iter().any(|f| fsx::key(f) == fsx::key(path));
        let real = fsx::real_path(path);
        let parent = fsx::parent(&real);
        let at_top = parent.is_empty() || parent.trim_end_matches(SEP).len() <= 2; // "/" or "C:\"
        if !emptied && (self.protected.contains(&fsx::key(&real)) || at_top) {
            return Some("This folder is protected.".into());
        }
        if self.never_inside.iter().any(|s| fsx::within(&real, s)) {
            return Some("This folder is protected.".into());
        }
        #[cfg(unix)]
        if fsx::inside(&real, &self.shared_temp) {
            // /tmp is shared by every account: only touch what this user created there.
            let rest = &real[self.shared_temp.len() + 1..];
            let top = fsx::join(&self.shared_temp, rest.split(SEP).next().unwrap_or(""));
            if fsx::owner(&top) != Some(fsx::my_uid()) {
                return Some("It belongs to another user.".into());
            }
        }
        if !self.roots.iter().any(|r| fsx::inside(&real, r)) {
            return Some("It's outside the scanned folders.".into());
        }
        None
    }
}

/// Clearspace itself: the .app bundle on macOS, the program elsewhere.
fn own_install() -> Option<String> {
    let exe = std::env::current_exe().ok()?.to_string_lossy().into_owned();
    if cfg!(target_os = "macos") {
        if let Some(i) = exe.find(".app/") {
            return Some(exe[..i + 4].to_string());
        }
    }
    Some(exe)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protects_top_folders_and_allows_inside() {
        let home = fsx::home();
        let guard = Guard::new(&[home.clone()]);
        assert!(guard.refusal(&home).is_some());
        if fsx::exists(&fsx::join(&home, "Downloads")) {
            assert_eq!(guard.refusal(&fsx::join(&home, "Downloads")).as_deref(), Some("This folder is protected."));
        }
        let dir = std::env::temp_dir().join(format!("cs-guard-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.to_string_lossy().into_owned();
        // Windows keeps its temp folder inside the home folder, so scan somewhere else.
        let elsewhere = Guard::new(&[fsx::join(&path, "elsewhere")]);
        assert_eq!(elsewhere.refusal(&path).as_deref(), Some("It's outside the scanned folders."));
        let inner = Guard::new(&[fsx::parent(&path)]);
        assert_eq!(inner.refusal(&path), None);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
