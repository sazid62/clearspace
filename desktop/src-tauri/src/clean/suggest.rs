//! Known caches and leftovers for each platform, plus items found by what they are: project build
//! folders, git worktrees, leftovers in /tmp, videos and big downloads.

use super::fsx::{self, SEP};
use super::scan::{ScanResult, GIT_FILE, MINIMUM};
use serde::Serialize;
use std::collections::HashMap;

#[derive(Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Safety {
    /// Rebuilt or re-downloaded automatically when needed.
    Safe,
    /// Your own data or slow to get back; decide for yourself.
    Review,
}

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Suggestion {
    pub path: String,
    pub title: String,
    pub note: String,
    pub safety: Safety,
    pub size: u64,
}

struct Entry {
    path: String,
    title: &'static str,
    safety: Safety,
    note: &'static str,
}

fn entries() -> Vec<Entry> {
    use Safety::{Review, Safe};
    let home = fsx::home();
    let h = |rel: &str| fsx::join(&home, rel);
    let e = |path: String, title, safety, note| Entry { path, title, safety, note };
    let mut out = vec![
        e(h(".gradle/caches"), "Gradle cache", Safe, "Re-downloaded on the next Android/Gradle build."),
        e(h(".npm/_cacache"), "npm cache", Safe, "Re-downloaded when needed."),
        e(h(".bun/install/cache"), "Bun cache", Safe, "Re-downloaded when needed."),
        e(h("go/pkg/mod"), "Go module downloads", Safe, "Re-downloaded on the next go build."),
        e(h(".cargo/registry"), "Cargo downloads", Safe, "Re-downloaded on the next cargo build."),
        e(h(".m2/repository"), "Maven downloads", Safe, "Re-downloaded on the next Maven build."),
        e(h(".ollama/models"), "Ollama AI models", Review, "Your downloaded models. Delete only if you no longer use them."),
        e(h(".cache/huggingface"), "Hugging Face models", Review, "Downloaded models and datasets. Delete only if you no longer use them."),
        e(h(".android/avd"), "Android emulator phones", Review, "Your emulators. Delete only if you don't use them."),
        e(h(".codeium"), "Codeium / Windsurf index", Review, "Rebuilt when you reopen the editor."),
    ];
    #[cfg(target_os = "macos")]
    {
        let tmp = super::temp::user_temp_root();
        out.extend([
            e(fsx::join(&tmp, "X/com.google.Chrome.code_sign_clone"), "Chrome leftover copies", Safe, "A Chrome bug leaves old copies of the app here. Quit Chrome first."),
            e(fsx::join(&tmp, "X/com.brave.Browser.code_sign_clone"), "Brave leftover copies", Safe, "Same bug as Chrome. Quit Brave first."),
            e(h("Library/Caches/go-build"), "Go build cache", Safe, "Rebuilt on the next go build."),
            e(h("Library/Caches/pnpm"), "pnpm metadata cache", Safe, "Re-downloaded when needed."),
            e(h("Library/Caches/BraveSoftware"), "Brave browser cache", Safe, "Quit Brave first."),
            e(h("Library/Caches/com.brave.Browser"), "Brave browser cache (2)", Safe, "Quit Brave first."),
            e(h("Library/Caches/Google"), "Chrome browser cache", Safe, "Quit Chrome first."),
            e(h("Library/Caches/com.microsoft.VSCode.ShipIt"), "VS Code old update files", Safe, "Leftovers from past updates."),
            e(h("Library/Caches/Homebrew"), "Homebrew downloads", Safe, "Old installer downloads."),
            e(h("Library/Application Support/Google/GoogleUpdater/crx_cache"), "Google updater cache", Safe, "Old update packages."),
            e(h("Library/Caches/Yarn"), "Yarn cache", Safe, "Re-downloaded when needed."),
            e(h("Library/Caches/pip"), "pip cache", Safe, "Re-downloaded when needed."),
            e(h("Library/Caches/CocoaPods"), "CocoaPods cache", Safe, "Re-downloaded on the next pod install."),
            e(h("Library/Developer/Xcode/DerivedData"), "Xcode build products", Safe, "Rebuilt the next time you build in Xcode."),
            e(h("Library/Developer/CoreSimulator/Caches"), "Simulator caches", Safe, "Recreated by the iOS Simulator."),
            e(h(".Trash"), "Trash contents", Safe, "Things you already deleted. (Empties the Trash.)"),
            e(h("Library/pnpm/store"), "pnpm package store", Review, "Projects re-download packages on the next pnpm install. Files still used by node_modules stay on disk until those projects are reinstalled."),
            e(h("Library/Application Support/com.apple.wallpaper/aerials/videos"), "Aerial wallpaper videos", Review, "Downloaded screen-saver videos; macOS re-downloads the one you use."),
            e(h("Library/Developer/Xcode/iOS DeviceSupport"), "iOS device support files", Review, "Copied again from your device the next time you connect it to Xcode."),
            e(h("Library/Caches/ms-playwright"), "Playwright browsers", Review, "Re-download with npx playwright install."),
            e(h("Library/Android/sdk/system-images"), "Android system images", Review, "Needed to create and run emulators."),
        ]);
    }
    #[cfg(target_os = "linux")]
    {
        let cache = std::env::var("XDG_CACHE_HOME").ok().filter(|d| !d.is_empty()).unwrap_or_else(|| h(".cache"));
        let c = |rel: &str| fsx::join(&cache, rel);
        out.extend([
            e(c("pip"), "pip cache", Safe, "Re-downloaded when needed."),
            e(c("go-build"), "Go build cache", Safe, "Rebuilt on the next go build."),
            e(c("yarn"), "Yarn cache", Safe, "Re-downloaded when needed."),
            e(c("pnpm"), "pnpm metadata cache", Safe, "Re-downloaded when needed."),
            e(c("google-chrome"), "Chrome browser cache", Safe, "Quit Chrome first."),
            e(c("chromium"), "Chromium browser cache", Safe, "Quit Chromium first."),
            e(c("BraveSoftware"), "Brave browser cache", Safe, "Quit Brave first."),
            e(c("mozilla"), "Firefox cache", Safe, "Quit Firefox first."),
            e(c("thumbnails"), "Thumbnail previews", Safe, "Recreated as you browse your files."),
            e(c("JetBrains"), "JetBrains IDE caches", Safe, "Rebuilt when you reopen the IDE (indexing takes a moment)."),
            e(c("electron"), "Electron downloads", Safe, "Re-downloaded when needed."),
            e(c("ms-playwright"), "Playwright browsers", Review, "Re-download with npx playwright install."),
            e(super::temp::trash().unwrap_or_default(), "Trash contents", Safe, "Things you already deleted. (Empties the Trash.)"),
            e(h(".local/share/pnpm/store"), "pnpm package store", Review, "Projects re-download packages on the next pnpm install."),
            e(h("Android/Sdk/system-images"), "Android system images", Review, "Needed to create and run emulators."),
        ]);
    }
    #[cfg(windows)]
    {
        use super::temp::env_dir;
        let local = env_dir("LOCALAPPDATA", "AppData/Local");
        let l = |rel: &str| fsx::join(&local, rel);
        out.extend([
            e(l("Temp"), "Temporary files", Safe, "Left by installers and apps. Files still in use are skipped."),
            e(l("Google/Chrome/User Data/Default/Cache"), "Chrome browser cache", Safe, "Quit Chrome first."),
            e(l("Google/Chrome/User Data/Default/Code Cache"), "Chrome code cache", Safe, "Quit Chrome first."),
            e(l("Microsoft/Edge/User Data/Default/Cache"), "Edge browser cache", Safe, "Quit Edge first."),
            e(l("Microsoft/Edge/User Data/Default/Code Cache"), "Edge code cache", Safe, "Quit Edge first."),
            e(l("BraveSoftware/Brave-Browser/User Data/Default/Cache"), "Brave browser cache", Safe, "Quit Brave first."),
            e(l("npm-cache"), "npm cache", Safe, "Re-downloaded when needed."),
            e(l("pip/Cache"), "pip cache", Safe, "Re-downloaded when needed."),
            e(l("Yarn/Cache"), "Yarn cache", Safe, "Re-downloaded when needed."),
            e(l("pnpm-cache"), "pnpm metadata cache", Safe, "Re-downloaded when needed."),
            e(l("go-build"), "Go build cache", Safe, "Rebuilt on the next go build."),
            e(l("NuGet/v3-cache"), "NuGet cache", Safe, "Re-downloaded when needed."),
            e(l("CrashDumps"), "Crash reports", Safe, "Saved when apps crashed; only useful for debugging them."),
            e(l("D3DSCache"), "DirectX shader cache", Safe, "Rebuilt by games and apps as needed."),
            e(l("NVIDIA/DXCache"), "NVIDIA shader cache", Safe, "Rebuilt by games as needed."),
            e(l("pnpm/store"), "pnpm package store", Review, "Projects re-download packages on the next pnpm install."),
            e(h(".nuget/packages"), "NuGet packages", Review, "Re-downloaded on the next restore."),
            e(l("ms-playwright"), "Playwright browsers", Review, "Re-download with npx playwright install."),
            e(l("Android/Sdk/system-images"), "Android system images", Review, "Needed to create and run emulators."),
        ]);
    }
    out.retain(|e| !e.path.is_empty());
    out
}

/// Known caches plus what the scan itself turned up.
pub fn suggestions(result: &ScanResult) -> Vec<Suggestion> {
    let mut found: HashMap<String, Suggestion> = HashMap::new();
    let mut add = |s: Suggestion| {
        found.entry(fsx::key(&s.path)).or_insert(s);
    };
    for entry in entries() {
        if let Some(item) = result.items.get(&fsx::key(&entry.path)).filter(|i| i.size >= MINIMUM) {
            add(Suggestion { path: item.path.clone(), title: entry.title.into(), note: entry.note.into(), safety: entry.safety, size: item.size });
        }
    }
    let detector = Detector::new(result);
    detector.folders().into_iter().for_each(&mut add);
    detector.files().into_iter().for_each(&mut add);
    let mut out: Vec<Suggestion> = found.into_values().collect();
    out.sort_by(|a, b| b.size.cmp(&a.size));
    out
}

/// Folders a project tool recreates; anything inside one of these is never suggested separately.
const GENERATED: [&str; 15] = ["node_modules", ".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".angular", ".output", ".dart_tool", "dist", "build", "target", "Pods", ".venv", "venv"];
/// Document bundles (Photos, Final Cut, ...) look like folders but must stay whole.
const BUNDLES: [&str; 14] = ["app", "photoslibrary", "fcpbundle", "imovielibrary", "tvlibrary", "musiclibrary", "screenstudio", "logicx", "band", "photolibrary", "xcarchive", "bundle", "framework", "pkg"];
const VIDEOS: [&str; 14] = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "mpg", "mpeg", "ts", "m2ts", "vob", "3gp"];
const INSTALLERS: [&str; 22] = ["dmg", "pkg", "mpkg", "iso", "xip", "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "apk", "aab", "ipa", "exe", "msi", "deb", "rpm", "appimage", "flatpak"];

struct Detector<'a> {
    result: &'a ScanResult,
    home: String,
    /// Where the platform keeps apps' own data in the home folder; never suggested by the detector.
    private_area: Option<String>,
    shared_temp: Option<String>,
    now: i64,
}

impl<'a> Detector<'a> {
    fn new(result: &'a ScanResult) -> Self {
        let home = fsx::home();
        let private_area = if cfg!(target_os = "macos") {
            Some(fsx::join(&home, "Library"))
        } else if cfg!(windows) {
            Some(fsx::join(&home, "AppData"))
        } else {
            None
        };
        #[cfg(unix)]
        let shared_temp = Some(super::temp::shared_temp());
        #[cfg(not(unix))]
        let shared_temp = None;
        Detector { result, home, private_area, shared_temp, now: fsx::now_secs() }
    }

    fn folders(&self) -> Vec<Suggestion> {
        let mut out = vec![];
        for item in self.result.items.values() {
            if !item.dir || item.size < MINIMUM || !self.is_user_area(&item.path) {
                continue;
            }
            let (path, name, size) = (item.path.as_str(), item.name.as_str(), item.size);
            if let Some(s) = self.generated(path, name, size).or_else(|| self.worktree(path, name, size)).or_else(|| self.temp_leftover(path, name, size)) {
                out.push(s);
            }
        }
        out
    }

    fn markers(&self, path: &str) -> Option<&std::collections::HashSet<String>> {
        self.result.markers.get(&fsx::key(path))
    }

    fn generated(&self, path: &str, name: &str, size: u64) -> Option<Suggestion> {
        let parent = fsx::parent(path);
        let empty = Default::default();
        let siblings = self.markers(&parent).unwrap_or(&empty);
        let inside = self.markers(path).unwrap_or(&empty);
        let project = fsx::name(&parent);
        let make = |title: String, safety, note: &str| Some(Suggestion { path: path.into(), title: format!("{title} · {project}"), note: note.into(), safety, size });
        let js = siblings.contains("package.json");
        let gradle_or_flutter = ["build.gradle", "build.gradle.kts", "pubspec.yaml"].iter().any(|m| siblings.contains(*m));
        use Safety::{Review, Safe};
        match name {
            "node_modules" if js => make("node_modules".into(), Review, "Installed packages. Come back with npm/pnpm/yarn install; remove for projects you're not working on."),
            ".next" | ".turbo" | ".nuxt" | ".svelte-kit" | ".parcel-cache" | ".angular" | ".output" if js => {
                make(format!("{name} build cache"), Safe, "Rebuilt on the next build or dev run. Stop the project's dev server first.")
            }
            "dist" | "build" if js => make(format!("{name} output"), Review, "Build output. Rebuilt by the project's build command."),
            "build" if gradle_or_flutter => make("build output".into(), Review, "Rebuilt on the next Gradle/Flutter build."),
            ".dart_tool" if siblings.contains("pubspec.yaml") => make(".dart_tool".into(), Safe, "Recreated by flutter pub get."),
            "target" if siblings.contains("Cargo.toml") => make("Rust target".into(), Review, "Rust build output. Rebuilt by cargo build (can take a while)."),
            "Pods" if siblings.contains("Podfile") => make("CocoaPods".into(), Review, "Reinstalled by pod install."),
            ".venv" | "venv" | "env" if inside.contains("pyvenv.cfg") => make("Python venv".into(), Review, "Recreate it and reinstall the project's packages."),
            _ => None,
        }
    }

    /// A linked git worktree: a checkout whose `.git` is a file pointing into another repo's .git/worktrees.
    fn worktree(&self, path: &str, name: &str, size: u64) -> Option<Suggestion> {
        if !self.markers(path)?.contains(GIT_FILE) {
            return None;
        }
        let link = std::fs::read_to_string(fsx::join(path, ".git")).ok()?;
        let gitdir = link.strip_prefix("gitdir:")?.trim().replace('\\', "/");
        if !gitdir.contains("/worktrees/") {
            return None; // submodules use .git/modules
        }
        let repo = gitdir.split("/.git/worktrees/").next().and_then(|r| r.rsplit('/').next()).unwrap_or("repo").to_string();
        let mut title = format!("Git worktree · {name}");
        let mut note = match std::fs::read_to_string(format!("{gitdir}/HEAD")) {
            Ok(head) => {
                let head = head.trim();
                let branch = head.strip_prefix("ref: refs/heads/").unwrap_or("detached");
                title += &format!(" ({branch})");
                format!("Extra checkout of {repo}. Anything not committed and pushed in it is lost. Then run git worktree prune in {repo}.")
            }
            Err(_) => format!("Extra checkout of {repo}, whose repository is gone. Anything not committed and pushed in it is lost."),
        };
        note += &format!(" Last changed {}.", self.age(path));
        Some(Suggestion { path: path.into(), title, note, safety: Safety::Review, size })
    }

    /// Items this user left in /tmp. Claude Code keeps one folder per session; each is offered separately.
    fn temp_leftover(&self, path: &str, name: &str, size: u64) -> Option<Suggestion> {
        let temp = self.shared_temp.as_ref()?;
        let rest = path.strip_prefix(&format!("{temp}{SEP}"))?;
        let parts: Vec<&str> = rest.split(SEP).collect();
        let top = parts.first()?;
        #[cfg(unix)]
        if fsx::owner(&fsx::join(temp, top)) != Some(fsx::my_uid()) {
            return None;
        }
        let restart = if cfg!(target_os = "macos") { " macOS clears /tmp only on restart." } else { "" };
        if top.starts_with("claude-") {
            if parts.len() != 3 {
                return None; // claude-<uid>/<project>/<session>
            }
            // Claude Code names the project folder after its path with / turned into -.
            let home_prefix = self.home.replace(SEP, "-") + "-";
            let project = parts[1].strip_prefix(&home_prefix).unwrap_or(parts[1]);
            let session: String = parts[2].chars().take(8).collect();
            return Some(Suggestion {
                path: path.into(),
                title: format!("Claude Code session · {project} · {session}"),
                note: format!("Scratch files and worktrees from a past Claude Code session, last changed {}. Skip the session you're running now.", self.age(path)),
                safety: Safety::Review,
                size,
            });
        }
        if parts.len() != 1 {
            return None;
        }
        Some(Suggestion {
            path: path.into(),
            title: format!("Temporary files · {name}"),
            note: format!("Left in /tmp by a tool or test run, last changed {}.{restart}", self.age(path)),
            safety: Safety::Review,
            size,
        })
    }

    fn files(&self) -> Vec<Suggestion> {
        let downloads = [fsx::join(&self.home, "Downloads"), fsx::join(&self.home, "Desktop")];
        let mut out = vec![];
        for file in &self.result.large_files {
            if !self.is_user_area(&file.path) {
                continue;
            }
            let ext = fsx::extension(&file.path);
            let in_downloads = downloads.iter().any(|d| fsx::inside(&file.path, d));
            let when = fsx::relative(file.modified, self.now);
            let name = fsx::name(&file.path);
            let (title, note) = if VIDEOS.contains(&ext.as_str()) && (file.size >= MINIMUM * 5 || in_downloads) {
                (format!("Video · {name}"), format!("Saved {when}. Delete if you've watched it or keep a copy elsewhere."))
            } else if in_downloads && INSTALLERS.contains(&ext.as_str()) {
                (format!("Installer or archive · {name}"), format!("Downloaded {when}. Not needed once the app is installed or the archive is unpacked."))
            } else if in_downloads {
                (format!("Download · {name}"), format!("Downloaded {when}. Delete if you no longer need it."))
            } else {
                continue;
            };
            out.push(Suggestion { path: file.path.clone(), title, note, safety: Safety::Review, size: file.size });
        }
        out
    }

    /// Your own files: home (minus the apps' private area and hidden tool folders) and /tmp. Never
    /// app internals, document bundles, or things nested inside a generated folder.
    fn is_user_area(&self, path: &str) -> bool {
        let base = if fsx::inside(path, &self.home) {
            &self.home
        } else if let Some(temp) = self.shared_temp.as_ref().filter(|t| fsx::inside(path, t)) {
            temp
        } else {
            return false;
        };
        if self.private_area.as_ref().is_some_and(|area| fsx::within(path, area)) {
            return false;
        }
        let rest = &path[base.trim_end_matches(SEP).len() + 1..];
        let parts: Vec<&str> = rest.split(SEP).collect();
        for part in &parts[..parts.len().saturating_sub(1)] {
            if part.starts_with('.') || GENERATED.contains(part) {
                return false;
            }
            if BUNDLES.contains(&fsx::extension(part).as_str()) {
                return false;
            }
        }
        true
    }

    fn age(&self, path: &str) -> String {
        fsx::info(path).map(|m| fsx::relative(fsx::modified_secs(&m), self.now)).unwrap_or_else(|| "a while ago".into())
    }
}
