//! Linux: apps from their desktop entries (what the app menu shows). Removing one runs the package
//! manager that installed it (Flatpak, Snap, apt, dnf, pacman, zypper) or deletes the AppImage, then
//! offers what it left behind in ~/.config, ~/.cache, ~/.local/share and friends.

use super::{App, Confidence, Hits, Inspection, Listings, PERSONAL};
use crate::clean::fsx;
use std::collections::HashMap;
use std::process::Command;

#[derive(Clone, Debug, Default)]
pub struct Extra {
    pub desktop_file: String,
    pub desktop_id: String,
    /// The program the entry starts (first word of Exec), resolved on PATH when possible.
    pub program: Option<String>,
    pub flatpak: Option<String>,
    pub snap: Option<String>,
    pub appimage: Option<String>,
}

fn data_dirs() -> Vec<String> {
    let home = fsx::home();
    let mut dirs = vec![std::env::var("XDG_DATA_HOME").ok().filter(|d| !d.is_empty()).unwrap_or_else(|| fsx::join(&home, ".local/share"))];
    let system = std::env::var("XDG_DATA_DIRS").ok().filter(|d| !d.is_empty()).unwrap_or_else(|| "/usr/local/share:/usr/share".into());
    dirs.extend(system.split(':').filter(|d| !d.is_empty()).map(String::from));
    dirs.extend([fsx::join(&home, ".local/share/flatpak/exports/share"), "/var/lib/flatpak/exports/share".into(), "/var/lib/snapd/desktop".into()]);
    let mut seen = std::collections::HashSet::new();
    dirs.retain(|d| seen.insert(d.trim_end_matches('/').to_string()));
    dirs
}

fn parse_desktop(path: &str) -> Option<HashMap<String, String>> {
    let text = std::fs::read_to_string(path).ok()?;
    let mut in_entry = false;
    let mut out = HashMap::new();
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            in_entry = line == "[Desktop Entry]";
            continue;
        }
        if !in_entry {
            continue;
        }
        if let Some((k, v)) = line.split_once('=') {
            out.entry(k.trim().to_string()).or_insert_with(|| v.trim().to_string());
        }
    }
    Some(out)
}

pub fn list() -> Vec<App> {
    let mut by_id: HashMap<String, App> = HashMap::new();
    for dir in data_dirs() {
        let apps_dir = fsx::join(&dir, "applications");
        let mut pending = vec![apps_dir.clone()];
        while let Some(d) = pending.pop() {
            for name in fsx::list_names(&d) {
                let path = fsx::join(&d, &name);
                if fsx::is_dir(&path) {
                    pending.push(path);
                    continue;
                }
                if !name.ends_with(".desktop") {
                    continue;
                }
                // Desktop ids use '-' for subfolders; the first data dir wins, like the menu.
                let id = path[apps_dir.len() + 1..].replace('/', "-");
                if by_id.contains_key(&id) {
                    continue;
                }
                if let Some(app) = app(&path, &id) {
                    by_id.insert(id, app);
                } else {
                    // A hidden entry still hides the same id further down the list.
                    by_id.insert(id, App::default());
                }
            }
        }
    }
    let mut apps: Vec<App> = by_id.into_values().filter(|a| !a.id.is_empty()).collect();
    apps.sort_by_key(|a| a.name.to_lowercase());
    apps
}

fn app(path: &str, id: &str) -> Option<App> {
    let entry = parse_desktop(path)?;
    let get = |k: &str| entry.get(k).cloned().filter(|v| !v.is_empty());
    if get("Type").as_deref() != Some("Application") || get("NoDisplay").as_deref() == Some("true") || get("Hidden").as_deref() == Some("true") {
        return None;
    }
    let name = get("Name")?;
    let exec = get("Exec").unwrap_or_default();
    let first = exec.split_whitespace().find(|w| !w.contains('=') || w.starts_with('/')).unwrap_or("").trim_matches('"').to_string();
    let program = resolve(&first);
    let flatpak = get("X-Flatpak");
    let snap = get("X-SnapInstanceName").or_else(|| path.starts_with("/var/lib/snapd/").then(|| id.split('_').next().unwrap_or(id).trim_end_matches(".desktop").to_string()));
    let appimage = [program.clone(), get("TryExec")].into_iter().flatten().find(|p| p.to_lowercase().ends_with(".appimage") && fsx::exists(p));
    let uninstaller = if flatpak.is_some() || snap.is_some() || !path.starts_with(&fsx::home()) {
        Some("Uninstall Package".to_string())
    } else {
        None
    };
    let detail = flatpak.clone().map(|f| format!("Flatpak · {f}")).or_else(|| snap.clone().map(|s| format!("Snap · {s}"))).or_else(|| appimage.as_ref().map(|_| "AppImage".to_string()));
    Some(App {
        id: path.to_string(),
        name,
        version: get("X-AppImage-Version"),
        detail,
        location: appimage.clone().or_else(|| Some(path.to_string())),
        icon: get("Icon").and_then(|i| icon_file(&i)),
        uninstaller: if appimage.is_some() { None } else { uninstaller },
        size: None,
        extra: Extra { desktop_file: path.to_string(), desktop_id: id.trim_end_matches(".desktop").to_string(), program, flatpak, snap, appimage },
    })
}

/// A program name from Exec, found on PATH.
fn resolve(program: &str) -> Option<String> {
    if program.is_empty() {
        return None;
    }
    if program.starts_with('/') {
        return Some(program.to_string());
    }
    std::env::var("PATH").ok()?.split(':').map(|d| fsx::join(d, program)).find(|p| fsx::exists(p))
}

/// The icon theme file for an Icon= name (a PNG or SVG), largest first.
fn icon_file(icon: &str) -> Option<String> {
    if icon.starts_with('/') {
        return fsx::exists(icon).then(|| icon.to_string());
    }
    let sizes = ["256x256", "128x128", "scalable", "96x96", "64x64", "48x48", "32x32"];
    for dir in data_dirs() {
        for theme in ["hicolor", "Adwaita", "breeze"] {
            for size in sizes {
                for ext in ["png", "svg"] {
                    let path = fsx::join(&dir, &format!("icons/{theme}/{size}/apps/{icon}.{ext}"));
                    if fsx::exists(&path) {
                        return Some(path);
                    }
                }
            }
        }
        for ext in ["png", "svg"] {
            let path = fsx::join(&dir, &format!("pixmaps/{icon}.{ext}"));
            if fsx::exists(&path) {
                return Some(path);
            }
        }
    }
    None
}

pub fn open(path: &str) -> Result<App, String> {
    if path.ends_with(".desktop") {
        return app(path, &fsx::name(path)).ok_or_else(|| "That desktop entry doesn't describe an app.".into());
    }
    if path.to_lowercase().ends_with(".appimage") {
        let name = fsx::name(path);
        let stem = name.split(['-', '_', '.']).next().unwrap_or(&name).to_string();
        return Ok(App {
            id: path.into(),
            name: stem.clone(),
            detail: Some("AppImage".into()),
            location: Some(path.into()),
            extra: Extra { program: Some(path.into()), appimage: Some(path.into()), desktop_id: stem.to_lowercase(), ..Default::default() },
            ..Default::default()
        });
    }
    Err("Choose an app's .desktop file or an AppImage.".into())
}

/// The installed package that owns `file`, and the command that removes it.
fn package_of(file: &str) -> Option<(String, Vec<String>)> {
    let run = |cmd: &str, args: &[&str]| -> Option<String> {
        let out = Command::new(cmd).args(args).output().ok()?;
        out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_string()).filter(|s| !s.is_empty())
    };
    if let Some(out) = run("dpkg", &["-S", file]) {
        let pkg = out.lines().next()?.split(':').next()?.trim().to_string();
        return Some((pkg.clone(), vec!["pkexec".into(), "apt-get".into(), "remove".into(), "-y".into(), pkg]));
    }
    if let Some(pkg) = run("rpm", &["-qf", "--qf", "%{NAME}", file]) {
        let tool = if resolve("dnf").is_some() { "dnf" } else if resolve("zypper").is_some() { "zypper" } else { "yum" };
        let mut cmd = vec!["pkexec".to_string(), tool.into(), "remove".into(), "-y".into(), pkg.clone()];
        if tool == "zypper" {
            cmd = vec!["pkexec".into(), "zypper".into(), "--non-interactive".into(), "remove".into(), pkg.clone()];
        }
        return Some((pkg, cmd));
    }
    if let Some(pkg) = run("pacman", &["-Qqo", file]) {
        return Some((pkg.clone(), vec!["pkexec".into(), "pacman".into(), "-R".into(), "--noconfirm".into(), pkg]));
    }
    None
}

fn uninstall_command(app: &App) -> Result<Vec<String>, String> {
    if let Some(id) = &app.extra.flatpak {
        return Ok(vec!["flatpak".into(), "uninstall".into(), "-y".into(), "--noninteractive".into(), id.clone()]);
    }
    if let Some(snap) = &app.extra.snap {
        return Ok(vec!["pkexec".into(), "snap".into(), "remove".into(), snap.clone()]);
    }
    package_of(&app.extra.desktop_file).map(|(_, cmd)| cmd).ok_or_else(|| "No package manager owns this app. Remove its files below instead.".into())
}

/// Runs the package manager's remove (asking for the administrator password when it needs it).
pub fn run_uninstaller(app: &App) -> Result<(), String> {
    let cmd = uninstall_command(app)?;
    let out = Command::new(&cmd[0]).args(&cmd[1..]).output().map_err(|e| format!("{}: {e}", cmd[0]))?;
    match out.status.code() {
        Some(0) => Ok(()),
        Some(126) => Err("Cancelled.".into()),
        _ => {
            let err = String::from_utf8_lossy(&out.stderr).trim().lines().last().unwrap_or("").to_string();
            Err(if err.is_empty() { "The package manager couldn't remove it.".into() } else { err })
        }
    }
}

pub fn pids(app: &App) -> Vec<i32> {
    let Some(program) = app.extra.appimage.clone().or_else(|| app.extra.program.clone()) else { return vec![] };
    let program = fsx::real_path(&program);
    let mut out = vec![];
    for entry in fsx::list_names("/proc") {
        let Ok(pid) = entry.parse::<i32>() else { continue };
        let Ok(exe) = std::fs::read_link(format!("/proc/{pid}/exe")) else { continue };
        if exe.to_string_lossy() == program {
            out.push(pid);
        }
    }
    out
}

pub fn terminate(pids: &[i32]) {
    for &pid in pids {
        unsafe { libc::kill(pid, libc::SIGTERM) };
    }
}

pub fn inspect(app: &App, _all: &[App]) -> Inspection {
    let home = fsx::home();
    let xdg = |var: &str, rel: &str| std::env::var(var).ok().filter(|d| !d.is_empty()).unwrap_or_else(|| fsx::join(&home, rel));
    let (config, cache, data, state) = (xdg("XDG_CONFIG_HOME", ".config"), xdg("XDG_CACHE_HOME", ".cache"), xdg("XDG_DATA_HOME", ".local/share"), xdg("XDG_STATE_HOME", ".local/state"));
    let mut hits = Hits::default();
    let mut listings = Listings::default();
    let x = &app.extra;
    if let Some(image) = &x.appimage {
        hits.add(image, "application", Confidence::Exact);
    }
    // A desktop entry in the home folder is the user's own copy; one from a package goes with the package.
    if x.desktop_file.starts_with(&home) {
        hits.add(&x.desktop_file, "shortcuts", Confidence::Exact);
    }
    if let Some(id) = &x.flatpak {
        hits.add(&fsx::join(&home, &format!(".var/app/{id}")), "packageData", Confidence::Exact);
    }
    if let Some(snap) = &x.snap {
        hits.add(&fsx::join(&home, &format!("snap/{snap}")), "packageData", Confidence::Exact);
    }
    for name in names(app) {
        for (base, kind) in [(&config, "preferences"), (&cache, "caches"), (&data, "support"), (&state, "support")] {
            hits.add_child(base, &name, kind, Confidence::Exact, &mut listings);
        }
        hits.add_child(&home, &format!(".{name}"), "homeData", Confidence::Exact, &mut listings);
        hits.add_child(&fsx::join(&config, "autostart"), &format!("{name}.desktop"), "autostart", Confidence::Exact, &mut listings);
    }
    hits.add_child(&fsx::join(&config, "autostart"), &format!("{}.desktop", x.desktop_id), "autostart", Confidence::Exact, &mut listings);
    // Same-named folders that only share a word with the app's name.
    for (base, kind) in [(&config, "preferences"), (&cache, "caches"), (&data, "support")] {
        for entry in listings.get(base) {
            if fsx::contains_word(&entry, &app.name) {
                hits.add(&fsx::join(base, &entry), kind, Confidence::NameOnly);
            }
        }
    }
    let mut needles = vec![x.desktop_id.clone()];
    needles.extend(x.appimage.clone());
    let word = x.program.as_deref().map(fsx::name).unwrap_or_else(|| app.name.clone());
    let never = vec![home.clone(), config, cache, data, state, fsx::join(&home, ".var/app"), fsx::join(&home, "snap")];
    Inspection { leftovers: hits.finish(&never), mentions: super::mentions(&needles, &word) }
}

/// Folder names the app's files go by: its program, desktop id (and its last part), and name.
fn names(app: &App) -> Vec<String> {
    let x = &app.extra;
    let mut out = vec![app.name.clone(), x.desktop_id.clone()];
    if let Some(last) = x.desktop_id.rsplit('.').next() {
        out.push(last.to_string());
    }
    if let Some(program) = &x.program {
        if !program.to_lowercase().ends_with(".appimage") {
            out.push(fsx::name(program));
        }
    }
    if let Some(snap) = &x.snap {
        out.push(snap.clone());
    }
    out.retain(|n| n.len() > 1 && !PERSONAL.contains(&n.to_lowercase().as_str()) && !PERSONAL.contains(&format!(".{}", n.to_lowercase()).as_str()));
    out.sort();
    out.dedup();
    out
}
