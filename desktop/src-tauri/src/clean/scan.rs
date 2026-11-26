//! Measures every file under the scan roots and keeps a size tree of the items worth showing
//! (20 MB and up); smaller ones are folded into each folder's "small items".

use super::fsx::{self, SEP};
use serde::Serialize;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Instant;

pub const MINIMUM: u64 = 20 * 1024 * 1024;

/// Entries that tell what a folder is (a project, a git worktree, a Python venv...).
const MARKERS: [&str; 7] = ["package.json", "Cargo.toml", "Podfile", "pyvenv.cfg", "build.gradle", "build.gradle.kts", "pubspec.yaml"];
/// A `.git` that is a file, not a folder: a linked worktree or submodule.
pub const GIT_FILE: &str = ".git (file)";

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub path: String,
    pub name: String,
    pub dir: bool,
    pub size: u64,
    /// Total of the children under the minimum size, shown as one "small items" row.
    pub small: u64,
    pub children: Vec<Node>,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct LargeFile {
    pub path: String,
    pub size: u64,
    /// Seconds since 1970.
    pub modified: i64,
}

pub struct ScanRoot {
    pub path: String,
    pub title: String,
}

/// What gets scanned on this platform.
pub fn roots() -> Vec<ScanRoot> {
    // The self-test points the scan at a small fixture instead of the whole disk.
    if std::env::var_os("CLEARSPACE_SELFTEST").is_some() {
        if let Ok(list) = std::env::var("CLEARSPACE_SCAN_ROOTS") {
            return std::env::split_paths(&list)
                .map(|p| {
                    // Real path, like the platform's own roots (/tmp is /private/tmp on macOS).
                    let path = fsx::real_path(&p.to_string_lossy());
                    ScanRoot { title: fsx::name(&path), path }
                })
                .collect();
        }
    }
    let home = fsx::home();
    let root = |path: String, title: &str| ScanRoot { path, title: title.into() };
    #[allow(unused_mut)]
    let mut out = vec![root(home.clone(), "Home Folder")];
    #[cfg(target_os = "macos")]
    {
        out.push(root("/Applications".into(), "Applications"));
        out.push(root(super::temp::user_temp_root(), "Temporary Files"));
        out.push(root(super::temp::shared_temp(), "Shared Temporary Files"));
    }
    #[cfg(target_os = "linux")]
    out.push(root(super::temp::shared_temp(), "Temporary Files"));
    // Windows keeps temporary files inside the home folder (AppData\Local\Temp), so it's covered.
    let _ = &home;
    out
}

pub struct Item {
    pub path: String,
    pub name: String,
    pub dir: bool,
    pub size: u64,
}

pub struct ScanResult {
    pub root: Node,
    pub large_files: Vec<LargeFile>,
    /// Every kept item, by `fsx::key` of its path.
    pub items: HashMap<String, Item>,
    /// Folder → marker entries it directly contains.
    pub markers: HashMap<String, HashSet<String>>,
    pub file_count: u64,
    pub millis: u64,
}

impl ScanResult {
    #[cfg(test)]
    pub fn size_of(&self, path: &str) -> Option<u64> {
        self.items.get(&fsx::key(path)).map(|i| i.size)
    }
}

pub struct Scanner<'a> {
    cancel: &'a AtomicBool,
    progress: &'a mut dyn FnMut(u64, &str),
    items: HashMap<String, Item>,
    large_files: Vec<LargeFile>,
    markers: HashMap<String, HashSet<String>>,
    seen: HashSet<(u64, u64)>,
    file_count: u64,
    last_report: Instant,
}

impl<'a> Scanner<'a> {
    pub fn new(cancel: &'a AtomicBool, progress: &'a mut dyn FnMut(u64, &str)) -> Self {
        Scanner {
            cancel,
            progress,
            items: HashMap::new(),
            large_files: Vec::new(),
            markers: HashMap::new(),
            seen: HashSet::new(),
            file_count: 0,
            last_report: Instant::now(),
        }
    }

    /// Walks every root; None if cancelled. Recursive: run it on a thread with a large stack.
    pub fn run(mut self, roots: &[ScanRoot]) -> Option<ScanResult> {
        let started = Instant::now();
        let mut root = Node { path: String::new(), name: "Scanned folders".into(), dir: true, size: 0, small: 0, children: vec![] };
        for scan_root in roots {
            let Some(meta) = fsx::info(&scan_root.path) else { continue };
            if !meta.is_dir() {
                continue;
            }
            let node = self.scan(&scan_root.path, &scan_root.title, fsx::device(&meta));
            if self.cancel.load(Ordering::Relaxed) {
                return None;
            }
            root.size += node.size;
            self.keep(&node);
            root.children.push(node);
        }
        root.children.sort_by(|a, b| b.size.cmp(&a.size));
        self.large_files.sort_by(|a, b| b.size.cmp(&a.size));
        self.large_files.truncate(3000);
        Some(ScanResult {
            root,
            large_files: self.large_files,
            items: self.items,
            markers: self.markers,
            file_count: self.file_count,
            millis: started.elapsed().as_millis() as u64,
        })
    }

    fn keep(&mut self, node: &Node) {
        self.items.insert(fsx::key(&node.path), Item { path: node.path.clone(), name: node.name.clone(), dir: node.dir, size: node.size });
    }

    fn scan(&mut self, path: &str, name: &str, device: u64) -> Node {
        let mut node = Node { path: path.into(), name: name.into(), dir: true, size: 0, small: 0, children: vec![] };
        if self.cancel.load(Ordering::Relaxed) {
            return node;
        }
        let Ok(entries) = std::fs::read_dir(path) else { return node };
        let mut folders = vec![];
        for entry in entries.flatten() {
            let entry_name = entry.file_name().to_string_lossy().into_owned();
            let Ok(meta) = entry.metadata() else { continue };
            let child_path = format!("{}{SEP}{entry_name}", path.trim_end_matches(SEP));
            if meta.is_dir() {
                // Links, junctions and other volumes mounted inside the tree (e.g. ~/OrbStack) aren't this disk.
                if fsx::is_real_dir(&meta) && fsx::device(&meta) == device {
                    folders.push((child_path, entry_name));
                }
                continue;
            }
            if entry_name == ".git" {
                if meta.is_file() {
                    self.markers.entry(fsx::key(path)).or_default().insert(GIT_FILE.into());
                }
            } else if MARKERS.contains(&entry_name.as_str()) {
                self.markers.entry(fsx::key(path)).or_default().insert(entry_name.clone());
            }
            self.file_count += 1;
            if self.file_count & 1023 == 0 {
                self.report(path);
            }
            if fsx::file_id(&meta).is_some_and(|id| !self.seen.insert(id)) {
                continue; // a hard link already counted
            }
            let size = fsx::disk_size(&meta);
            node.size += size;
            if size >= MINIMUM {
                let file = Node { path: child_path.clone(), name: entry_name, dir: false, size, small: 0, children: vec![] };
                self.keep(&file);
                node.children.push(file);
                if meta.is_file() {
                    self.large_files.push(LargeFile { path: child_path, size, modified: fsx::modified_secs(&meta) });
                }
            } else {
                node.small += size;
            }
        }
        for (child_path, child_name) in folders {
            let child = self.scan(&child_path, &child_name, device);
            node.size += child.size;
            if child.size >= MINIMUM {
                self.keep(&child);
                node.children.push(child);
            } else {
                node.small += child.size;
            }
        }
        node.children.sort_by(|a, b| b.size.cmp(&a.size));
        node
    }

    fn report(&mut self, folder: &str) {
        if self.last_report.elapsed().as_millis() >= 80 {
            self.last_report = Instant::now();
            (self.progress)(self.file_count, folder);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn keeps_big_items_and_folds_small_ones() {
        let dir = std::env::temp_dir().join(format!("cs-scan-{}", std::process::id()));
        let big = dir.join("project/node_modules");
        std::fs::create_dir_all(&big).unwrap();
        std::fs::write(dir.join("project/package.json"), "{}").unwrap();
        std::fs::write(big.join("blob"), vec![1u8; 21 * 1024 * 1024]).unwrap();
        std::fs::write(dir.join("small.txt"), "hi").unwrap();
        let cancel = AtomicBool::new(false);
        let mut progress = |_: u64, _: &str| {};
        let path = dir.to_string_lossy().into_owned();
        let result = Scanner::new(&cancel, &mut progress).run(&[ScanRoot { path: path.clone(), title: "T".into() }]).unwrap();
        let top = &result.root.children[0];
        assert_eq!(top.name, "T");
        assert_eq!(top.children[0].name, "project");
        assert!(top.small > 0);
        assert!(result.size_of(&fsx::join(&path, "project/node_modules")).is_some());
        assert!(result.markers[&fsx::key(&fsx::join(&path, "project"))].contains("package.json"));
        assert_eq!(result.large_files.len(), 1);
        std::fs::remove_dir_all(dir).unwrap();
    }
}
