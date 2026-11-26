//! What the Clean tools remember between runs: the "never clean" list and the history of what
//! was removed. Both live beside the Terminal space's folder, in `Clearspace/Clean`.

use super::fsx;
use serde::{Deserialize, Serialize};
use std::path::PathBuf;
use std::sync::Mutex;

/// Keeps two removals from writing the history at once.
static FILES: Mutex<()> = Mutex::new(());
const HISTORY_LIMIT: usize = 5000;

pub fn dir() -> PathBuf {
    let terminal = crate::store::dir();
    terminal.parent().map(|p| p.join("Clean")).unwrap_or(terminal)
}

fn write(name: &str, text: &str) -> Result<(), String> {
    let dir = dir();
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    let tmp = dir.join(format!("{name}.tmp"));
    std::fs::write(&tmp, text).map_err(|e| e.to_string())?;
    std::fs::rename(&tmp, dir.join(name)).map_err(|e| e.to_string())
}

// MARK: Never clean

/// Files and folders the user marked as never to clean.
pub fn protected() -> Vec<String> {
    std::fs::read_to_string(dir().join("protected.json")).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

pub fn set_protected(paths: &[String]) -> Result<(), String> {
    let mut paths: Vec<String> = paths.iter().map(|p| p.trim_end_matches(fsx::SEP).to_string()).filter(|p| !p.is_empty()).collect();
    paths.sort_by_key(|p| p.to_lowercase());
    paths.dedup_by_key(|p| fsx::key(p));
    let _lock = FILES.lock().unwrap();
    write("protected.json", &serde_json::to_string_pretty(&paths).map_err(|e| e.to_string())?)
}

/// Why `path` may not be removed, given the never-clean list: it is on it, inside a folder on
/// it, or holds something on it.
pub fn protection(path: &str, protected: &[String]) -> Option<String> {
    for p in protected {
        if fsx::key(p) == fsx::key(path) {
            return Some("You marked it as never to clean.".into());
        }
        if fsx::inside(path, p) {
            return Some(format!("It's inside {}, which you marked as never to clean.", fsx::name(p)));
        }
        if fsx::inside(p, path) {
            return Some(format!("It holds {}, which you marked as never to clean.", fsx::name(p)));
        }
    }
    None
}

// MARK: History

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    /// Seconds since 1970.
    pub at: i64,
    /// "trash", "delete", "slim" or "task".
    pub action: String,
    /// The path removed, or the maintenance task's title.
    pub title: String,
    /// Bytes freed (in the Trash until it's emptied, for "trash").
    pub size: u64,
    /// "cleaner", "uninstaller" or "maintenance".
    pub tool: String,
}

impl Entry {
    pub fn now(action: &str, title: &str, size: u64, tool: &str) -> Self {
        Entry { at: fsx::now_secs(), action: action.into(), title: title.into(), size, tool: tool.into() }
    }
}

/// Adds to the history, dropping the oldest entries past the limit.
pub fn record(entries: &[Entry]) {
    if entries.is_empty() {
        return;
    }
    let _lock = FILES.lock().unwrap();
    let mut lines: Vec<String> = std::fs::read_to_string(dir().join("history.jsonl")).unwrap_or_default().lines().map(String::from).collect();
    lines.extend(entries.iter().filter_map(|e| serde_json::to_string(e).ok()));
    let start = lines.len().saturating_sub(HISTORY_LIMIT);
    let _ = write("history.jsonl", &(lines[start..].join("\n") + "\n"));
}

/// Newest first.
pub fn history() -> Vec<Entry> {
    let text = std::fs::read_to_string(dir().join("history.jsonl")).unwrap_or_default();
    let mut out: Vec<Entry> = text.lines().filter_map(|l| serde_json::from_str(l).ok()).collect();
    out.reverse();
    out
}

pub fn clear_history() {
    let _lock = FILES.lock().unwrap();
    let _ = std::fs::remove_file(dir().join("history.jsonl"));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn protects_the_item_what_is_inside_it_and_what_holds_it() {
        let base = fsx::join(&fsx::home(), "work");
        let list = vec![fsx::join(&base, "keep")];
        assert_eq!(protection(&fsx::join(&base, "keep"), &list).as_deref(), Some("You marked it as never to clean."));
        assert!(protection(&fsx::join(&base, "keep/node_modules"), &list).unwrap().starts_with("It's inside keep"));
        assert!(protection(&base, &list).unwrap().starts_with("It holds keep"));
        assert_eq!(protection(&fsx::join(&base, "keeper"), &list), None);
        assert_eq!(protection(&fsx::join(&base, "other"), &list), None);
    }

    #[test]
    fn history_lines_round_trip() {
        let entry = Entry { at: 5, action: "delete".into(), title: "/tmp/x".into(), size: 9, tool: "cleaner".into() };
        let line = serde_json::to_string(&entry).unwrap();
        assert_eq!(line, r#"{"at":5,"action":"delete","title":"/tmp/x","size":9,"tool":"cleaner"}"#);
        assert_eq!(serde_json::from_str::<Entry>(&line).unwrap(), entry);
    }
}
