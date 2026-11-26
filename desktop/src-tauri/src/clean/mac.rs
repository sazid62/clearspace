//! macOS pieces that need AppKit/Foundation: disk capacity as Finder reports it, Finder icons,
//! the administrator prompt, Full Disk Access, and quitting running apps.

use objc2::rc::Retained;
use objc2::runtime::AnyObject;
use objc2::AnyThread;
use objc2_app_kit::{NSBitmapImageFileType, NSBitmapImageRep, NSRunningApplication, NSWorkspace};
use objc2_foundation::{NSAppleScript, NSArray, NSDictionary, NSNumber, NSPoint, NSRect, NSSize, NSString, NSURL};
use std::sync::OnceLock;

pub static APP: OnceLock<tauri::AppHandle> = OnceLock::new();

/// (volume name, total bytes, available bytes). "Important usage" counts purgeable space as free,
/// matching what Finder shows.
pub fn storage() -> Option<(String, u64, u64)> {
    unsafe {
        use objc2_foundation::{NSURLVolumeAvailableCapacityForImportantUsageKey as IMPORTANT, NSURLVolumeAvailableCapacityKey as AVAILABLE, NSURLVolumeLocalizedNameKey as NAME, NSURLVolumeTotalCapacityKey as TOTAL};
        let url = NSURL::fileURLWithPath(&NSString::from_str("/"));
        let keys = NSArray::from_slice(&[NAME, TOTAL, AVAILABLE, IMPORTANT]);
        let values = url.resourceValuesForKeys_error(&keys).ok()?;
        let number = |key: &NSString| values.objectForKey(key).and_then(|v| v.downcast::<NSNumber>().ok()).map(|n| n.longLongValue().max(0) as u64);
        let name = values.objectForKey(NAME).and_then(|v| v.downcast::<NSString>().ok()).map(|s| s.to_string()).unwrap_or_else(|| "Macintosh HD".into());
        let total = number(TOTAL)?;
        let available = number(IMPORTANT).filter(|&n| n > 0).or_else(|| number(AVAILABLE))?;
        Some((name, total, available))
    }
}

/// The Finder icon for any file, folder or app, as a PNG `pixels` wide.
pub fn icon_png(path: &str, pixels: f64) -> Option<Vec<u8>> {
    let image = NSWorkspace::sharedWorkspace().iconForFile(&NSString::from_str(path));
    image.setSize(NSSize::new(pixels, pixels));
    let mut rect = NSRect::new(NSPoint::new(0.0, 0.0), NSSize::new(pixels, pixels));
    let cg = unsafe { image.CGImageForProposedRect_context_hints(&mut rect, None, None) }?;
    let rep = NSBitmapImageRep::initWithCGImage(NSBitmapImageRep::alloc(), &cg);
    let data = unsafe { rep.representationUsingType_properties(NSBitmapImageFileType::PNG, &NSDictionary::new()) }?;
    Some(data.to_vec())
}

/// Runs AppleScript on the main thread (NSAppleScript requires it), so the administrator prompt
/// names Clearspace. Must not be called from the main thread.
pub fn run_admin_script(source: &str) -> super::remove::AdminResult {
    use super::remove::AdminResult;
    let Some(app) = APP.get() else { return AdminResult::Failed { message: "Not ready.".into() } };
    let (tx, rx) = std::sync::mpsc::channel();
    let source = source.to_string();
    let sent = app.run_on_main_thread(move || {
        let result = (|| {
            let script = NSAppleScript::initWithSource(NSAppleScript::alloc(), &NSString::from_str(&source))?;
            let mut error: Option<Retained<NSDictionary<NSString, AnyObject>>> = None;
            unsafe { script.executeAndReturnError(Some(&mut error)) };
            let Some(error) = error else { return Some(AdminResult::Completed) };
            let number = unsafe { error.objectForKey(objc2_foundation::NSAppleScriptErrorNumber) }.and_then(|v| v.downcast::<NSNumber>().ok()).map(|n| n.longLongValue());
            if number == Some(-128) {
                return Some(AdminResult::Cancelled);
            }
            let message = unsafe { error.objectForKey(objc2_foundation::NSAppleScriptErrorMessage) }
                .and_then(|v| v.downcast::<NSString>().ok())
                .map(|s| s.to_string())
                .unwrap_or_else(|| "The administrator command failed.".into());
            Some(AdminResult::Failed { message })
        })();
        let _ = tx.send(result.unwrap_or(AdminResult::Failed { message: "Couldn't run the administrator command.".into() }));
    });
    if sent.is_err() {
        return AdminResult::Failed { message: "Couldn't reach the window.".into() };
    }
    rx.recv().unwrap_or(AdminResult::Failed { message: "The administrator command didn't finish.".into() })
}

/// These files open only with Full Disk Access; "operation not permitted" means it isn't granted.
pub fn has_full_disk_access() -> bool {
    let home = super::fsx::home();
    for path in [
        "/Library/Application Support/com.apple.TCC/TCC.db".to_string(),
        format!("{home}/Library/Application Support/com.apple.TCC/TCC.db"),
        format!("{home}/Library/Safari/Bookmarks.plist"),
    ] {
        match std::fs::File::open(&path) {
            Ok(_) => return true,
            Err(e) if e.kind() == std::io::ErrorKind::PermissionDenied => return false,
            Err(_) => continue,
        }
    }
    false
}

/// Every process whose program is inside `bundle` (an .app path).
pub fn pids_inside(bundle: &str) -> Vec<i32> {
    let prefix = format!("{}/", bundle.trim_end_matches('/'));
    let mut pids = vec![0i32; 4096];
    let count = unsafe { libc::proc_listallpids(pids.as_mut_ptr().cast(), (pids.len() * 4) as libc::c_int) };
    if count <= 0 {
        return vec![];
    }
    pids.truncate(count as usize);
    pids.into_iter()
        .filter(|&pid| {
            let mut buf = vec![0u8; libc::PROC_PIDPATHINFO_MAXSIZE as usize];
            let len = unsafe { libc::proc_pidpath(pid, buf.as_mut_ptr().cast(), buf.len() as u32) };
            len > 0 && std::str::from_utf8(&buf[..len as usize]).is_ok_and(|p| p.starts_with(&prefix))
        })
        .collect()
}

/// Asks each app to quit the normal way, so it can save first.
pub fn terminate(pids: &[i32]) {
    for &pid in pids {
        if let Some(app) = NSRunningApplication::runningApplicationWithProcessIdentifier(pid) {
            app.terminate();
        }
    }
}
