//! Two-finger swipes over the sidebar on macOS, read from AppKit with the trackpad's real phases
//! (fingers down, moving, lifted, coasting), exactly like the native Swift build. The web view only
//! gets bare wheel deltas and has to guess when the fingers lift, which makes the snap late.
//!
//! Emits "clearspace://swipe" with `Change { dx }` while the fingers move and `End { dx, velocity }`
//! once they lift. Horizontal swipe events are swallowed so the sidebar list doesn't scroll too.

use serde::{Deserialize, Serialize};
use std::sync::Mutex;

#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Swipe {
    /// Travel so far in points, in the fingers' direction (negative = toward the next space).
    Change { dx: f64 },
    /// Fingers lifted; `velocity` is their speed over the last 0.1 s in points per second.
    End { dx: f64, velocity: f64 },
}

#[derive(Clone, Copy, Debug, PartialEq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Phase {
    Began,
    Changed,
    /// Fingers resting mid-swipe.
    Stationary,
    Ended,
    Cancelled,
    /// No phase: a mouse wheel, or fingers touching down before they move.
    Other,
}

/// One scroll event, reduced to what the tracker needs (also what the self-test feeds in).
#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Sample {
    pub phase: Phase,
    /// Part of the coasting after the fingers lifted.
    pub momentum: bool,
    /// From a trackpad (a mouse wheel never swipes spaces).
    pub precise: bool,
    /// Over the sidebar.
    pub inside: bool,
    /// Horizontal step in the fingers' direction, whatever "natural scrolling" is set to.
    pub dx: f64,
    pub dy: f64,
    /// Seconds.
    pub t: f64,
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
enum Axis {
    Undecided,
    Horizontal,
    #[default]
    Vertical,
}

#[derive(Default)]
pub struct Tracker {
    axis: Axis,
    dx: f64,
    dy: f64,
    samples: Vec<(f64, f64)>,
}

impl Tracker {
    /// True when the event belongs to a horizontal swipe, so the page doesn't scroll as well.
    pub fn handle(&mut self, s: &Sample, out: &mut impl FnMut(Swipe)) -> bool {
        // The coasting that follows a swipe belongs to it.
        if s.momentum {
            return self.axis == Axis::Horizontal;
        }
        // Anything else without a phase means the swipe and its coasting are over.
        if s.phase == Phase::Other {
            self.axis = Axis::Vertical;
            return false;
        }
        if s.phase == Phase::Began {
            if !s.precise || !s.inside {
                self.axis = Axis::Vertical;
                return false;
            }
            self.axis = Axis::Undecided;
            self.dx = 0.0;
            self.dy = 0.0;
            self.samples.clear();
        }
        if self.axis == Axis::Vertical {
            return false;
        }
        match s.phase {
            Phase::Changed => {
                self.dx += s.dx;
                self.dy += s.dy.abs();
                self.samples.push((s.t, s.dx));
                self.samples.retain(|(t, _)| s.t - t <= 0.1);
                if self.axis == Axis::Undecided && self.dx.hypot(self.dy) > 6.0 {
                    self.axis = if self.dx.abs() > self.dy * 1.2 { Axis::Horizontal } else { Axis::Vertical };
                }
                if self.axis == Axis::Horizontal {
                    out(Swipe::Change { dx: self.dx });
                }
                self.axis == Axis::Horizontal
            }
            Phase::Ended | Phase::Cancelled => {
                if self.axis != Axis::Horizontal {
                    self.axis = Axis::Vertical;
                    return false;
                }
                // Fingers that paused before lifting carry no flick.
                self.samples.retain(|(t, _)| s.t - t <= 0.1);
                let mut velocity = 0.0;
                if let Some(&(first, _)) = self.samples.first() {
                    if s.t - first > 0.01 {
                        velocity = self.samples.iter().map(|(_, d)| d).sum::<f64>() / (s.t - first);
                    }
                }
                out(Swipe::End { dx: self.dx, velocity });
                // Stay horizontal so the coasting that follows is swallowed too.
                true
            }
            _ => self.axis == Axis::Horizontal,
        }
    }
}

static TRACKER: Mutex<Tracker> = Mutex::new(Tracker { axis: Axis::Vertical, dx: 0.0, dy: 0.0, samples: Vec::new() });
/// The sidebar, in window points from the top-left: x, y, width, height.
static REGION: Mutex<Option<[f64; 4]>> = Mutex::new(None);

/// The window reports where the sidebar is whenever it moves or resizes.
#[tauri::command]
pub fn swipe_region(x: f64, y: f64, width: f64, height: f64) {
    *REGION.lock().unwrap() = Some([x, y, width, height]);
}

/// True on platforms where `install` reads the trackpad natively.
#[tauri::command]
pub fn swipe_native() -> bool {
    cfg!(target_os = "macos")
}

/// Self-test only: pushes a synthetic event through the same tracker as the trackpad.
#[tauri::command]
pub fn swipe_feed(app: tauri::AppHandle, sample: Sample) -> Result<bool, String> {
    if std::env::var_os("CLEARSPACE_SELFTEST").is_none() {
        return Err("self-test only".into());
    }
    Ok(handle(&app, &sample))
}

fn handle(app: &tauri::AppHandle, sample: &Sample) -> bool {
    use tauri::Emitter;
    TRACKER.lock().unwrap().handle(sample, &mut |swipe| {
        let _ = app.emit("clearspace://swipe", swipe);
    })
}

#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn inside_region(x: f64, y: f64) -> bool {
    REGION.lock().unwrap().is_some_and(|[rx, ry, w, h]| x >= rx && x < rx + w && y >= ry && y < ry + h)
}

/// Watches every scroll event the app receives (a local monitor, so no permission is needed).
#[cfg(target_os = "macos")]
pub fn install(app: &tauri::AppHandle) {
    use block2::RcBlock;
    use objc2::MainThreadMarker;
    use objc2_app_kit::{NSEvent, NSEventMask, NSEventPhase};
    use std::ptr::NonNull;
    use tauri::Manager;

    let Some(window) = app.get_webview_window("main") else { return };
    let Ok(ns_window) = window.ns_window() else { return };
    let ours = ns_window as usize;
    let app = app.clone();

    let block = RcBlock::new(move |event: NonNull<NSEvent>| -> *mut NSEvent {
        let e = unsafe { event.as_ref() };
        let Some(mtm) = MainThreadMarker::new() else { return event.as_ptr() };
        let phase = e.phase();
        let momentum = e.momentumPhase() != NSEventPhase::None;
        let phase = if phase.contains(NSEventPhase::Began) {
            Phase::Began
        } else if phase.contains(NSEventPhase::Changed) {
            Phase::Changed
        } else if phase.contains(NSEventPhase::Stationary) {
            Phase::Stationary
        } else if phase.contains(NSEventPhase::Ended) {
            Phase::Ended
        } else if phase.contains(NSEventPhase::Cancelled) {
            Phase::Cancelled
        } else {
            Phase::Other
        };
        // Only the start of a gesture needs the position; later events belong to it wherever they land.
        let mut inside = false;
        if phase == Phase::Began {
            if let Some(w) = e.window(mtm) {
                if objc2::rc::Retained::as_ptr(&w) as usize == ours {
                    let p = e.locationInWindow();
                    let height = w.contentView().map(|v| v.frame().size.height).unwrap_or(0.0);
                    inside = inside_region(p.x, height - p.y);
                }
            }
        }
        let dx = e.scrollingDeltaX();
        let sample = Sample {
            phase,
            momentum,
            precise: e.hasPreciseScrollingDeltas(),
            inside,
            // Follow the fingers whichever way "natural scrolling" is set.
            dx: if e.isDirectionInvertedFromDevice() { dx } else { -dx },
            dy: e.scrollingDeltaY(),
            t: e.timestamp(),
        };
        if handle(&app, &sample) { std::ptr::null_mut() } else { event.as_ptr() }
    });
    let monitor = unsafe { NSEvent::addLocalMonitorForEventsMatchingMask_handler(NSEventMask::ScrollWheel, &block) };
    // The monitor lives as long as the app.
    std::mem::forget(monitor);
    std::mem::forget(block);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(phase: Phase, dx: f64, t: f64) -> Sample {
        Sample { phase, momentum: false, precise: true, inside: true, dx, dy: 0.0, t }
    }

    #[test]
    fn follows_then_reports_flick() {
        let mut tracker = Tracker::default();
        let mut out = vec![];
        let mut push = |e| out.push(e);
        assert!(!tracker.handle(&s(Phase::Began, 0.0, 0.0), &mut push));
        for i in 1..=10 {
            tracker.handle(&s(Phase::Changed, -10.0, i as f64 * 0.01), &mut push);
        }
        assert!(tracker.handle(&s(Phase::Ended, 0.0, 0.11), &mut push));
        let momentum = Sample { momentum: true, ..s(Phase::Other, -5.0, 0.12) };
        assert!(tracker.handle(&momentum, &mut push), "coasting is swallowed");
        assert_eq!(out.first(), Some(&Swipe::Change { dx: -10.0 }));
        match out.last() {
            Some(Swipe::End { dx, velocity }) => {
                assert_eq!(*dx, -100.0);
                assert!(*velocity < -800.0, "{velocity}");
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn ignores_vertical_and_outside() {
        let mut tracker = Tracker::default();
        let mut out = vec![];
        let mut push = |e| out.push(e);
        tracker.handle(&Sample { inside: false, ..s(Phase::Began, 0.0, 0.0) }, &mut push);
        assert!(!tracker.handle(&s(Phase::Changed, -50.0, 0.01), &mut push));
        tracker.handle(&s(Phase::Began, 0.0, 1.0), &mut push);
        assert!(!tracker.handle(&Sample { dy: 20.0, ..s(Phase::Changed, 2.0, 1.01) }, &mut push));
        assert!(out.is_empty());
    }

    #[test]
    fn mouse_wheel_after_a_swipe_scrolls_again() {
        let mut tracker = Tracker::default();
        let mut push = |_| {};
        tracker.handle(&s(Phase::Began, 0.0, 0.0), &mut push);
        tracker.handle(&s(Phase::Changed, -40.0, 0.01), &mut push);
        assert!(tracker.handle(&s(Phase::Stationary, 0.0, 0.2), &mut push), "resting fingers stay in the swipe");
        tracker.handle(&s(Phase::Ended, 0.0, 0.3), &mut push);
        let wheel = Sample { precise: false, ..s(Phase::Other, 0.0, 0.5) };
        assert!(!tracker.handle(&wheel, &mut push));
    }

    #[test]
    fn paused_fingers_carry_no_flick() {
        let mut tracker = Tracker::default();
        let mut out = vec![];
        let mut push = |e| out.push(e);
        tracker.handle(&s(Phase::Began, 0.0, 0.0), &mut push);
        tracker.handle(&s(Phase::Changed, -80.0, 0.01), &mut push);
        tracker.handle(&s(Phase::Ended, 0.0, 0.5), &mut push);
        assert_eq!(out.last(), Some(&Swipe::End { dx: -80.0, velocity: 0.0 }));
    }
}
