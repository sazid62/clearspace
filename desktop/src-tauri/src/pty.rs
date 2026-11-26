//! One shell per terminal tab, behind a pseudo-terminal (ConPTY on Windows, openpty elsewhere).
//! Output streams to the window over a Tauri channel; keystrokes come back through `pty_write`.

use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};
use serde::Serialize;
use std::collections::HashMap;
use std::io::{Read, Write};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::ipc::Channel;

#[derive(Clone, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum PtyEvent {
    Data { data: String },
    Exit { code: Option<u32> },
}

struct Session {
    master: Box<dyn MasterPty + Send>,
    writer: Arc<Mutex<Box<dyn Write + Send>>>,
    killer: Box<dyn ChildKiller + Send + Sync>,
    pid: Option<u32>,
}

#[derive(Default)]
pub struct Ptys(Mutex<HashMap<String, Session>>);

impl Ptys {
    pub fn kill_all(&self) {
        let mut sessions = self.0.lock().unwrap();
        for (_, mut session) in sessions.drain() {
            let _ = session.killer.kill();
        }
    }
}

/// Starts (or restarts) the shell for tab `id` in `cwd`, then types `startup` into it.
#[tauri::command]
pub fn pty_spawn(
    state: tauri::State<'_, Ptys>,
    id: String,
    cwd: Option<String>,
    cols: u16,
    rows: u16,
    startup: Option<String>,
    events: Channel<PtyEvent>,
) -> Result<(), String> {
    let pair = native_pty_system()
        .openpty(PtySize { rows: rows.max(2), cols: cols.max(2), pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())?;

    let mut cmd = shell_command();
    let home = dirs::home_dir().map(|p| p.to_string_lossy().into_owned());
    let dir = cwd.filter(|d| std::path::Path::new(d).is_dir()).or(home);
    if let Some(dir) = dir {
        cmd.cwd(dir);
    }
    cmd.env("TERM", "xterm-256color");
    cmd.env("COLORTERM", "truecolor");
    cmd.env("TERM_PROGRAM", "Clearspace");
    if std::env::var_os("LANG").is_none() && !cfg!(windows) {
        cmd.env("LANG", "en_US.UTF-8");
    }
    for (key, _) in std::env::vars_os() {
        if key.to_string_lossy().starts_with("CLEARSPACE_") {
            cmd.env_remove(key);
        }
    }

    let mut child = pair.slave.spawn_command(cmd).map_err(|e| e.to_string())?;
    drop(pair.slave);
    let mut reader = pair.master.try_clone_reader().map_err(|e| e.to_string())?;
    let writer = Arc::new(Mutex::new(pair.master.take_writer().map_err(|e| e.to_string())?));
    let killer = child.clone_killer();
    let pid = child.process_id();
    // When the shell last printed something; None until its first output.
    let last_output: Arc<Mutex<Option<Instant>>> = Arc::new(Mutex::new(None));

    if let Some(command) = startup.map(|s| s.trim().to_string()).filter(|s| !s.is_empty()) {
        // Type the command once the shell has drawn its prompt (output went quiet), as a person
        // would; typed earlier it shows up twice, and some shells drop it.
        let writer = writer.clone();
        let last_output = last_output.clone();
        thread::spawn(move || {
            let started = Instant::now();
            loop {
                thread::sleep(Duration::from_millis(50));
                let quiet = last_output.lock().unwrap().is_some_and(|t| t.elapsed() >= Duration::from_millis(300));
                if quiet || started.elapsed() >= Duration::from_secs(8) {
                    break;
                }
            }
            let mut writer = writer.lock().unwrap();
            let _ = writer.write_all(format!("{command}\r").as_bytes());
            let _ = writer.flush();
        });
    }

    let output = events.clone();
    let seen = last_output.clone();
    thread::spawn(move || {
        let mut buf = [0u8; 64 * 1024];
        let mut pending: Vec<u8> = Vec::new();
        loop {
            match reader.read(&mut buf) {
                Ok(0) | Err(_) => break,
                Ok(n) => {
                    *seen.lock().unwrap() = Some(Instant::now());
                    pending.extend_from_slice(&buf[..n]);
                    // Hold back a multi-byte character split across reads.
                    let valid = match std::str::from_utf8(&pending) {
                        Ok(_) => pending.len(),
                        Err(e) if e.error_len().is_none() => e.valid_up_to(),
                        Err(_) => pending.len(),
                    };
                    if valid > 0 {
                        let text = String::from_utf8_lossy(&pending[..valid]).into_owned();
                        pending.drain(..valid);
                        if output.send(PtyEvent::Data { data: text }).is_err() {
                            break;
                        }
                    }
                }
            }
        }
    });

    thread::spawn(move || {
        let code = child.wait().ok().map(|s| s.exit_code());
        // Let the last output reach the window first (ConPTY never signals end-of-output).
        thread::sleep(Duration::from_millis(80));
        let _ = events.send(PtyEvent::Exit { code });
    });

    let previous = state.0.lock().unwrap().insert(id, Session { master: pair.master, writer, killer, pid });
    if let Some(mut old) = previous {
        let _ = old.killer.kill();
    }
    Ok(())
}

#[tauri::command]
pub fn pty_write(state: tauri::State<'_, Ptys>, id: String, data: String) -> Result<(), String> {
    let writer = state.0.lock().unwrap().get(&id).ok_or("no such tab")?.writer.clone();
    let mut writer = writer.lock().unwrap();
    writer.write_all(data.as_bytes()).map_err(|e| e.to_string())?;
    writer.flush().map_err(|e| e.to_string())
}

#[tauri::command]
pub fn pty_resize(state: tauri::State<'_, Ptys>, id: String, cols: u16, rows: u16) -> Result<(), String> {
    let sessions = state.0.lock().unwrap();
    let session = sessions.get(&id).ok_or("no such tab")?;
    session
        .master
        .resize(PtySize { rows: rows.max(2), cols: cols.max(2), pixel_width: 0, pixel_height: 0 })
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn pty_kill(state: tauri::State<'_, Ptys>, id: String) {
    if let Some(mut session) = state.0.lock().unwrap().remove(&id) {
        let _ = session.killer.kill();
    }
}

/// The shell's current folder, read from the OS (macOS, Linux). Windows reports it through OSC 7 instead.
#[tauri::command]
pub fn pty_cwd(state: tauri::State<'_, Ptys>, ids: Vec<String>) -> HashMap<String, String> {
    let sessions = state.0.lock().unwrap();
    ids.into_iter()
        .filter_map(|id| {
            let pid = sessions.get(&id)?.pid?;
            Some((id, crate::cwd::of(pid)?))
        })
        .collect()
}

#[cfg(unix)]
fn shell_command() -> CommandBuilder {
    // The user's login shell, started as "-zsh" etc. so their profile sets PATH, as Terminal.app does.
    CommandBuilder::new_default_prog()
}

#[cfg(windows)]
fn shell_command() -> CommandBuilder {
    // PowerShell 7 when installed, else Windows PowerShell. The prompt wrapper reports the folder
    // with OSC 7 so tabs reopen where they were; the user's own prompt still runs.
    const PROMPT: &str = "$__csPrompt = $function:prompt; function global:prompt { \
        $l = $executionContext.SessionState.Path.CurrentLocation; $o = ''; \
        if ($l.Provider.Name -eq 'FileSystem') { $o = [char]27 + ']7;file://localhost/' + ($l.ProviderPath -replace '\\\\', '/') + [char]7 }; \
        $o + (& $__csPrompt) }";
    let exe = if which("pwsh.exe") { "pwsh.exe" } else { "powershell.exe" };
    let mut cmd = CommandBuilder::new(exe);
    cmd.arg("-NoLogo");
    cmd.arg("-NoExit");
    cmd.arg("-EncodedCommand");
    cmd.arg(encode_utf16_base64(PROMPT));
    cmd
}

#[cfg(windows)]
fn which(exe: &str) -> bool {
    std::env::var_os("PATH")
        .map(|paths| std::env::split_paths(&paths).any(|dir| dir.join(exe).is_file()))
        .unwrap_or(false)
}

/// PowerShell's -EncodedCommand takes base64 of UTF-16LE, which sidesteps command-line quoting.
#[cfg_attr(not(windows), allow(dead_code))]
pub(crate) fn encode_utf16_base64(text: &str) -> String {
    const ALPHABET: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let bytes: Vec<u8> = text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let n = (chunk[0] as u32) << 16 | (*chunk.get(1).unwrap_or(&0) as u32) << 8 | *chunk.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::encode_utf16_base64;

    #[test]
    fn encodes_like_powershell() {
        // [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes('dir'))
        assert_eq!(encode_utf16_base64("dir"), "ZABpAHIA");
        assert_eq!(encode_utf16_base64("ab"), "YQBiAA==");
    }
}
