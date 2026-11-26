//! The Clean space: Disk Cleaner (scan, suggestions, removal), App Uninstaller, Maintenance,
//! Status and History, on every platform. Heavy work runs on its own threads and streams results
//! to the window over channels.

pub mod apps;
pub mod fsx;
pub mod guard;
#[cfg(target_os = "macos")]
pub mod mac;
pub mod maintain;
pub mod remove;
pub mod scan;
pub mod settings;
pub mod slim;
#[cfg(target_os = "macos")]
mod slim_mac;
pub mod status;
pub mod suggest;
pub mod temp;
pub mod worktrees;

use apps::{App, Confidence, Inspection};
use remove::{AdminResult, Mode};
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use tauri::ipc::Channel;

#[derive(Default)]
pub struct CleanState {
    scan_cancel: Mutex<Option<Arc<AtomicBool>>>,
    apps: Mutex<Vec<App>>,
    /// Kept between samples: activity is measured against the previous one.
    status: Mutex<Option<status::Sampler>>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Storage {
    name: String,
    total: u64,
    available: u64,
    /// macOS only: whether Clearspace can see every folder.
    full_disk_access: Option<bool>,
}

#[tauri::command]
pub async fn clean_storage() -> Storage {
    tauri::async_runtime::spawn_blocking(storage).await.unwrap_or(Storage { name: "Disk".into(), total: 0, available: 0, full_disk_access: None })
}

fn storage() -> Storage {
    #[cfg(target_os = "macos")]
    {
        let (name, total, available) = mac::storage().unwrap_or(("Macintosh HD".into(), 0, 0));
        Storage { name, total, available, full_disk_access: Some(mac::has_full_disk_access()) }
    }
    #[cfg(target_os = "linux")]
    {
        let home = std::ffi::CString::new(fsx::home()).unwrap_or_default();
        let mut st: libc::statvfs = unsafe { std::mem::zeroed() };
        let ok = unsafe { libc::statvfs(home.as_ptr(), &mut st) } == 0;
        let (total, available) = if ok { (st.f_blocks as u64 * st.f_frsize as u64, st.f_bavail as u64 * st.f_frsize as u64) } else { (0, 0) };
        Storage { name: "Home disk".into(), total, available, full_disk_access: None }
    }
    #[cfg(windows)]
    {
        use windows_sys::Win32::Storage::FileSystem::GetDiskFreeSpaceExW;
        let home = fsx::home();
        let drive: String = home.chars().take(3).collect(); // "C:\"
        let wide: Vec<u16> = drive.encode_utf16().chain([0]).collect();
        let (mut available, mut total, mut free) = (0u64, 0u64, 0u64);
        unsafe { GetDiskFreeSpaceExW(wide.as_ptr(), &mut available, &mut total, &mut free) };
        Storage { name: format!("Local Disk ({})", drive.trim_end_matches('\\')), total, available, full_disk_access: None }
    }
}

#[derive(Serialize, Clone)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum ScanEvent {
    Progress { files: u64, folder: String },
    #[serde(rename_all = "camelCase")]
    Done { root: scan::Node, large_files: Vec<scan::LargeFile>, suggestions: Vec<suggest::Suggestion>, worktrees: Vec<worktrees::Worktree>, files: u64, millis: u64, emptied: Vec<String> },
    Cancelled,
}

#[tauri::command]
pub fn clean_scan(state: tauri::State<'_, CleanState>, events: Channel<ScanEvent>) -> Result<(), String> {
    let cancel = Arc::new(AtomicBool::new(false));
    if let Some(previous) = state.scan_cancel.lock().unwrap().replace(cancel.clone()) {
        previous.store(true, Ordering::Relaxed);
    }
    std::thread::Builder::new()
        .name("disk-scan".into())
        .stack_size(64 << 20) // the scan recurses once per folder level
        .spawn(move || {
            let progress_events = events.clone();
            let mut progress = |files: u64, folder: &str| {
                let _ = progress_events.send(ScanEvent::Progress { files, folder: folder.to_string() });
            };
            let roots = scan::roots();
            match scan::Scanner::new(&cancel, &mut progress).run(&roots) {
                Some(result) => {
                    let protected = settings::protected();
                    let mut suggestions = suggest::suggestions(&result, &suggest::Installed::current());
                    suggestions.retain(|s| settings::protection(&s.path, &protected).is_none());
                    let worktrees = worktrees::find(&result);
                    let _ = events.send(ScanEvent::Done { emptied: temp::emptied_folders(), suggestions, worktrees, files: result.file_count, millis: result.millis, large_files: result.large_files, root: result.root });
                }
                None => {
                    let _ = events.send(ScanEvent::Cancelled);
                }
            }
        })
        .map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn clean_scan_cancel(state: tauri::State<'_, CleanState>) {
    if let Some(cancel) = state.scan_cancel.lock().unwrap().take() {
        cancel.store(true, Ordering::Relaxed);
    }
}

#[derive(Deserialize)]
pub struct RemoveItem {
    path: String,
    size: u64,
}

#[derive(Deserialize, PartialEq, Clone, Copy)]
#[serde(rename_all = "camelCase")]
pub enum Checks {
    /// Disk Cleaner: only inside the scanned folders, never protected ones.
    Cleaner,
    /// App Uninstaller: the finder's own results; live mounts are refused.
    Uninstaller,
}

impl Checks {
    /// The tool's name in the history.
    fn tool(self) -> &'static str {
        match self {
            Checks::Cleaner => "cleaner",
            Checks::Uninstaller => "uninstaller",
        }
    }
}

#[derive(Serialize, Clone)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum RemoveEvent {
    Start { path: String },
    #[serde(rename_all = "camelCase")]
    Outcome { path: String, size: u64, error: Option<String>, needs_admin: bool },
    Finished,
}

/// Removes items one at a time off the main thread, reporting each step.
#[tauri::command]
pub fn clean_remove(items: Vec<RemoveItem>, mode: Mode, checks: Checks, events: Channel<RemoveEvent>) {
    std::thread::spawn(move || {
        let guard = (checks == Checks::Cleaner).then(|| guard::Guard::new(&scan::roots().into_iter().map(|r| r.path).collect::<Vec<_>>()));
        let protected = settings::protected();
        let emptied = temp::emptied_folders();
        for item in items {
            let _ = events.send(RemoveEvent::Start { path: item.path.clone() });
            if worktrees::is_docker(&item.path) {
                let error = worktrees::remove_docker(&item.path).err();
                if error.is_none() {
                    settings::record(&[settings::Entry::now("delete", &item.path, item.size, checks.tool())]);
                }
                let _ = events.send(RemoveEvent::Outcome { path: item.path, size: item.size, error, needs_admin: false });
                continue;
            }
            // A worktree deleted for good is also dropped from its repository's list. One moved to
            // the Trash keeps its record, so putting it back still works.
            let worktree = (mode == Mode::Permanent).then(|| worktrees::link(&item.path)).flatten();
            let refusal = settings::protection(&item.path, &protected).or_else(|| match &guard {
                Some(guard) => guard.refusal(&item.path),
                None if fsx::is_mount_point(&item.path) => Some("It's a mounted volume. Quit the app, then try again.".into()),
                None if !fsx::exists(&item.path) => Some("It no longer exists.".into()),
                None => None,
            });
            let (error, needs_admin) = match refusal {
                Some(r) => (Some(r), false),
                None => match remove::remove(&item.path, mode) {
                    Ok(()) => {
                        if let Some(link) = &worktree {
                            worktrees::forget(link, &item.path);
                        }
                        // The Trash and Windows' temp folder are emptied for good, whatever the mode.
                        let for_good = mode == Mode::Permanent || emptied.iter().any(|f| fsx::key(f) == fsx::key(&item.path));
                        settings::record(&[settings::Entry::now(if for_good { "delete" } else { "trash" }, &item.path, item.size, checks.tool())]);
                        (None, false)
                    }
                    Err(f) => (Some(f.message), f.needs_admin),
                },
            };
            let _ = events.send(RemoveEvent::Outcome { path: item.path, size: item.size, error, needs_admin });
        }
        let _ = events.send(RemoveEvent::Finished);
    });
}

/// Retries, with administrator rights, the items the account couldn't remove itself.
#[tauri::command]
pub async fn clean_remove_admin(items: Vec<RemoveItem>, mode: Mode, checks: Checks) -> AdminResult {
    let work = move || {
        let protected = settings::protected();
        let allowed: Vec<&RemoveItem> = items.iter().filter(|i| settings::protection(&i.path, &protected).is_none() && fsx::exists(&i.path)).collect();
        let paths: Vec<String> = allowed.iter().map(|i| i.path.clone()).collect();
        let result = remove::as_admin(&paths, mode);
        let gone: Vec<settings::Entry> = allowed.iter().filter(|i| !fsx::exists(&i.path)).map(|i| settings::Entry::now(if mode == Mode::Permanent { "delete" } else { "trash" }, &i.path, i.size, checks.tool())).collect();
        settings::record(&gone);
        result
    };
    tauri::async_runtime::spawn_blocking(work).await.unwrap_or(AdminResult::Failed { message: "The administrator command failed.".into() })
}

// MARK: Never clean, history

#[tauri::command]
pub fn protected_list() -> Vec<String> {
    settings::protected()
}

#[tauri::command]
pub fn protected_set(paths: Vec<String>) -> Result<Vec<String>, String> {
    settings::set_protected(&paths)?;
    Ok(settings::protected())
}

#[tauri::command(async)]
pub fn history_list() -> Vec<settings::Entry> {
    settings::history()
}

#[tauri::command]
pub fn history_clear() {
    settings::clear_history();
}

// MARK: Status

/// One reading of the system. The first of a session reads as idle: activity is measured
/// since the reading before.
#[tauri::command(async)]
pub fn status_sample(state: tauri::State<'_, CleanState>) -> Result<status::Status, String> {
    let disk = storage();
    let mut sampler = state.status.lock().unwrap();
    if sampler.is_none() {
        *sampler = Some(status::Sampler::new()?);
        // Processor use needs two looks a moment apart.
        std::thread::sleep(std::time::Duration::from_millis(250));
    }
    Ok(sampler.as_mut().unwrap().sample(disk.total, disk.available))
}

// MARK: Maintenance

#[tauri::command(async)]
pub fn maintain_tasks() -> Vec<maintain::Task> {
    maintain::tasks()
}

#[tauri::command]
pub fn maintain_run(ids: Vec<String>, events: Channel<maintain::Event>) {
    std::thread::spawn(move || {
        maintain::run(&ids, &|event| {
            let _ = events.send(event);
        });
    });
}

#[tauri::command]
pub fn slim_supported() -> bool {
    slim::supported()
}

/// Apps whose Intel half can go, as they are found.
#[tauri::command]
pub fn slim_list(events: Channel<slim::Event>) {
    std::thread::spawn(move || {
        slim::list(&|event| {
            let _ = events.send(event);
        });
    });
}

#[tauri::command]
pub fn slim_run(ids: Vec<String>, events: Channel<slim::Event>) {
    std::thread::spawn(move || {
        for id in ids {
            let _ = events.send(slim::Event::Start { id: id.clone() });
            let result = slim::slim(&id);
            if let Ok(freed) = &result {
                settings::record(&[settings::Entry::now("slim", &id, *freed, "maintenance")]);
            }
            let _ = events.send(slim::Event::Outcome { id, freed: *result.as_ref().unwrap_or(&0), error: result.err() });
        }
        let _ = events.send(slim::Event::Finished);
    });
}

/// Where each worktree's branch stands and which Docker containers, volumes and images are its own.
#[tauri::command]
pub fn clean_worktrees(worktrees: Vec<worktrees::Worktree>, events: Channel<worktrees::Event>) {
    std::thread::spawn(move || {
        let roots: Vec<String> = scan::roots().into_iter().map(|r| r.path).collect();
        worktrees::inspect(&worktrees, &roots, &|event| {
            let _ = events.send(event);
        });
    });
}

#[tauri::command]
pub fn clean_exists(paths: Vec<String>) -> Vec<bool> {
    paths.iter().map(|p| fsx::exists(p)).collect()
}

/// macOS privacy settings: "fullDiskAccess" or "appManagement".
#[tauri::command]
pub fn clean_open_settings(pane: String) {
    #[cfg(target_os = "macos")]
    {
        let anchor = if pane == "appManagement" { "Privacy_AppBundles" } else { "Privacy_AllFiles" };
        let _ = std::process::Command::new("/usr/bin/open").arg(format!("x-apple.systempreferences:com.apple.preference.security?{anchor}")).spawn();
    }
    #[cfg(not(target_os = "macos"))]
    let _ = pane;
}

// MARK: App Uninstaller

#[tauri::command]
pub async fn apps_list(state: tauri::State<'_, CleanState>) -> Result<Vec<App>, String> {
    let mut apps = tauri::async_runtime::spawn_blocking(apps::platform::list).await.map_err(|e| e.to_string())?;
    let mut stored = state.apps.lock().unwrap();
    // Keep an app picked from elsewhere (Downloads, another disk) while it still exists.
    let picked: Vec<App> = stored.iter().filter(|p| !apps.iter().any(|a| a.id == p.id) && fsx::exists(&p.id)).cloned().collect();
    apps.extend(picked);
    apps.sort_by_key(|a| a.name.to_lowercase());
    *stored = apps.clone();
    Ok(apps)
}

#[derive(Serialize, Clone)]
pub struct AppSize {
    id: String,
    size: u64,
}

/// Each app's size: first the app itself (fast), then everything it owns.
#[tauri::command]
pub fn apps_measure(state: tauri::State<'_, CleanState>, events: Channel<Vec<AppSize>>) {
    let apps = state.apps.lock().unwrap().clone();
    std::thread::spawn(move || {
        for footprint in [false, true] {
            let mut batch = vec![];
            for (i, app) in apps.iter().enumerate() {
                let size = if footprint { measure_footprint(app, &apps) } else { app.size.unwrap_or_else(|| app.location.as_deref().map(fsx::allocated_size).unwrap_or(0)) };
                batch.push(AppSize { id: app.id.clone(), size });
                if batch.len() == 8 || i == apps.len() - 1 {
                    if events.send(std::mem::take(&mut batch)).is_err() {
                        return;
                    }
                }
            }
        }
    });
}

/// The app plus every leftover matched for certain (name-only matches might be another app's).
fn measure_footprint(app: &App, all: &[App]) -> u64 {
    let found = apps::platform::inspect(app, all);
    let leftovers: u64 = found.leftovers.iter().filter(|l| l.confidence == Confidence::Exact).map(|l| fsx::allocated_size(&l.path)).sum();
    // Packages' own files aren't among the leftovers; count what the system reported for them.
    let has_app = found.leftovers.iter().any(|l| l.kind == "application");
    leftovers + if has_app { 0 } else { app.size.unwrap_or(0) }
}

#[derive(Serialize, Clone)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum InspectEvent {
    Found { inspection: Inspection },
    Size { path: String, size: u64 },
    Done,
}

#[tauri::command]
pub fn apps_inspect(state: tauri::State<'_, CleanState>, id: String, events: Channel<InspectEvent>) -> Result<(), String> {
    let all = state.apps.lock().unwrap().clone();
    let app = all.iter().find(|a| a.id == id).cloned().ok_or("That app is no longer installed.")?;
    std::thread::spawn(move || {
        let inspection = apps::platform::inspect(&app, &all);
        let paths: Vec<String> = inspection.leftovers.iter().map(|l| l.path.clone()).collect();
        if events.send(InspectEvent::Found { inspection }).is_err() {
            return;
        }
        for path in paths {
            let size = fsx::allocated_size(&path);
            if events.send(InspectEvent::Size { path, size }).is_err() {
                return;
            }
        }
        let _ = events.send(InspectEvent::Done);
    });
    Ok(())
}

/// An app chosen by hand; it joins the list.
#[tauri::command]
pub async fn apps_open(state: tauri::State<'_, CleanState>, path: String) -> Result<App, String> {
    let app = tauri::async_runtime::spawn_blocking(move || apps::platform::open(&path)).await.map_err(|e| e.to_string())??;
    let mut stored = state.apps.lock().unwrap();
    if !stored.iter().any(|a| a.id == app.id) {
        stored.push(app.clone());
    }
    Ok(app)
}

fn find_app(state: &CleanState, id: &str) -> Result<App, String> {
    state.apps.lock().unwrap().iter().find(|a| a.id == id).cloned().ok_or_else(|| "That app is no longer installed.".into())
}

#[tauri::command]
pub async fn apps_running(state: tauri::State<'_, CleanState>, id: String) -> Result<bool, String> {
    let app = find_app(&state, &id)?;
    Ok(tauri::async_runtime::spawn_blocking(move || !apps::platform::pids(&app).is_empty()).await.unwrap_or(false))
}

#[tauri::command]
pub async fn apps_quit(state: tauri::State<'_, CleanState>, id: String) -> Result<(), String> {
    let app = find_app(&state, &id)?;
    tauri::async_runtime::spawn_blocking(move || apps::platform::terminate(&apps::platform::pids(&app))).await.map_err(|e| e.to_string())
}

/// Windows programs and Linux packages: runs their own uninstaller and waits for it.
#[tauri::command]
pub async fn apps_uninstall(state: tauri::State<'_, CleanState>, id: String) -> Result<(), String> {
    let app = find_app(&state, &id)?;
    tauri::async_runtime::spawn_blocking(move || apps::platform::run_uninstaller(&app)).await.map_err(|e| e.to_string())?
}

// MARK: Icons

/// Serves `icon://localhost/<path>?s=<points>`: the file's icon as the system shows it.
pub fn icon_response(uri: &tauri::http::Uri) -> tauri::http::Response<Vec<u8>> {
    use tauri::http::Response;
    let path = percent_decode(uri.path().trim_start_matches('/'));
    let points: f64 = uri.query().and_then(|q| q.strip_prefix("s=")).and_then(|s| s.parse().ok()).unwrap_or(32.0);
    let not_found = || Response::builder().status(404).body(Vec::new()).unwrap();
    let ok = |bytes: Vec<u8>, kind: &str| {
        Response::builder()
            .header("Content-Type", kind)
            .header("Cache-Control", "max-age=3600")
            // The page's origin differs from icon://, so reading the bytes from script needs this.
            .header("Access-Control-Allow-Origin", "*")
            .body(bytes)
            .unwrap()
    };
    #[cfg(target_os = "macos")]
    {
        // Retina: twice the points.
        match mac::icon_png(&path, (points * 2.0).clamp(16.0, 512.0)) {
            Some(png) => ok(png, "image/png"),
            None => not_found(),
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = points;
        let kind = match fsx::extension(&path).as_str() {
            "png" => "image/png",
            "svg" => "image/svg+xml",
            _ => return not_found(),
        };
        match std::fs::read(&path) {
            Ok(bytes) => ok(bytes, kind),
            Err(_) => not_found(),
        }
    }
}

fn percent_decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(b) = u8::from_str_radix(&text[i + 1..i + 3], 16) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

#[cfg(test)]
mod tests {
    #[test]
    fn decodes_percent() {
        assert_eq!(super::percent_decode("%2FApplications%2FA%20B.app"), "/Applications/A B.app");
        assert_eq!(super::percent_decode("C%3A%5Cx"), r"C:\x");
    }
}
