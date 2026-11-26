//! Slimming: universal Mac apps carry their code twice, once for Apple silicon and once for
//! Intel. On an Apple silicon Mac the Intel half is never used, so it can go. macOS only.

use serde::Serialize;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct SlimApp {
    /// The app's path.
    pub id: String,
    pub name: String,
    /// Bytes of Intel code that can go.
    pub intel: u64,
    pub files: usize,
}

#[derive(Serialize, Clone, Debug)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    Found { app: SlimApp },
    /// The list is complete.
    Listed,
    Start { id: String },
    Outcome { id: String, freed: u64, error: Option<String> },
    Finished,
}

/// Only Apple silicon Macs have an Intel half to spare.
pub fn supported() -> bool {
    #[cfg(target_os = "macos")]
    return super::slim_mac::supported();
    #[cfg(not(target_os = "macos"))]
    return false;
}

/// Apps with Intel code worth removing, as they are found; ends with `Listed`.
pub fn list(send: &dyn Fn(Event)) {
    #[cfg(target_os = "macos")]
    super::slim_mac::list(send);
    #[cfg(not(target_os = "macos"))]
    send(Event::Listed);
}

/// Slims one app. Returns the bytes its Intel half took.
pub fn slim(app: &str) -> Result<u64, String> {
    #[cfg(target_os = "macos")]
    return super::slim_mac::slim(app);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Err("Only Mac apps can be slimmed.".into())
    }
}
