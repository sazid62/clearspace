//! The saved Terminal space: `workspace.json` plus one scrollback file per tab. Same folder and
//! format as the native macOS build, so tabs carry over between them.
//!   macOS   ~/Library/Application Support/Clearspace/Terminal
//!   Windows %APPDATA%\Clearspace\Terminal
//!   Linux   ~/.local/share/Clearspace/Terminal
//! `CLEARSPACE_TERMINAL_DIR` overrides it (tests).

use std::fs;
use std::path::{Path, PathBuf};
use std::time::UNIX_EPOCH;

const SCROLLBACK_LINES: usize = 5000;

pub fn dir() -> PathBuf {
    if let Some(dir) = std::env::var_os("CLEARSPACE_TERMINAL_DIR") {
        return PathBuf::from(dir);
    }
    dirs::data_dir().unwrap_or_else(std::env::temp_dir).join("Clearspace").join("Terminal")
}

fn scrollback_dir() -> PathBuf {
    dir().join("scrollback")
}

/// Tab ids are UUIDs; anything else is refused so a bad id can't reach outside the folder.
fn scrollback_file(id: &str) -> Result<PathBuf, String> {
    let ok = id.len() == 36 && id.chars().all(|c| c.is_ascii_hexdigit() || c == '-');
    if !ok {
        return Err(format!("bad tab id {id:?}"));
    }
    Ok(scrollback_dir().join(format!("{}.txt", id.to_uppercase())))
}

fn write_atomic(path: &Path, text: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, text).map_err(|e| e.to_string())?;
    fs::rename(&tmp, path).map_err(|e| e.to_string())
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Saved {
    json: String,
    saved_at: Option<u64>,
}

#[tauri::command]
pub fn load_workspace() -> Option<Saved> {
    let path = dir().join("workspace.json");
    let json = fs::read_to_string(&path).ok()?;
    let saved_at = fs::metadata(&path)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
        .map(|d| d.as_millis() as u64);
    Some(Saved { json, saved_at })
}

#[tauri::command]
pub fn save_workspace(json: String) -> Result<(), String> {
    serde_json::from_str::<serde_json::Value>(&json).map_err(|e| e.to_string())?;
    write_atomic(&dir().join("workspace.json"), &json)
}

#[tauri::command]
pub fn load_scrollback(id: String) -> Option<String> {
    fs::read_to_string(scrollback_file(&id).ok()?).ok().filter(|t| !t.is_empty())
}

#[tauri::command]
pub fn save_scrollback(id: String, text: String) -> Result<(), String> {
    let path = scrollback_file(&id)?;
    let trimmed = trimmed(&text, SCROLLBACK_LINES);
    if trimmed.is_empty() {
        let _ = fs::remove_file(path);
        return Ok(());
    }
    write_atomic(&path, &trimmed)
}

#[tauri::command]
pub fn remove_scrollback(id: String) {
    if let Ok(path) = scrollback_file(&id) {
        let _ = fs::remove_file(path);
    }
}

/// Deletes scrollback files whose tab no longer exists.
#[tauri::command]
pub fn prune_scrollback(keep: Vec<String>) {
    let keep: Vec<String> = keep.iter().map(|k| k.to_uppercase()).collect();
    let Ok(entries) = fs::read_dir(scrollback_dir()) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        let stem = path.file_stem().map(|s| s.to_string_lossy().to_uppercase()).unwrap_or_default();
        if !keep.contains(&stem) {
            let _ = fs::remove_file(path);
        }
    }
}

/// Drops trailing blank lines (the unused part of the screen) and keeps the last `max_lines`.
pub fn trimmed(text: &str, max_lines: usize) -> String {
    let mut lines: Vec<&str> = text.split('\n').collect();
    while lines.last().is_some_and(|l| l.trim().is_empty()) {
        lines.pop();
    }
    let start = lines.len().saturating_sub(max_lines);
    lines[start..].join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trims_blank_tail_and_keeps_last_lines() {
        assert_eq!(trimmed("a\nb\n\n  \n", 10), "a\nb");
        assert_eq!(trimmed("1\n2\n3\n4", 2), "3\n4");
        assert_eq!(trimmed("\n\n", 5), "");
    }

    #[test]
    fn refuses_ids_that_are_not_uuids() {
        assert!(scrollback_file("../../etc/passwd").is_err());
        assert!(scrollback_file("A8955B6A-1D95-44E4-BDAE-69CB1ACA97E1").is_ok());
    }
}
