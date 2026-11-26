//! macOS: .app bundles in /Applications and ~/Applications, and everything that belongs to one —
//! preferences, caches, containers, logs, saved state, launch agents and daemons, privileged
//! helpers, package receipts, command-line links and anything else in ~/Library named after it.

use super::{App, Confidence, Hits, Inspection, Listings, PERSONAL};
use crate::clean::fsx;
use std::collections::HashSet;

#[derive(Clone, Debug, Default)]
pub struct Extra {
    pub bundle_id: Option<String>,
    /// App groups from the code signature; each owns ~/Library/Group Containers/<group>.
    pub app_groups: Vec<String>,
    /// Labels of privileged helpers the app installs (Info.plist SMPrivilegedExecutables).
    pub helper_labels: Vec<String>,
}

/// Every app the user can remove: /Applications and ~/Applications, without macOS's own apps
/// and Clearspace itself.
pub fn bundles() -> Vec<String> {
    let home = fsx::home();
    let mut bundles = vec![];
    for root in ["/Applications".to_string(), fsx::join(&home, "Applications")] {
        collect(&root, 1, &mut bundles);
    }
    let own = own_bundle();
    let mut seen = HashSet::new();
    bundles.into_iter().map(|b| fsx::real_path(&b)).filter(|p| !is_system(p) && Some(p) != own.as_ref() && seen.insert(p.clone())).collect()
}

/// Identifier and name of every installed app, macOS's own included. Reads only each
/// Info.plist, so it is quick.
pub fn installed() -> Vec<(String, String)> {
    let home = fsx::home();
    let mut bundles = vec![];
    for root in ["/Applications".to_string(), fsx::join(&home, "Applications"), "/System/Applications".to_string()] {
        collect(&root, 1, &mut bundles);
    }
    bundles
        .iter()
        .filter_map(|path| {
            let info = ["Contents/Info.plist", "WrappedBundle/Info.plist"].iter().find_map(|rel| plist::Value::from_file(fsx::join(path, rel)).ok())?;
            let id = info.as_dictionary()?.get("CFBundleIdentifier")?.as_string()?.trim().to_string();
            let name = fsx::name(path);
            (!id.is_empty()).then(|| (id, name.strip_suffix(".app").unwrap_or(&name).to_string()))
        })
        .collect()
}

pub fn list() -> Vec<App> {
    let paths = bundles();
    // Reading code signatures takes ~30 ms an app, so read them side by side.
    let mut apps: Vec<App> = std::thread::scope(|scope| {
        let chunks: Vec<Vec<String>> = paths.chunks(paths.len().div_ceil(8).max(1)).map(|c| c.to_vec()).collect();
        let handles: Vec<_> = chunks.into_iter().map(|chunk| scope.spawn(move || chunk.iter().filter_map(|p| app(p)).collect::<Vec<_>>())).collect();
        handles.into_iter().flat_map(|h| h.join().unwrap_or_default()).collect()
    });
    apps.sort_by_key(|a| a.name.to_lowercase());
    apps
}

fn collect(dir: &str, depth: u32, out: &mut Vec<String>) {
    for name in fsx::list_names(dir) {
        if name.starts_with('.') {
            continue;
        }
        let path = fsx::join(dir, &name);
        if name.to_lowercase().ends_with(".app") {
            out.push(path);
        } else if depth < 2 && fsx::is_dir(&path) {
            collect(&path, depth + 1, out);
        }
    }
}

/// Apps on the sealed system volume (Safari's /Applications link included) can't be removed.
pub fn is_system(path: &str) -> bool {
    fsx::real_path(path).starts_with("/System/")
}

fn own_bundle() -> Option<String> {
    let exe = std::env::current_exe().ok()?.to_string_lossy().into_owned();
    exe.find(".app/").map(|i| fsx::real_path(&exe[..i + 4]))
}

pub fn app(path: &str) -> Option<App> {
    if !path.to_lowercase().ends_with(".app") || !fsx::is_dir(&fsx::real_path(path)) {
        return None;
    }
    let name = fsx::name(path);
    let name = name[..name.len() - 4].to_string();
    // iPhone/iPad apps on Apple silicon keep their Info.plist inside a wrapper.
    let info = ["Contents/Info.plist", "WrappedBundle/Info.plist"]
        .iter()
        .find_map(|rel| plist::Value::from_file(fsx::join(path, rel)).ok())
        .and_then(|v| v.into_dictionary());
    let text = |key: &str| info.as_ref().and_then(|d| d.get(key)).and_then(|v| v.as_string()).map(|s| s.trim().to_string()).filter(|s| !s.is_empty());
    let bundle_id = text("CFBundleIdentifier").or_else(|| spotlight_bundle_id(path));
    let helper_labels = info
        .as_ref()
        .and_then(|d| d.get("SMPrivilegedExecutables"))
        .and_then(|v| v.as_dictionary())
        .map(|d| d.keys().cloned().collect())
        .unwrap_or_default();
    Some(App {
        id: path.to_string(),
        name,
        version: text("CFBundleShortVersionString"),
        detail: bundle_id.clone(),
        location: Some(path.to_string()),
        icon: Some(path.to_string()),
        uninstaller: None,
        size: None,
        extra: Extra { bundle_id, app_groups: app_groups(path), helper_labels },
    })
}

/// com.apple.security.application-groups from the bundle's code signature.
fn app_groups(path: &str) -> Vec<String> {
    let Ok(out) = std::process::Command::new("/usr/bin/codesign").args(["-d", "--entitlements", "-", "--xml", path]).output() else { return vec![] };
    let Ok(value) = plist::Value::from_reader_xml(&out.stdout[..]) else { return vec![] };
    value
        .as_dictionary()
        .and_then(|d| d.get("com.apple.security.application-groups"))
        .and_then(|v| v.as_array())
        .map(|a| a.iter().filter_map(|g| g.as_string().map(String::from)).collect())
        .unwrap_or_default()
}

fn spotlight_bundle_id(path: &str) -> Option<String> {
    let out = std::process::Command::new("/usr/bin/mdls").args(["-raw", "-name", "kMDItemCFBundleIdentifier", path]).output().ok()?;
    let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!id.is_empty() && id != "(null)").then_some(id)
}

/// An app picked by hand (from Downloads, another disk…).
pub fn open(path: &str) -> Result<App, String> {
    let path = fsx::real_path(path);
    if is_system(&path) {
        return Err(format!("{} is part of macOS. Apps that ship with macOS live on the protected system volume and can't be removed.", fsx::name(&path).trim_end_matches(".app")));
    }
    app(&path).ok_or_else(|| "That isn't an app.".into())
}

pub fn pids(app: &App) -> Vec<i32> {
    crate::clean::mac::pids_inside(&app.id)
}

pub fn terminate(pids: &[i32]) {
    crate::clean::mac::terminate(pids)
}

pub fn run_uninstaller(_app: &App) -> Result<(), String> {
    Err("Mac apps have no separate uninstaller.".into())
}

const BIN_DIRS: [&str; 2] = ["/usr/local/bin", "/opt/homebrew/bin"];

pub fn inspect(app: &App, all: &[App]) -> Inspection {
    Finder::new(app, all).find()
}

struct Finder<'a> {
    app: &'a App,
    home: String,
    user_library: String,
    system_library: String,
    receipts: String,
    bin_dirs: Vec<String>,
    /// App groups other installed apps also claim; those containers hold the other apps' data too.
    shared_groups: HashSet<String>,
    hits: Hits,
    listings: Listings,
    mentions: Vec<String>,
}

impl<'a> Finder<'a> {
    fn new(app: &'a App, all: &[App]) -> Self {
        let home = fsx::home();
        let mut bin_dirs: Vec<String> = BIN_DIRS.iter().map(|s| s.to_string()).collect();
        bin_dirs.extend([".local/bin", "bin", ".docker/cli-plugins"].map(|d| fsx::join(&home, d)));
        Finder {
            app,
            user_library: fsx::join(&home, "Library"),
            system_library: "/Library".into(),
            receipts: "/private/var/db/receipts".into(),
            bin_dirs,
            shared_groups: all.iter().filter(|a| a.id != app.id).flat_map(|a| a.extra.app_groups.iter().cloned()).collect(),
            home,
            hits: Hits::default(),
            listings: Listings::default(),
            mentions: vec![],
        }
    }

    fn find(mut self) -> Inspection {
        let app = self.app;
        let name = app.name.clone();
        self.hits.add(&app.id, "application", Confidence::Exact);
        for base in [self.user_library.clone(), self.system_library.clone()] {
            let b = |rel: &str| fsx::join(&base, rel);
            self.child(&b("Application Support"), &name, Confidence::Exact);
            self.child(&b("Caches"), &name, Confidence::Exact);
            self.child(&b("Logs"), &name, Confidence::Exact);
            self.child(&b("PreferencePanes"), &format!("{name}.prefPane"), Confidence::Exact);
            if let Some(id) = app.extra.bundle_id.clone() {
                let prefix = id.to_lowercase() + ".";
                self.child(&b("Application Support"), &id, Confidence::Exact);
                self.child(&b("Caches"), &id, Confidence::Exact);
                self.child(&b("Preferences"), &format!("{id}.plist"), Confidence::Exact);
                self.child(&b("Containers"), &id, Confidence::Exact);
                self.child(&b("Application Scripts"), &id, Confidence::Exact);
                for group in &app.extra.app_groups {
                    let confidence = if self.shared_groups.contains(group) { Confidence::NameOnly } else { Confidence::Exact };
                    self.child(&b("Group Containers"), group, confidence);
                    self.child(&b("Application Scripts"), group, confidence);
                }
                self.entries(&b("Preferences/ByHost"), |e| e.to_lowercase().starts_with(&prefix) && e.ends_with(".plist"));
                self.entries(&b("WebKit"), |e| fsx::contains_word(e, &id));
                self.entries(&b("HTTPStorages"), |e| fsx::contains_word(e, &id));
                self.entries(&b("Saved Application State"), |e| fsx::contains_word(e, &id) && e.ends_with(".savedState"));
            }
            self.matches(&b("LaunchAgents"), |e| e.ends_with(".plist"));
            self.matches(&b("LaunchDaemons"), |e| e.ends_with(".plist"));
            self.matches(&b("Group Containers"), |_| true);
            self.launch_jobs(&b("LaunchAgents"));
            self.launch_jobs(&b("LaunchDaemons"));
            for label in &app.extra.helper_labels {
                self.child(&b("PrivilegedHelperTools"), label, Confidence::Exact);
            }
        }
        if let Some(id) = &app.extra.bundle_id {
            let prefix = id.to_lowercase() + ".";
            let receipts = self.receipts.clone();
            self.entries(&receipts, |e| e.to_lowercase().starts_with(&prefix));
        }
        self.sweep_user_library();
        self.home_folders();
        self.links_into_app();
        self.docker_contexts();
        let mut needles = vec![app.id.clone(), format!("/.{}/", name.to_lowercase())];
        needles.extend(app.extra.bundle_id.clone());
        self.mentions.extend(super::mentions(&needles, &name));
        self.mentions.sort();
        self.mentions.dedup();
        let never = vec![self.user_library.clone(), self.system_library.clone()];
        let mut leftovers = self.hits.finish(&[], &never);
        leftovers.retain(|l| !l.path.starts_with("/System/"));
        for l in &mut leftovers {
            l.kind = kind(&l.path, app, &self.user_library, &self.system_library, &self.receipts, &self.bin_dirs, &self.home);
        }
        Inspection { leftovers, mentions: self.mentions }
    }

    fn child(&mut self, dir: &str, name: &str, confidence: Confidence) {
        self.hits.add_child(dir, name, "other", confidence, &mut self.listings);
    }

    fn entries(&mut self, dir: &str, include: impl Fn(&str) -> bool) {
        for e in self.listings.get(dir) {
            if include(&e) {
                self.hits.add(&fsx::join(dir, &e), "other", Confidence::Exact);
            }
        }
    }

    fn matches(&mut self, dir: &str, include: impl Fn(&str) -> bool) {
        for e in self.listings.get(dir) {
            if include(&e) {
                if let Some(c) = self.matching(&e) {
                    self.hits.add(&fsx::join(dir, &e), "other", c);
                }
            }
        }
    }

    fn matching(&self, entry: &str) -> Option<Confidence> {
        if self.app.extra.bundle_id.as_ref().is_some_and(|id| fsx::contains_word(entry, id)) {
            return Some(Confidence::Exact);
        }
        fsx::contains_word(entry, &self.app.name).then_some(Confidence::NameOnly)
    }

    /// launchd jobs that name the app: by AssociatedBundleIdentifiers, by a helper label the app
    /// declares, or by running a program inside the bundle. The helper binary they run goes too.
    fn launch_jobs(&mut self, dir: &str) {
        let app_prefix = format!("{}/", self.app.id);
        for entry in self.listings.get(dir) {
            if !entry.ends_with(".plist") {
                continue;
            }
            let path = fsx::join(dir, &entry);
            let Some(job) = plist::Value::from_file(&path).ok().and_then(|v| v.into_dictionary()) else { continue };
            let label = job.get("Label").and_then(|v| v.as_string()).unwrap_or("");
            let program = job
                .get("Program")
                .and_then(|v| v.as_string())
                .or_else(|| job.get("ProgramArguments").and_then(|v| v.as_array()).and_then(|a| a.first()).and_then(|v| v.as_string()))
                .unwrap_or("")
                .to_string();
            let associated: Vec<&str> = job.get("AssociatedBundleIdentifiers").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|v| v.as_string()).collect()).unwrap_or_default();
            let owned = self.app.extra.bundle_id.as_deref().is_some_and(|id| associated.contains(&id)) || self.app.extra.helper_labels.iter().any(|l| l == label) || program.starts_with(&app_prefix);
            if !owned {
                continue;
            }
            self.hits.add(&path, "other", Confidence::Exact);
            let system = ["/System/", "/usr/bin/", "/bin/", "/usr/sbin/"].iter().any(|p| program.starts_with(p));
            if program.starts_with('/') && !program.starts_with(&app_prefix) && !system {
                self.hits.add(&program, "other", Confidence::Exact);
            }
        }
    }

    /// ~/.<name>, ~/<Name> and the XDG folders (~/.config/<name>, ~/.cache/<name>, …).
    fn home_folders(&mut self) {
        let name = self.app.name.clone();
        let lower = name.to_lowercase();
        if name.is_empty() || PERSONAL.contains(&lower.as_str()) || PERSONAL.contains(&format!(".{lower}").as_str()) {
            return;
        }
        let home = self.home.clone();
        for candidate in [name.clone(), format!(".{name}")] {
            self.child(&home, &candidate, Confidence::Exact);
        }
        for xdg in [".config", ".cache", ".local/share", ".local/state"] {
            self.child(&fsx::join(&home, xdg), &name, Confidence::Exact);
        }
    }

    /// Command-line links an app installs (docker, kubectl, code…) that point into its bundle.
    fn links_into_app(&mut self) {
        let app_prefix = format!("{}/", self.app.id);
        for dir in self.bin_dirs.clone() {
            for entry in self.listings.get(&dir) {
                let path = fsx::join(&dir, &entry);
                let Ok(target) = std::fs::read_link(&path) else { continue };
                // The resolved path follows the whole chain; the raw target covers links already dangling.
                let resolved = fsx::real_path(&path);
                if resolved == self.app.id || resolved.starts_with(&app_prefix) || target.to_string_lossy().starts_with(&app_prefix) {
                    self.hits.add(&path, "commandLineTools", Confidence::Exact);
                }
            }
        }
    }

    /// Docker CLI contexts an app registers (~/.docker/contexts/meta/<hash>/meta.json "Name").
    fn docker_contexts(&mut self) {
        let contexts = fsx::join(&self.home, ".docker/contexts");
        for hash in self.listings.get(&fsx::join(&contexts, "meta")) {
            let meta = fsx::join(&contexts, &format!("meta/{hash}"));
            let Ok(text) = std::fs::read_to_string(fsx::join(&meta, "meta.json")) else { continue };
            let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
            let Some(context) = json.get("Name").and_then(|n| n.as_str()) else { continue };
            if !context.eq_ignore_ascii_case(&self.app.name) {
                continue;
            }
            self.hits.add(&meta, "homeData", Confidence::Exact);
            self.hits.add(&fsx::join(&contexts, &format!("tls/{hash}")), "homeData", Confidence::Exact);
            // The Docker CLI fails on every command while its current context is missing.
            let config = fsx::join(&self.home, ".docker/config.json");
            let current = std::fs::read_to_string(&config).ok().and_then(|t| serde_json::from_str::<serde_json::Value>(&t).ok()).and_then(|j| j.get("currentContext").and_then(|c| c.as_str()).map(String::from));
            if current.as_deref() == Some(context) {
                self.mentions.push(config);
            }
        }
    }

    /// Catches leftovers in nonstandard places: anything in ~/Library (four levels deep) named after the app.
    fn sweep_user_library(&mut self) {
        let lib = self.user_library.clone();
        // Personal data that is never an app's leftover, however it's named.
        let skipped: HashSet<String> = ["Mail", "Messages", "Mobile Documents", "CloudStorage", "Keychains", "Calendars", "Safari", "Photos", "Accounts", "Biome", "Daemon Containers"].iter().map(|d| fsx::join(&lib, d)).collect();
        // Other apps' sandboxes: test their folder names, but never look inside them.
        let shallow: HashSet<String> = [fsx::join(&lib, "Containers"), fsx::join(&lib, "Group Containers")].into();
        let caches_or_logs = [fsx::join(&lib, "Caches"), fsx::join(&lib, "Logs")];
        let mut pending = vec![(lib.clone(), 0)];
        while let Some((dir, depth)) = pending.pop() {
            for entry in fsx::list_names(&dir) {
                let path = fsx::join(&dir, &entry);
                if let Some(mut confidence) = self.matching(&entry) {
                    // A folder named exactly after the app inside a cache or log store
                    // (Caches/SentryCrash/OrbStack) is that app's, and regenerable even if not.
                    if confidence == Confidence::NameOnly && entry.eq_ignore_ascii_case(&self.app.name) && caches_or_logs.iter().any(|c| fsx::inside(&path, c)) {
                        confidence = Confidence::Exact;
                    }
                    self.hits.add(&path, "other", confidence);
                    continue;
                }
                if depth + 1 < 4 && !shallow.contains(&dir) && !skipped.contains(&path) && fsx::is_dir(&path) {
                    pending.push((path, depth + 1));
                }
            }
        }
    }
}

fn kind(path: &str, app: &App, user_library: &str, system_library: &str, receipts: &str, bin_dirs: &[String], home: &str) -> &'static str {
    if path == app.id {
        return "application";
    }
    if fsx::inside(path, receipts) {
        return "receipts";
    }
    for base in [user_library, system_library] {
        if fsx::inside(path, base) {
            let top = path[base.len() + 1..].split('/').next().unwrap_or("");
            return match top {
                "Application Support" | "Application Scripts" | "PreferencePanes" => "support",
                "Caches" => "caches",
                "Preferences" => "preferences",
                "Containers" => "containers",
                "Group Containers" => "groupContainers",
                "Saved Application State" => "savedState",
                "WebKit" | "HTTPStorages" | "Cookies" => "webData",
                "Logs" => "logs",
                "LaunchAgents" | "LaunchDaemons" | "PrivilegedHelperTools" => "launchItems",
                _ => "other",
            };
        }
    }
    if bin_dirs.iter().any(|d| fsx::inside(path, d)) {
        return "commandLineTools";
    }
    if fsx::inside(path, home) {
        return "homeData";
    }
    "other"
}

#[cfg(test)]
mod tests {
    /// Dev aid: `cargo test inspect_real_app -- --ignored --nocapture` lists what an installed app owns.
    #[test]
    #[ignore]
    fn inspect_real_app() {
        let apps = super::list();
        let name = std::env::var("APP").unwrap_or_else(|_| "Discord".into());
        let app = apps.iter().find(|a| a.name == name).expect("app installed");
        println!("{} {:?} groups={:?}", app.name, app.extra.bundle_id, app.extra.app_groups);
        let found = super::inspect(app, &apps);
        for l in &found.leftovers {
            println!("  {:<16} {:?} {}", l.kind, l.confidence, l.path);
        }
        println!("  mentions: {:?}", found.mentions);
    }
}
