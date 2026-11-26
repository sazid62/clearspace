//! Maintenance: small system chores (flush the DNS cache, rebuild an index, clear package
//! downloads) that the system offers as commands. Each task shows the command it runs. Tasks
//! that need administrator rights run together behind one system prompt.

use super::remove::AdminResult;
use super::settings;
use serde::Serialize;
use std::collections::HashMap;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Task {
    pub id: &'static str,
    pub title: &'static str,
    pub detail: &'static str,
    /// What it runs: sh on macOS and Linux, PowerShell on Windows.
    pub command: String,
    /// Asks for the administrator password.
    pub admin: bool,
    /// Something to know before running it.
    pub caution: Option<&'static str>,
}

fn task(id: &'static str, title: &'static str, detail: &'static str, command: &str, admin: bool, caution: Option<&'static str>) -> Task {
    Task { id, title, detail, command: command.into(), admin, caution }
}

/// A program on PATH or in the system folders (administrator tools aren't on every user's PATH).
#[cfg(target_os = "linux")]
fn has(program: &str) -> bool {
    let path = std::env::var("PATH").unwrap_or_default();
    path.split(':').chain(["/usr/bin", "/bin", "/usr/sbin", "/sbin", "/usr/local/bin"]).any(|dir| !dir.is_empty() && std::path::Path::new(dir).join(program).exists())
}

/// The tasks this machine can run.
pub fn tasks() -> Vec<Task> {
    #[cfg(target_os = "macos")]
    return mac_tasks();
    #[cfg(target_os = "linux")]
    return linux_tasks();
    #[cfg(windows)]
    return windows_tasks();
}

#[cfg(target_os = "macos")]
const LSREGISTER: &str = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister";
#[cfg(target_os = "macos")]
const SUDO_LOCAL: &str = "/etc/pam.d/sudo_local";

/// Touch ID answers sudo when /etc/pam.d/sudo_local carries the pam_tid line.
#[cfg(any(target_os = "macos", test))]
fn touch_id_enabled(sudo_local: &str) -> bool {
    sudo_local.lines().any(|l| {
        let l = l.trim();
        !l.starts_with('#') && l.starts_with("auth") && l.contains("pam_tid.so")
    })
}

#[cfg(target_os = "macos")]
fn mac_tasks() -> Vec<Task> {
    let mut out = vec![
        task("dns", "Flush the DNS cache", "Fixes sites that won't load after a network or DNS change.", "/usr/bin/dscacheutil -flushcache && /usr/bin/killall -HUP mDNSResponder", true, None),
        task("quicklook", "Reset Quick Look previews", "Clears cached thumbnails and previews. They are drawn again as you browse.", "/usr/bin/qlmanage -r cache && /usr/bin/qlmanage -r", false, None),
        task(
            "openwith",
            "Rebuild the Open With menu",
            "Registers your apps again, which removes duplicate and stale entries from Open With.",
            &format!("{LSREGISTER} -r -f -apps system,local,user && {LSREGISTER} -gc"),
            false,
            None,
        ),
        task("finder", "Restart Finder and the Dock", "Clears stuck icons and a Dock that stopped responding.", "/usr/bin/killall Dock; /usr/bin/killall Finder", false, Some("Open Finder windows close.")),
        task("spotlight", "Rebuild the Spotlight index", "Fixes searches that miss files you know are there.", "/usr/bin/mdutil -E /", true, Some("Search is slower for an hour or so while the index is rebuilt.")),
        task("memory", "Free inactive memory", "Releases memory held for files that are no longer open. macOS does this on its own when it needs to.", "/usr/sbin/purge", true, None),
    ];
    // sudo reads sudo_local since macOS 14; older systems would lose the change on every update.
    let supported = std::fs::read_to_string("/etc/pam.d/sudo").is_ok_and(|t| t.contains("sudo_local")) && super::fsx::list_names("/usr/lib/pam").iter().any(|n| n.starts_with("pam_tid.so"));
    if supported {
        if touch_id_enabled(&std::fs::read_to_string(SUDO_LOCAL).unwrap_or_default()) {
            out.push(task("touchid-off", "Stop using Touch ID for sudo", "Terminal goes back to asking for your password when a command needs administrator rights.", &format!("/usr/bin/sed -i '' '/^auth.*pam_tid\\.so/d' {SUDO_LOCAL}"), true, None));
        } else {
            let line = "auth       sufficient     pam_tid.so";
            let command = format!(
                "f={SUDO_LOCAL}; if [ -f \"$f\" ]; then printf '%s\\n' '{line}' | /bin/cat - \"$f\" > \"$f.new\" && /bin/mv \"$f.new\" \"$f\"; else printf '%s\\n' '# sudo_local: local config file which survives system update and is included for sudo' '{line}' > \"$f\"; fi && /bin/chmod 444 \"$f\""
            );
            out.push(task("touchid-on", "Use Touch ID for sudo", "Lets you approve administrator commands in Terminal with your fingerprint instead of typing your password.", &command, true, None));
        }
    }
    out
}

#[cfg(target_os = "linux")]
fn linux_tasks() -> Vec<Task> {
    let mut out = vec![];
    if has("resolvectl") {
        out.push(task("dns", "Flush the DNS cache", "Fixes sites that won't load after a network or DNS change.", "resolvectl flush-caches", true, None));
    }
    let packages = [
        ("apt-get", "apt-get clean", Some("apt-get autoremove -y")),
        ("dnf", "dnf clean all", Some("dnf autoremove -y")),
        ("pacman", "pacman -Sc --noconfirm", None),
        ("zypper", "zypper --non-interactive clean --all", None),
    ];
    if let Some((_, clean, autoremove)) = packages.into_iter().find(|(tool, ..)| has(tool)) {
        out.push(task("packages", "Clear downloaded packages", "Removes installer files the package manager kept after installing. They are downloaded again if ever needed.", clean, true, None));
        if let Some(autoremove) = autoremove {
            out.push(task("autoremove", "Remove packages nothing needs", "Uninstalls packages that were only installed for something that is gone.", autoremove, true, Some("Check the list first with the same command and --dry-run if you installed things by hand.")));
        }
    }
    if has("journalctl") {
        out.push(task("journal", "Trim system logs to a week", "Deletes system log entries older than seven days.", "journalctl --vacuum-time=7d", true, None));
    }
    if has("fstrim") {
        out.push(task("trim", "Trim the SSD", "Tells the drive which blocks are free, which keeps it fast.", "fstrim -av", true, None));
    }
    if has("flatpak") {
        out.push(task("flatpak", "Remove unused Flatpak runtimes", "Uninstalls runtimes no installed Flatpak app uses.", "flatpak uninstall --unused -y", false, None));
    }
    if has("fc-cache") {
        out.push(task("fonts", "Rebuild the font cache", "Fixes missing or garbled fonts after installing or removing some.", "fc-cache -f", false, None));
    }
    out
}

#[cfg(windows)]
fn windows_tasks() -> Vec<Task> {
    vec![
        task("dns", "Flush the DNS cache", "Fixes sites that won't load after a network or DNS change.", "ipconfig.exe /flushdns", false, None),
        task("recycle", "Empty the Recycle Bin", "Deletes everything in the Recycle Bin for good.", "Clear-RecycleBin -Force -ErrorAction SilentlyContinue", false, Some("This can't be undone.")),
        task("icons", "Refresh the icon cache", "Fixes blank or wrong icons on the desktop and in the Start menu.", "ie4uinit.exe -show", false, None),
        task(
            "updates",
            "Clean up Windows Update leftovers",
            "Removes old versions of system components that updates replaced.",
            "dism.exe /Online /Cleanup-Image /StartComponentCleanup",
            true,
            Some("Takes several minutes."),
        ),
        task("drive", "Optimize the system drive", "Trims an SSD or defragments a hard disk, whichever the drive needs.", "defrag.exe $env:SystemDrive /O", true, Some("Can take a while on a hard disk.")),
    ]
}

#[derive(Serialize, Clone, Debug)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    Start { id: String },
    Outcome { id: String, ok: bool, message: String },
    Finished,
}

/// Runs the chosen tasks: the plain ones one by one, then the administrator ones together
/// behind a single prompt.
pub fn run(ids: &[String], send: &dyn Fn(Event)) {
    let chosen: Vec<Task> = tasks().into_iter().filter(|t| ids.iter().any(|id| id == t.id)).collect();
    let mut done = vec![];
    for t in chosen.iter().filter(|t| !t.admin) {
        send(Event::Start { id: t.id.into() });
        let (ok, message) = run_plain(&t.command);
        if ok {
            done.push(settings::Entry::now("task", t.title, 0, "maintenance"));
        }
        send(Event::Outcome { id: t.id.into(), ok, message });
    }
    let admin: Vec<&Task> = chosen.iter().filter(|t| t.admin).collect();
    if !admin.is_empty() {
        for t in &admin {
            send(Event::Start { id: t.id.into() });
        }
        let results = std::env::temp_dir().join(format!("clearspace-maintain-{}-{}.txt", std::process::id(), super::fsx::now_secs()));
        // Made here so it stays this user's file even though an administrator writes to it.
        let _ = std::fs::write(&results, "");
        let outcome = run_admin(&admin_script(&admin, &results.to_string_lossy()));
        let codes = parse_results(&std::fs::read_to_string(&results).unwrap_or_default());
        let _ = std::fs::remove_file(&results);
        for t in admin {
            let (ok, message) = match (codes.get(t.id), &outcome) {
                (Some(0), _) => (true, "Done.".to_string()),
                (Some(code), _) => (false, format!("The command failed (exit code {code}).")),
                (None, AdminResult::Cancelled) => (false, "Cancelled.".into()),
                (None, AdminResult::Failed { message }) => (false, message.clone()),
                (None, AdminResult::Completed) => (false, "It didn't run.".into()),
            };
            if ok {
                done.push(settings::Entry::now("task", t.title, 0, "maintenance"));
            }
            send(Event::Outcome { id: t.id.into(), ok, message });
        }
    }
    settings::record(&done);
    send(Event::Finished);
}

/// The last line a command printed, which is where tools put their verdict.
fn last_line(text: &[u8]) -> String {
    String::from_utf8_lossy(text).lines().map(str::trim).filter(|l| !l.is_empty()).next_back().unwrap_or("").chars().take(200).collect()
}

fn run_plain(command: &str) -> (bool, String) {
    #[cfg(unix)]
    let result = std::process::Command::new("/bin/sh").args(["-c", command]).stdin(std::process::Stdio::null()).output();
    #[cfg(windows)]
    let result = {
        use std::os::windows::process::CommandExt;
        const NO_WINDOW: u32 = 0x0800_0000;
        let script = format!("$LASTEXITCODE = 0; {command}; exit $LASTEXITCODE");
        std::process::Command::new("powershell.exe").args(["-NoProfile", "-EncodedCommand", &crate::pty::encode_utf16_base64(&script)]).creation_flags(NO_WINDOW).output()
    };
    match result {
        Ok(out) if out.status.success() => (true, "Done.".into()),
        Ok(out) => {
            let line = last_line(if out.stderr.is_empty() { &out.stdout } else { &out.stderr });
            (false, if line.is_empty() { "The command failed.".into() } else { line })
        }
        Err(e) => (false, e.to_string()),
    }
}

/// One script for every administrator task; each writes "<id> <exit code>" to `results`.
fn admin_script(tasks: &[&Task], results: &str) -> String {
    if cfg!(windows) {
        let quoted = format!("'{}'", results.replace('\'', "''"));
        let mut script = String::new();
        for t in tasks {
            script += &format!("$LASTEXITCODE = 0; try {{ {} | Out-Null; $code = $LASTEXITCODE }} catch {{ $code = 1 }}; \"{} $code\" | Add-Content -LiteralPath {quoted}\n", t.command, t.id);
        }
        script
    } else {
        let quoted = super::remove::shell_quoted(results);
        tasks.iter().map(|t| format!("( {} ) >/dev/null 2>&1; echo \"{} $?\" >> {quoted}\n", t.command, t.id)).collect()
    }
}

fn parse_results(text: &str) -> HashMap<String, i32> {
    text.lines().filter_map(|l| l.trim().rsplit_once(' ')).filter_map(|(id, code)| Some((id.to_string(), code.parse().ok()?))).collect()
}

fn run_admin(script: &str) -> AdminResult {
    #[cfg(target_os = "macos")]
    {
        let escaped = script.trim_end().replace('\\', r"\\").replace('"', "\\\"").replace('\n', "; ");
        super::mac::run_admin_script(&format!("do shell script \"{escaped}\" with administrator privileges"))
    }
    #[cfg(target_os = "linux")]
    {
        match std::process::Command::new("pkexec").args(["sh", "-c", script]).output() {
            // pkexec: 126 = the prompt was dismissed, 127 = not authorized.
            Ok(out) if out.status.code() == Some(126) => AdminResult::Cancelled,
            Ok(out) if out.status.code() == Some(127) => AdminResult::Failed { message: "Not authorized.".into() },
            Ok(_) => AdminResult::Completed,
            Err(e) => AdminResult::Failed { message: format!("Couldn't ask for administrator rights (pkexec: {e}).") },
        }
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const NO_WINDOW: u32 = 0x0800_0000;
        let outer = format!(
            "try {{ Start-Process -FilePath powershell.exe -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList '-NoProfile','-EncodedCommand','{}' }} catch {{ exit 2 }}",
            crate::pty::encode_utf16_base64(script)
        );
        match std::process::Command::new("powershell.exe").args(["-NoProfile", "-EncodedCommand", &crate::pty::encode_utf16_base64(&outer)]).creation_flags(NO_WINDOW).output() {
            Ok(out) if out.status.code() == Some(2) => AdminResult::Cancelled,
            Ok(_) => AdminResult::Completed,
            Err(e) => AdminResult::Failed { message: e.to_string() },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_task_has_its_own_id_and_a_command() {
        let list = tasks();
        let mut ids: Vec<&str> = list.iter().map(|t| t.id).collect();
        ids.sort();
        ids.dedup();
        assert_eq!(ids.len(), list.len());
        assert!(list.iter().all(|t| !t.command.trim().is_empty() && !t.title.is_empty()));
    }

    #[test]
    fn reads_what_the_administrator_script_wrote() {
        let codes = parse_results("dns 0\nspotlight 1\n\ngarbage\n");
        assert_eq!((codes.get("dns"), codes.get("spotlight"), codes.len()), (Some(&0), Some(&1), 2));
    }

    #[cfg(unix)]
    #[test]
    fn the_administrator_script_reports_each_task() {
        let dir = std::env::temp_dir().join(format!("cs-maintain-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let results = dir.join("it's results.txt").to_string_lossy().into_owned();
        let ok = task("good", "Good", "", "true && echo noise", true, None);
        let bad = task("bad", "Bad", "", "false", true, None);
        let script = admin_script(&[&ok, &bad], &results);
        assert!(std::process::Command::new("/bin/sh").args(["-c", &script]).status().unwrap().success());
        let codes = parse_results(&std::fs::read_to_string(&results).unwrap());
        assert_eq!((codes["good"], codes["bad"]), (0, 1));
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[cfg(unix)]
    #[test]
    fn plain_tasks_report_failure_with_the_last_line() {
        assert_eq!(run_plain("true"), (true, "Done.".to_string()));
        assert_eq!(run_plain("echo first >&2; echo why >&2; exit 3"), (false, "why".to_string()));
    }

    #[test]
    fn knows_when_touch_id_is_on() {
        assert!(touch_id_enabled("# comment\nauth       sufficient     pam_tid.so\n"));
        assert!(!touch_id_enabled("#auth       sufficient     pam_tid.so\n"));
        assert!(!touch_id_enabled(""));
    }
}
