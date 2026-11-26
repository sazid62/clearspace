mod clean;
mod cwd;
mod pty;
mod store;
mod swipe;

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, RunEvent, WindowEvent};

/// Set once the window has saved everything; quitting is held back until then (or 2 s pass).
static SAVED: AtomicBool = AtomicBool::new(false);
static SAVING: AtomicBool = AtomicBool::new(false);

#[tauri::command]
fn platform() -> &'static str {
    std::env::consts::OS
}

/// Development aid: with CLEARSPACE_SELFTEST=<scenario> and CLEARSPACE_SELFTEST_DIR set, the window
/// runs a scripted walkthrough, writes snapshots and a log there, then quits. Inert otherwise.
#[tauri::command]
fn selftest_mode() -> Option<String> {
    std::env::var("CLEARSPACE_SELFTEST").ok().filter(|_| std::env::var_os("CLEARSPACE_SELFTEST_DIR").is_some())
}

#[tauri::command]
fn selftest_write(name: String, text: Option<String>, png_base64: Option<String>) -> Result<(), String> {
    let dir = std::path::PathBuf::from(std::env::var_os("CLEARSPACE_SELFTEST_DIR").ok_or("selftest off")?);
    if name.contains(['/', '\\']) || name.contains("..") {
        return Err("bad name".into());
    }
    std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
    if let Some(text) = text {
        std::fs::write(dir.join(&name), text).map_err(|e| e.to_string())?;
    }
    if let Some(b64) = png_base64 {
        std::fs::write(dir.join(&name), decode_base64(&b64)?).map_err(|e| e.to_string())?;
    }
    Ok(())
}

fn decode_base64(text: &str) -> Result<Vec<u8>, String> {
    let value = |c: u8| -> Result<u32, String> {
        Ok(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            _ => return Err("bad base64".into()),
        } as u32)
    };
    let clean: Vec<u8> = text.bytes().filter(|&c| c != b'=' && !c.is_ascii_whitespace()).collect();
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    for chunk in clean.chunks(4) {
        let mut n = 0u32;
        for (i, &c) in chunk.iter().enumerate() {
            n |= value(c)? << (18 - 6 * i);
        }
        let bytes = [(n >> 16) as u8, (n >> 8) as u8, n as u8];
        out.extend_from_slice(&bytes[..chunk.len().saturating_sub(1)]);
    }
    Ok(out)
}

/// The window calls this after saving folders, layout and scrollback on quit.
#[tauri::command]
fn saved_for_quit(app: AppHandle) {
    quit_now(&app);
}

fn quit_now(app: &AppHandle) {
    SAVED.store(true, Ordering::SeqCst);
    app.state::<pty::Ptys>().kill_all();
    app.exit(0);
}

/// Quit, window close, logout and restart all land here: ask the window to save, then quit.
fn save_then_quit(app: &AppHandle) {
    if SAVING.swap(true, Ordering::SeqCst) {
        return;
    }
    let _ = app.emit("clearspace://save-and-quit", ());
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_secs(2));
        quit_now(&app);
    });
}

/// The macOS menu bar, like the native build's: tab and space commands with their usual keys.
/// Items send their id to the window ("clearspace://menu"); Quit saves first.
#[cfg(target_os = "macos")]
fn mac_menu(app: &AppHandle) -> tauri::Result<tauri::menu::Menu<tauri::Wry>> {
    use tauri::menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder};
    let item = |id: &str, text: &str, keys: &str| MenuItemBuilder::with_id(id, text).accelerator(keys).build(app);

    let app_menu = SubmenuBuilder::new(app, "Clearspace")
        .about(None)
        .separator()
        .services()
        .separator()
        .hide()
        .hide_others()
        .show_all()
        .separator()
        .item(&item("quit", "Quit Clearspace", "Cmd+Q")?)
        .build()?;
    let file = SubmenuBuilder::new(app, "File")
        .item(&item("newTab", "New Tab", "Cmd+T")?)
        .item(&item("newGroup", "New Group…", "Cmd+Shift+N")?)
        .separator()
        .item(&item("closeTab", "Close Tab", "Cmd+W")?)
        .build()?;
    let edit = SubmenuBuilder::new(app, "Edit").undo().redo().separator().cut().copy().paste().select_all().build()?;
    let view = SubmenuBuilder::new(app, "View")
        .item(&item("space:clean", "Clean", "Ctrl+1")?)
        .item(&item("space:terminal", "Terminal", "Ctrl+2")?)
        .separator()
        .item(&item("space:next", "Next Space", "Ctrl+Cmd+Right")?)
        .item(&item("space:prev", "Previous Space", "Ctrl+Cmd+Left")?)
        .separator()
        .item(&item("nextTab", "Next Tab", "Cmd+Shift+]")?)
        .item(&item("prevTab", "Previous Tab", "Cmd+Shift+[")?)
        .separator()
        .fullscreen()
        .build()?;
    let window = SubmenuBuilder::new(app, "Window").minimize().maximize().build()?;
    MenuBuilder::new(app).items(&[&app_menu, &file, &edit, &view, &window]).build()
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let builder = tauri::Builder::default();
    #[cfg(target_os = "macos")]
    let builder = builder.menu(mac_menu).on_menu_event(|app, event| match event.id().as_ref() {
        "quit" => save_then_quit(app),
        id => {
            let _ = app.emit("clearspace://menu", id);
        }
    });
    builder
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(pty::Ptys::default())
        .manage(clean::CleanState::default())
        .register_asynchronous_uri_scheme_protocol("icon", |_ctx, request, responder| {
            let uri = request.uri().clone();
            std::thread::spawn(move || responder.respond(clean::icon_response(&uri)));
        })
        .invoke_handler(tauri::generate_handler![
            platform,
            saved_for_quit,
            selftest_mode,
            selftest_write,
            pty::pty_spawn,
            pty::pty_write,
            pty::pty_resize,
            pty::pty_kill,
            pty::pty_cwd,
            store::load_workspace,
            store::save_workspace,
            store::load_scrollback,
            store::save_scrollback,
            store::remove_scrollback,
            store::prune_scrollback,
            swipe::swipe_region,
            swipe::swipe_native,
            swipe::swipe_feed,
            clean::clean_storage,
            clean::clean_scan,
            clean::clean_scan_cancel,
            clean::clean_remove,
            clean::clean_remove_admin,
            clean::clean_exists,
            clean::clean_worktrees,
            clean::clean_open_settings,
            clean::apps_list,
            clean::apps_measure,
            clean::apps_inspect,
            clean::apps_open,
            clean::apps_running,
            clean::apps_quit,
            clean::apps_uninstall,
        ])
        .setup(|app| {
            #[cfg(target_os = "macos")]
            {
                let _ = clean::mac::APP.set(app.handle().clone());
                swipe::install(app.handle());
            }
            // Self-test windows stay in view so they keep rendering while someone uses the Mac
            // (a hidden web view pauses timers and animation frames).
            if selftest_mode().is_some() {
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.set_always_on_top(true);
                    // Also on whichever desktop (Space) is showing, e.g. over a full-screen editor.
                    let _ = window.set_visible_on_all_workspaces(true);
                }
            }
            Ok(())
        })
        .on_window_event(|window, event| {
            if let WindowEvent::CloseRequested { api, .. } = event {
                if !SAVED.load(Ordering::SeqCst) {
                    api.prevent_close();
                    save_then_quit(window.app_handle());
                }
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building Clearspace")
        .run(|app, event| {
            if let RunEvent::ExitRequested { api, .. } = event {
                if !SAVED.load(Ordering::SeqCst) {
                    api.prevent_exit();
                    save_then_quit(app);
                }
            }
        });
}

#[cfg(test)]
mod tests {
    #[test]
    fn decodes_base64() {
        assert_eq!(super::decode_base64("aGVsbG8=").unwrap(), b"hello");
        assert_eq!(super::decode_base64("aGk=").unwrap(), b"hi");
    }
}
