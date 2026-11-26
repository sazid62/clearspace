//! Windows: programs from the "Installed apps" list (the registry's Uninstall keys). Removing one
//! runs the program's own uninstaller first, then offers what it left behind in AppData,
//! ProgramData, the install folder and the Start menu.

use super::{App, Confidence, Hits, Inspection, Listings, PERSONAL};
use crate::clean::fsx;
use crate::clean::temp::env_dir;
use std::os::windows::process::CommandExt;
use winreg::enums::{HKEY_CURRENT_USER, HKEY_LOCAL_MACHINE, KEY_READ, KEY_WOW64_32KEY, KEY_WOW64_64KEY};
use winreg::RegKey;

const NO_WINDOW: u32 = 0x0800_0000;
const UNINSTALL: &str = r"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall";

#[derive(Clone, Debug, Default)]
pub struct Extra {
    pub install_dir: Option<String>,
    pub publisher: Option<String>,
    pub uninstall_command: Option<String>,
}

pub fn list() -> Vec<App> {
    let mut apps: Vec<App> = vec![];
    let sources = [
        (HKEY_LOCAL_MACHINE, KEY_WOW64_64KEY, "HKLM"),
        (HKEY_LOCAL_MACHINE, KEY_WOW64_32KEY, "HKLM32"),
        (HKEY_CURRENT_USER, 0, "HKCU"),
    ];
    for (hive, view, label) in sources {
        let Ok(key) = RegKey::predef(hive).open_subkey_with_flags(UNINSTALL, KEY_READ | view) else { continue };
        for sub in key.enum_keys().flatten() {
            let Ok(entry) = key.open_subkey_with_flags(&sub, KEY_READ | view) else { continue };
            let text = |name: &str| entry.get_value::<String, _>(name).ok().map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
            let number = |name: &str| entry.get_value::<u32, _>(name).ok();
            let Some(name) = text("DisplayName") else { continue };
            // Updates, system parts and entries with no way to uninstall aren't apps people remove.
            if number("SystemComponent") == Some(1) || text("ParentKeyName").is_some() || matches!(text("ReleaseType").as_deref(), Some("Update" | "Hotfix" | "Security Update")) {
                continue;
            }
            let Some(command) = text("UninstallString") else { continue };
            let install_dir = text("InstallLocation").map(|d| d.trim_matches('"').trim_end_matches('\\').to_string()).filter(|d| fsx::is_dir(d));
            let icon_exe = text("DisplayIcon").map(|i| i.split(',').next().unwrap_or("").trim_matches('"').to_string()).filter(|p| fsx::exists(p));
            let location = install_dir.clone().or_else(|| icon_exe.as_ref().map(|e| fsx::parent(e)));
            let id = format!("{label}\\{sub}");
            if apps.iter().any(|a| a.name == name && a.version == text("DisplayVersion")) {
                continue; // listed in both registry views
            }
            apps.push(App {
                id,
                name,
                version: text("DisplayVersion"),
                detail: text("Publisher"),
                location,
                icon: icon_exe,
                uninstaller: Some("Run Uninstaller".into()),
                size: number("EstimatedSize").map(|kb| kb as u64 * 1024),
                extra: Extra { install_dir, publisher: text("Publisher"), uninstall_command: Some(command) },
            });
        }
    }
    apps.sort_by_key(|a| a.name.to_lowercase());
    apps
}

pub fn open(_path: &str) -> Result<App, String> {
    Err("Pick the program from the list. Windows programs are removed with their own uninstaller.".into())
}

/// Runs the program's own uninstaller (it may ask for administrator rights) and waits for it.
pub fn run_uninstaller(app: &App) -> Result<(), String> {
    let command = app.extra.uninstall_command.clone().ok_or("This program has no uninstaller.")?;
    let (exe, args) = split_command(&command);
    let quote = |s: &str| format!("'{}'", s.replace('\'', "''"));
    let mut script = format!("$ErrorActionPreference = 'Stop'; try {{ Start-Process -FilePath {} -Wait", quote(&exe));
    if !args.is_empty() {
        script += &format!(" -ArgumentList {}", quote(&args));
    }
    script += " } catch { Write-Output $_.Exception.Message; exit 2 }";
    let out = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-EncodedCommand", &crate::pty::encode_utf16_base64(&script)])
        .creation_flags(NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() { Ok(()) } else { Err(String::from_utf8_lossy(&out.stdout).trim().to_string()) }
}

/// `"C:\x\uninst.exe" /S` or `MsiExec.exe /X{GUID}` → (program, arguments).
fn split_command(command: &str) -> (String, String) {
    let command = command.trim();
    if let Some(rest) = command.strip_prefix('"') {
        if let Some(end) = rest.find('"') {
            return (rest[..end].to_string(), rest[end + 1..].trim().to_string());
        }
    }
    if let Some(i) = command.to_lowercase().find(".exe") {
        let end = i + 4;
        return (command[..end].to_string(), command[end..].trim().to_string());
    }
    match command.split_once(' ') {
        Some((exe, args)) => (exe.to_string(), args.trim().to_string()),
        None => (command.to_string(), String::new()),
    }
}

pub fn pids(app: &App) -> Vec<i32> {
    let Some(dir) = app.extra.install_dir.clone() else { return vec![] };
    let script = format!("Get-Process | Where-Object {{ $_.Path -like '{}\\*' }} | ForEach-Object {{ $_.Id }}", dir.replace('\'', "''"));
    let Ok(out) = std::process::Command::new("powershell.exe").args(["-NoProfile", "-EncodedCommand", &crate::pty::encode_utf16_base64(&script)]).creation_flags(NO_WINDOW).output() else { return vec![] };
    String::from_utf8_lossy(&out.stdout).lines().filter_map(|l| l.trim().parse().ok()).collect()
}

/// Asks each program to close (like clicking its close button), so it can save first.
pub fn terminate(pids: &[i32]) {
    for pid in pids {
        let _ = std::process::Command::new("taskkill").args(["/PID", &pid.to_string()]).creation_flags(NO_WINDOW).output();
    }
}

pub fn inspect(app: &App, _all: &[App]) -> Inspection {
    let home = fsx::home();
    let roaming = env_dir("APPDATA", "AppData/Roaming");
    let local = env_dir("LOCALAPPDATA", "AppData/Local");
    let program_data = std::env::var("PROGRAMDATA").unwrap_or_else(|_| r"C:\ProgramData".into());
    let mut hits = Hits::default();
    let mut listings = Listings::default();
    if let Some(dir) = &app.extra.install_dir {
        // Program Files itself is never one program's.
        if fsx::parent(dir).len() > 3 {
            hits.add(dir, "application", Confidence::Exact);
        }
    }
    let names = names(app);
    let publisher = app.extra.publisher.clone().unwrap_or_default();
    for (base, kind) in [(&roaming, "appData"), (&local, "localData"), (&program_data, "sharedData")] {
        for name in &names {
            hits.add_child(base, name, kind, Confidence::Exact, &mut listings);
            if !publisher.is_empty() {
                let vendor = listings.get(base).into_iter().find(|e| e.eq_ignore_ascii_case(&publisher) || fsx::contains_word(&publisher, e) && e.len() > 2);
                if let Some(vendor) = vendor {
                    hits.add_child(&fsx::join(base, &vendor), name, kind, Confidence::Exact, &mut listings);
                }
            }
        }
        hits.add_child(&fsx::join(&local, "Programs"), &app.name, "application", Confidence::Exact, &mut listings);
    }
    // Start menu and desktop shortcuts.
    let menus = [fsx::join(&roaming, "Microsoft/Windows/Start Menu/Programs"), fsx::join(&program_data, "Microsoft/Windows/Start Menu/Programs")];
    let desktops = [fsx::join(&home, "Desktop"), std::env::var("PUBLIC").map(|p| fsx::join(&p, "Desktop")).unwrap_or_default()];
    for dir in menus.iter().chain(desktops.iter()) {
        for entry in listings.get(dir) {
            let stem = entry.strip_suffix(".lnk").unwrap_or(&entry);
            let exact = names.iter().any(|n| stem.eq_ignore_ascii_case(n)) || stem.eq_ignore_ascii_case(&app.name);
            if exact {
                hits.add(&fsx::join(dir, &entry), "shortcuts", Confidence::Exact);
            } else if entry.ends_with(".lnk") && fsx::contains_word(stem, &app.name) {
                hits.add(&fsx::join(dir, &entry), "shortcuts", Confidence::NameOnly);
            }
        }
    }
    let never = vec![roaming, local, program_data, home];
    Inspection { leftovers: hits.finish(&never, &[]), mentions: vec![] }
}

/// Names the program's folders go by: its display name with and without the version, and the
/// install folder's own name.
fn names(app: &App) -> Vec<String> {
    let mut out = vec![app.name.clone()];
    if let Some(version) = &app.version {
        let trimmed = app.name.replace(version.as_str(), "").trim().trim_end_matches(['-', '(', ')', 'v']).trim().to_string();
        out.push(trimmed);
    }
    if let Some(dir) = &app.extra.install_dir {
        out.push(fsx::name(dir));
    }
    out.retain(|n| n.len() > 1 && !PERSONAL.contains(&n.to_lowercase().as_str()));
    out.sort();
    out.dedup();
    out
}

#[cfg(test)]
mod tests {
    #[test]
    fn splits_uninstall_commands() {
        assert_eq!(super::split_command(r#""C:\A B\uninst.exe" /S"#), (r"C:\A B\uninst.exe".into(), "/S".into()));
        assert_eq!(super::split_command("MsiExec.exe /X{1}"), ("MsiExec.exe".into(), "/X{1}".into()));
    }
}
