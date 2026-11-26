//! Installed apps and everything each one leaves behind, per platform:
//! macOS .app bundles, Windows' installed-programs list, Linux desktop entries and packages.

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod mac;
#[cfg(windows)]
pub mod windows;

#[cfg(target_os = "linux")]
pub use linux as platform;
#[cfg(target_os = "macos")]
pub use mac as platform;
#[cfg(windows)]
pub use windows as platform;

use super::fsx;
use serde::Serialize;
use std::collections::HashMap;

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct App {
    pub id: String,
    pub name: String,
    pub version: Option<String>,
    /// Bundle identifier, publisher or package name.
    pub detail: Option<String>,
    /// What "Show in Finder/Explorer" opens.
    pub location: Option<String>,
    /// A file whose icon stands for the app.
    pub icon: Option<String>,
    /// The app comes with its own uninstaller (Windows programs, Linux packages), run before cleaning up.
    pub uninstaller: Option<String>,
    /// Size the system already knows, shown until it's measured.
    pub size: Option<u64>,
    #[serde(skip)]
    pub extra: platform::Extra,
}

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Confidence {
    /// Named exactly after the app, or carrying its identifier.
    Exact,
    /// Only shares the app's name as a word; could belong to something else.
    NameOnly,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Leftover {
    pub path: String,
    /// Group key; the window turns it into a title and icon.
    pub kind: &'static str,
    pub confidence: Confidence,
}

#[derive(Serialize, Clone, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct Inspection {
    pub leftovers: Vec<Leftover>,
    /// The user's own settings files that mention the app; shown for editing by hand, never removed.
    pub mentions: Vec<String>,
}

/// Collects matches; exact beats name-only, and items inside an item already listed go with it.
#[derive(Default)]
pub struct Hits {
    hits: HashMap<String, (Confidence, &'static str)>,
}

impl Hits {
    pub fn add(&mut self, path: &str, kind: &'static str, confidence: Confidence) {
        if path.is_empty() || !fsx::exists(path) {
            return;
        }
        let entry = self.hits.entry(path.to_string()).or_insert((confidence, kind));
        if confidence == Confidence::Exact {
            entry.0 = Confidence::Exact;
        }
    }

    /// Adds `dir/name`, matching the name without regard to case, like the file system does.
    pub fn add_child(&mut self, dir: &str, name: &str, kind: &'static str, confidence: Confidence, listings: &mut Listings) {
        if name.is_empty() {
            return;
        }
        if let Some(actual) = listings.get(dir).iter().find(|e| e.eq_ignore_ascii_case(name)) {
            self.add(&fsx::join(dir, actual), kind, confidence);
        }
    }

    pub fn finish(self, never: &[String]) -> Vec<Leftover> {
        let mut paths: Vec<&String> = self.hits.keys().collect();
        paths.sort();
        let mut kept: Vec<String> = vec![];
        for path in paths {
            if never.iter().any(|n| fsx::key(n) == fsx::key(path) || fsx::key(&fsx::parent(path)) == fsx::key(n)) {
                continue; // a top-level folder (~/Library/Caches itself) is never one app's to remove
            }
            if kept.iter().any(|k| fsx::inside(path, k)) {
                continue;
            }
            kept.push(path.clone());
        }
        kept.into_iter()
            .map(|path| {
                let (confidence, kind) = self.hits[&path];
                Leftover { path, kind, confidence }
            })
            .collect()
    }
}

/// Folder listings, read once per inspection.
#[derive(Default)]
pub struct Listings(HashMap<String, Vec<String>>);

impl Listings {
    pub fn get(&mut self, dir: &str) -> Vec<String> {
        self.0.entry(dir.to_string()).or_insert_with(|| fsx::list_names(dir)).clone()
    }
}

/// Home-folder names that are the user's own, never one app's, whatever the app is called.
pub const PERSONAL: [&str; 23] = [
    "library", "applications", "desktop", "documents", "downloads", "movies", "music", "pictures", "public", "sites", "videos", "templates", ".trash", ".ssh",
    ".config", ".local", ".cache", ".docker", "appdata", "onedrive", "snap", ".var", "go",
];

/// Settings files where installers add lines (PATH, `source`, `Include`).
#[cfg(unix)]
pub const SETTINGS_FILES: [&str; 10] = [".zprofile", ".zshrc", ".zshenv", ".zlogin", ".bash_profile", ".bashrc", ".profile", ".config/fish/config.fish", ".ssh/config", ".gitconfig"];

/// The user's settings files that mention any of `needles` or the exact `word`.
#[cfg(unix)]
pub fn mentions(needles: &[String], word: &str) -> Vec<String> {
    let home = fsx::home();
    let mut out = vec![];
    for file in SETTINGS_FILES {
        let path = fsx::join(&home, file);
        let Ok(text) = std::fs::read_to_string(&path) else { continue };
        if text.len() > 4_000_000 {
            continue;
        }
        if needles.iter().any(|n| !n.is_empty() && text.contains(n.as_str())) || fsx::contains_word_exact(&text, word) {
            out.push(path);
        }
    }
    out
}
