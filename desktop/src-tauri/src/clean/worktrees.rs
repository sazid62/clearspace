//! Git worktrees and everything that belongs to each: the checkout folder, where its branch stands
//! (merged, uncommitted, unpushed), and the Docker containers, volumes and images started from it.
//! Folders are found by the scan wherever they are; git and Docker are asked through their CLIs.

use super::fsx;
use super::scan::{GIT_FILE, ScanResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::{Duration, Instant};

const GIT_WAIT: Duration = Duration::from_secs(30);
const DOCKER_WAIT: Duration = Duration::from_secs(30);
/// Docker measures every volume for this one.
const DOCKER_SIZES_WAIT: Duration = Duration::from_secs(120);
const PROJECT: &str = "com.docker.compose.project";

#[derive(Serialize, Deserialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct Worktree {
    pub path: String,
    pub name: String,
    /// The repository's main checkout ("" when unknown).
    pub repo: String,
    pub repo_name: String,
    /// None on a detached HEAD.
    pub branch: Option<String>,
    /// Its repository is gone or no longer lists this checkout.
    pub lost: bool,
    /// The folder is gone; only what Docker kept for it is left.
    pub deleted: bool,
    pub size: u64,
    /// Seconds since 1970; 0 when unknown.
    pub modified: i64,
}

// MARK: Finding them

/// Where a linked worktree's `.git` file points.
pub struct Link {
    /// The repository's record of this checkout: `<repo>/.git/worktrees/<id>`.
    pub admin: String,
    /// The repository's git folder.
    pub common: String,
}

/// None unless `path` is a linked worktree (submodules point into `.git/modules` instead).
pub fn link(path: &str) -> Option<Link> {
    let text = std::fs::read_to_string(fsx::join(path, ".git")).ok()?;
    let raw = text.lines().next()?.strip_prefix("gitdir:")?.trim();
    let admin = absolute(path, raw);
    let worktrees = fsx::parent(&admin);
    let common = fsx::parent(&worktrees);
    (fsx::name(&worktrees) == "worktrees" && !common.is_empty()).then_some(Link { admin, common })
}

/// `raw` as git wrote it (absolute or relative to `base`, "/" even on Windows) as a plain path.
fn absolute(base: &str, raw: &str) -> String {
    use std::path::{Component, Path, PathBuf};
    let mut out = PathBuf::new();
    for part in Path::new(base).join(raw).components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out.to_string_lossy().into_owned()
}

/// Every linked worktree the scan walked past, including ones in hidden folders (.claude/worktrees).
pub fn find(result: &ScanResult) -> Vec<Worktree> {
    let mut out = vec![];
    for (key, marks) in &result.markers {
        if !marks.contains(GIT_FILE) {
            continue;
        }
        let item = result.items.get(key);
        // Small folders aren't kept by the scan, and on Windows the key is lower-cased.
        let path = item.map(|i| i.path.clone()).unwrap_or_else(|| if cfg!(windows) { fsx::real_path(key) } else { key.clone() });
        let Some(link) = link(&path) else { continue };
        let repo = if fsx::name(&link.common) == ".git" { fsx::parent(&link.common) } else { link.common.clone() };
        let head = std::fs::read_to_string(fsx::join(&link.admin, "HEAD")).unwrap_or_default();
        let changed = |p: &str| fsx::info(p).map(|m| fsx::modified_secs(&m)).unwrap_or(0);
        out.push(Worktree {
            name: fsx::name(&path),
            repo_name: fsx::name(&repo).trim_end_matches(".git").to_string(),
            repo,
            branch: head.trim().strip_prefix("ref: refs/heads/").map(str::to_string),
            lost: !fsx::is_dir(&link.admin),
            deleted: false,
            size: item.map(|i| i.size).unwrap_or_else(|| fsx::allocated_size(&path)),
            // The folder itself, or the last commit, checkout or pull in it.
            modified: changed(&path).max(changed(&fsx::join(&link.admin, "logs/HEAD"))),
            path,
        });
    }
    out.sort_by(|a, b| b.size.cmp(&a.size));
    out
}

/// After a worktree's folder is deleted: drops the repository's record of it, as `git worktree
/// prune` would, but only this one.
pub fn forget(link: &Link, path: &str) {
    if fsx::exists(path) || fsx::exists(&fsx::join(&link.admin, "locked")) {
        return;
    }
    let back = std::fs::read_to_string(fsx::join(&link.admin, "gitdir")).unwrap_or_default();
    if fsx::key(&absolute(&link.admin, back.trim())) != fsx::key(&absolute(path, ".git")) {
        return; // the record points somewhere else
    }
    if std::fs::remove_dir_all(&link.admin).is_ok() {
        let _ = std::fs::remove_dir(fsx::parent(&link.admin)); // only goes when empty
    }
}

// MARK: Running git and docker

struct Output {
    ok: bool,
    text: String,
    error: String,
}

/// Runs a command without a window, giving up after `wait`. None when it couldn't start.
fn run(program: &str, args: &[&str], wait: Duration) -> Option<Output> {
    use std::io::Read;
    use std::process::{Command, Stdio};
    let mut command = Command::new(program);
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
    // Plain English output ("gone"), and never a password prompt or a refreshed index.
    command.env("LC_ALL", "C").env("GIT_TERMINAL_PROMPT", "0").env("GIT_OPTIONAL_LOCKS", "0");
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const NO_WINDOW: u32 = 0x0800_0000;
        command.creation_flags(NO_WINDOW);
    }
    let mut child = command.spawn().ok()?;
    let (mut out, mut err) = (child.stdout.take()?, child.stderr.take()?);
    // Read while it runs: a full pipe would stall the command.
    let out_reader = std::thread::spawn(move || {
        let mut bytes = vec![];
        let _ = out.read_to_end(&mut bytes);
        bytes
    });
    let err_reader = std::thread::spawn(move || {
        let mut bytes = vec![];
        let _ = err.read_to_end(&mut bytes);
        bytes
    });
    let started = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Some(status),
            Ok(None) if started.elapsed() < wait => std::thread::sleep(Duration::from_millis(15)),
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        }
    };
    let text = String::from_utf8_lossy(&out_reader.join().unwrap_or_default()).into_owned();
    let error = String::from_utf8_lossy(&err_reader.join().unwrap_or_default()).trim().to_string();
    Some(Output { ok: status.is_some_and(|s| s.success()), text, error: if status.is_none() { "It didn't answer in time.".into() } else { error } })
}

/// Full path of a command-line tool. Apps opened from the Dock or a launcher get a bare PATH, so
/// the usual install folders are checked too.
fn tool(name: &str) -> Option<String> {
    let home = fsx::home();
    let from_path: Vec<String> = std::env::var_os("PATH").map(|p| std::env::split_paths(&p).map(|d| d.to_string_lossy().into_owned()).collect()).unwrap_or_default();
    let mut dirs: Vec<String> = vec![];
    if cfg!(target_os = "macos") {
        dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/Library/Developer/CommandLineTools/usr/bin", "/Applications/Xcode.app/Contents/Developer/usr/bin", "/Applications/Docker.app/Contents/Resources/bin"].map(String::from));
        dirs.extend([".docker/bin", ".orbstack/bin", ".rd/bin"].map(|d| fsx::join(&home, d)));
        // /usr/bin holds stubs that offer to install Xcode's tools when they're missing.
        dirs.extend(from_path.into_iter().filter(|d| d.trim_end_matches('/') != "/usr/bin"));
    } else {
        dirs.extend(from_path);
        if cfg!(target_os = "linux") {
            dirs.extend(["/usr/bin", "/usr/local/bin", "/snap/bin"].map(String::from));
            dirs.push(fsx::join(&home, ".rd/bin"));
        }
    }
    let file = if cfg!(windows) { format!("{name}.exe") } else { name.to_string() };
    dirs.iter().map(|d| fsx::join(d, &file)).find(|p| std::fs::metadata(p).is_ok_and(|m| m.is_file()))
}

// MARK: Git

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct GitStatus {
    /// Files changed or added in the folder and never committed.
    pub dirty: u32,
    /// Commits that aren't in the main branch; None when there's no main branch to compare with.
    pub ahead: Option<u32>,
    /// Commits that aren't on any remote (0 when the repository has no remote).
    pub unpushed: u32,
    /// Its branch was pushed once and the remote branch has since been deleted.
    pub upstream_gone: bool,
    /// The main branch compared with ("main").
    pub base: Option<String>,
}

/// None when git isn't installed or can't read the checkout.
fn git_status(git: &str, worktree: &Worktree) -> Option<GitStatus> {
    if worktree.lost || worktree.deleted {
        return None;
    }
    let ask = |args: &[&str]| run(git, &[&["-C", &worktree.path][..], args].concat(), GIT_WAIT).filter(|o| o.ok).map(|o| o.text);
    let count = |text: Option<String>| text.and_then(|t| t.trim().parse::<u32>().ok());
    let dirty = ask(&["status", "--porcelain"])?.lines().count() as u32;
    let refs = ask(&["for-each-ref", "--format=%(refname) %(symref)", "refs/remotes", "refs/heads/main", "refs/heads/master"]).unwrap_or_default();
    let (base, has_remotes) = main_branch(&refs);
    let ahead = base.as_ref().and_then(|b| count(ask(&["rev-list", "--count", &format!("{b}..HEAD")])));
    let unpushed = if has_remotes { count(ask(&["rev-list", "--count", "HEAD", "--not", "--remotes"])).unwrap_or(0) } else { 0 };
    let track = worktree.branch.as_ref().and_then(|b| ask(&["for-each-ref", "--format=%(upstream:track)", &format!("refs/heads/{b}")])).unwrap_or_default();
    Some(GitStatus { dirty, ahead, unpushed, upstream_gone: track.contains("gone"), base: base.map(|b| short_branch(&b)) })
}

/// The ref to measure "merged" against, from a `%(refname) %(symref)` listing, and whether the
/// repository has any remote branch. The remote's default branch wins over a local main.
fn main_branch(listing: &str) -> (Option<String>, bool) {
    let refs: HashMap<&str, &str> = listing.lines().filter_map(|l| l.split_once(' ').or(Some((l, "")))).map(|(name, target)| (name.trim(), target.trim())).filter(|(name, _)| !name.is_empty()).collect();
    let has_remotes = refs.keys().any(|r| r.starts_with("refs/remotes/"));
    let default = refs.get("refs/remotes/origin/HEAD").copied().filter(|target| refs.contains_key(target));
    let known = ["refs/remotes/origin/main", "refs/remotes/origin/master", "refs/heads/main", "refs/heads/master"];
    (default.or_else(|| known.into_iter().find(|r| refs.contains_key(r))).map(str::to_string), has_remotes)
}

fn short_branch(full: &str) -> String {
    match full.strip_prefix("refs/heads/") {
        Some(local) => local.to_string(),
        // refs/remotes/origin/main → main
        None => full.strip_prefix("refs/remotes/").and_then(|r| r.split_once('/')).map(|(_, branch)| branch.to_string()).unwrap_or_else(|| full.to_string()),
    }
}

// MARK: Docker

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Resource {
    /// "docker:<kind>:<reference>:<name>"; sent back to remove it.
    pub id: String,
    /// Path of the worktree (or deleted folder) it belongs to.
    pub worktree: String,
    /// "container", "volume" or "image".
    pub kind: &'static str,
    pub name: String,
    pub detail: String,
    pub size: u64,
    /// False when matched only by the compose project's name.
    pub certain: bool,
    pub running: bool,
}

#[derive(Default, Clone, Debug)]
struct Container {
    id: String,
    name: String,
    image_id: String,
    image_name: String,
    state: String,
    running: bool,
    project: String,
    /// The folder compose (or a dev container) was started in.
    folder: String,
    /// Folders of this computer mounted into it.
    binds: Vec<String>,
    /// Volumes mounted into it: name and where.
    volumes: Vec<(String, String)>,
    size: u64,
}

#[derive(Default, Clone, Debug)]
struct Image {
    id: String,
    name: String,
    /// The compose project that built it, if one did.
    project: String,
    size: u64,
}

#[derive(Default, Clone, Debug)]
struct Volume {
    name: String,
    project: String,
    size: u64,
}

#[derive(Default, Debug)]
struct Docker {
    containers: Vec<Container>,
    images: Vec<Image>,
    volumes: Vec<Volume>,
}

/// Image ids appear with and without the "sha256:" prefix.
fn image_id(id: &str) -> String {
    id.trim_start_matches("sha256:").to_string()
}

/// "432.1MB", "193kB (virtual 311MB)", "0B": Docker's sizes, in thousands.
fn parse_size(text: &str) -> u64 {
    let first = text.split_whitespace().next().unwrap_or("");
    let split = first.find(|c: char| !(c.is_ascii_digit() || c == '.')).unwrap_or(first.len());
    let unit = match first[split..].to_ascii_lowercase().as_str() {
        "kb" => 1e3,
        "mb" => 1e6,
        "gb" => 1e9,
        "tb" => 1e12,
        _ => 1.0,
    };
    (first[..split].parse::<f64>().unwrap_or(0.0) * unit) as u64
}

/// `docker inspect` output for containers.
fn parse_containers(json: &str) -> Vec<Container> {
    let Ok(Value::Array(list)) = serde_json::from_str::<Value>(json) else { return vec![] };
    list.iter()
        .map(|v| {
            let text = |pointer: &str| v.pointer(pointer).and_then(Value::as_str).unwrap_or("").to_string();
            let label = |key: &str| v.pointer("/Config/Labels").and_then(|l| l.get(key)).and_then(Value::as_str).unwrap_or("").to_string();
            let mut container = Container {
                id: text("/Id"),
                name: text("/Name").trim_start_matches('/').to_string(),
                image_id: image_id(&text("/Image")),
                image_name: text("/Config/Image"),
                state: text("/State/Status"),
                running: v.pointer("/State/Running").and_then(Value::as_bool).unwrap_or(false),
                project: label(PROJECT),
                folder: Some(label("com.docker.compose.project.working_dir")).filter(|f| !f.is_empty()).unwrap_or_else(|| label("devcontainer.local_folder")),
                ..Default::default()
            };
            for mount in v.get("Mounts").and_then(Value::as_array).into_iter().flatten() {
                let field = |key: &str| mount.get(key).and_then(Value::as_str).unwrap_or("").to_string();
                match field("Type").as_str() {
                    // Docker Desktop for Mac may show the host's folders under /host_mnt.
                    "bind" => container.binds.push(field("Source").trim_start_matches("/host_mnt").to_string()),
                    "volume" => container.volumes.push((field("Name"), field("Destination"))),
                    _ => {}
                }
            }
            container
        })
        .collect()
}

/// Adds sizes, images and volumes from `docker system df --verbose --format '{{json .}}'`.
fn apply_usage(docker: &mut Docker, json: &str) {
    let Ok(usage) = serde_json::from_str::<Value>(json) else { return };
    let list = |key: &str| usage.get(key).and_then(Value::as_array).cloned().unwrap_or_default();
    let text = |v: &Value, key: &str| v.get(key).and_then(Value::as_str).unwrap_or("").to_string();
    for c in list("Containers") {
        if let Some(container) = docker.containers.iter_mut().find(|k| k.id == text(&c, "ID")) {
            container.size = parse_size(&text(&c, "Size"));
        }
    }
    for i in list("Images") {
        let id = image_id(&text(&i, "ID"));
        if docker.images.iter().any(|k| k.id == id) {
            continue; // one row per tag
        }
        let (repository, tag) = (text(&i, "Repository"), text(&i, "Tag"));
        let name = if repository.is_empty() || repository == "<none>" { String::new() } else if tag.is_empty() || tag == "<none>" { repository } else { format!("{repository}:{tag}") };
        // What deleting it frees: layers shared with other images stay.
        let size = Some(text(&i, "UniqueSize")).filter(|s| !s.is_empty()).unwrap_or_else(|| text(&i, "Size"));
        docker.images.push(Image { id, name, project: String::new(), size: parse_size(&size) });
    }
    for v in list("Volumes") {
        let labels = text(&v, "Labels");
        let project = labels.split(',').find_map(|l| l.strip_prefix(&format!("{PROJECT}="))).unwrap_or("").to_string();
        docker.volumes.push(Volume { name: text(&v, "Name"), project, size: parse_size(&text(&v, "Size")) });
    }
}

/// Only a Docker on this computer: another machine's folders say nothing about the ones here.
fn local_engine(docker: &str) -> bool {
    let local = |host: &str| host.is_empty() || host.starts_with("unix://") || host.starts_with("npipe://");
    if !local(&std::env::var("DOCKER_HOST").unwrap_or_default()) {
        return false;
    }
    match run(docker, &["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"], DOCKER_WAIT) {
        Some(out) if out.ok => local(out.text.trim()),
        _ => true, // a Docker too old for contexts is local
    }
}

/// Everything Docker holds, or None when it isn't running.
fn load_docker(docker: &str) -> Option<Docker> {
    let ids = run(docker, &["ps", "--all", "--quiet", "--no-trunc"], DOCKER_WAIT).filter(|o| o.ok)?.text;
    let ids: Vec<&str> = ids.split_whitespace().collect();
    let mut found = Docker::default();
    for chunk in ids.chunks(50) {
        let args = [&["inspect", "--type", "container"][..], chunk].concat();
        if let Some(out) = run(docker, &args, DOCKER_WAIT).filter(|o| o.ok) {
            found.containers.extend(parse_containers(&out.text));
        }
    }
    if let Some(out) = run(docker, &["system", "df", "--verbose", "--format", "{{json .}}"], DOCKER_SIZES_WAIT).filter(|o| o.ok) {
        apply_usage(&mut found, &out.text);
    }
    // Compose labels the images it builds with its project.
    let labelled = run(docker, &["image", "ls", "--quiet", "--no-trunc", "--filter", &format!("label={PROJECT}")], DOCKER_WAIT).filter(|o| o.ok).map(|o| o.text).unwrap_or_default();
    let labelled: Vec<&str> = labelled.split_whitespace().collect::<HashSet<_>>().into_iter().collect();
    let format = format!("{{{{.Id}}}}\t{{{{index .Config.Labels \"{PROJECT}\"}}}}");
    for chunk in labelled.chunks(50) {
        let args = [&["image", "inspect", "--format", &format][..], chunk].concat();
        let Some(out) = run(docker, &args, DOCKER_WAIT).filter(|o| o.ok) else { continue };
        for (id, project) in out.text.lines().filter_map(|l| l.split_once('\t')) {
            if let Some(image) = found.images.iter_mut().find(|i| i.id == image_id(id)) {
                image.project = project.trim().to_string();
            }
        }
    }
    Some(found)
}

/// The project name compose derives from a folder's name.
fn compose_name(folder: &str) -> String {
    let kept: String = folder.to_lowercase().chars().filter(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == '-' || *c == '_').collect();
    kept.trim_start_matches(['-', '_']).to_string()
}

/// Sorts Docker's contents into the worktrees they belong to. A container belongs to the
/// worktree compose was started in (or whose folder it mounts); a volume or image belongs to a
/// worktree only when nothing outside it uses it. Also returns folders that are gone while their
/// containers remain, when they were inside `roots`.
fn assign(worktrees: &[Worktree], docker: &Docker, roots: &[String]) -> (Vec<Resource>, Vec<Worktree>) {
    let deepest = |path: &str| worktrees.iter().filter(|w| fsx::within(path, &w.path)).max_by_key(|w| w.path.len()).map(|w| w.path.clone());
    let is_gone = |folder: &str| std::path::Path::new(folder).is_absolute() && roots.iter().any(|r| fsx::inside(folder, r)) && !fsx::exists(folder);
    // Which group each container is in: a worktree, a deleted folder, or neither.
    let owners: Vec<Option<String>> = docker
        .containers
        .iter()
        .map(|c| match c.folder.as_str() {
            "" => c.binds.iter().find_map(|b| deepest(b)),
            folder => deepest(folder).or_else(|| is_gone(folder).then(|| folder.to_string())),
        })
        .collect();
    let mut deleted: Vec<Worktree> = vec![];
    for owner in owners.iter().flatten() {
        if !worktrees.iter().any(|w| &w.path == owner) && !deleted.iter().any(|w| &w.path == owner) {
            deleted.push(Worktree { path: owner.clone(), name: fsx::name(owner), repo: String::new(), repo_name: String::new(), branch: None, lost: false, deleted: true, size: 0, modified: 0 });
        }
    }

    let mut out: Vec<Resource> = vec![];
    let mut add = |worktree: &str, kind: &'static str, reference: &str, name: String, detail: String, size: u64, certain: bool, running: bool| {
        let id = format!("docker:{kind}:{reference}:{name}");
        if !out.iter().any(|r| r.kind == kind && r.id == id) {
            out.push(Resource { id, worktree: worktree.to_string(), kind, name, detail, size, certain, running });
        }
    };
    // True when every container passing `uses` is in `group` (also true when none does).
    let only = |group: &str, uses: &dyn Fn(&Container) -> bool| docker.containers.iter().zip(&owners).filter(|(c, _)| uses(c)).all(|(_, owner)| owner.as_deref() == Some(group));
    let volume_name = |name: &str| if name.len() == 64 && name.chars().all(|c| c.is_ascii_hexdigit()) { format!("{}…", &name[..12]) } else { name.to_string() };
    let image_name = |image: &Image| if image.name.is_empty() { image.id.chars().take(12).collect() } else { image.name.clone() };

    for (container, owner) in docker.containers.iter().zip(&owners) {
        let Some(group) = owner else { continue };
        add(group, "container", &container.id, container.name.clone(), format!("{} · {}", container.image_name, container.state), container.size, true, container.running);
        for (volume, destination) in &container.volumes {
            if only(group, &|c| c.volumes.iter().any(|(v, _)| v == volume)) {
                let size = docker.volumes.iter().find(|v| &v.name == volume).map(|v| v.size).unwrap_or(0);
                add(group, "volume", volume, volume_name(volume), format!("Mounted at {destination} in {}", container.name), size, true, false);
            }
        }
        if only(group, &|c| c.image_id == container.image_id) {
            let known = docker.images.iter().find(|i| i.id == container.image_id);
            let name = known.map(image_name).unwrap_or_else(|| container.image_name.clone());
            add(group, "image", &container.image_id, name, "Used only by containers started here.".into(), known.map(|i| i.size).unwrap_or(0), true, false);
        }
    }

    // Volumes and images compose labelled with a project. Kept when the containers are removed.
    let mut projects: HashMap<&str, HashSet<Option<&str>>> = HashMap::new();
    for (container, owner) in docker.containers.iter().zip(&owners).filter(|(c, _)| !c.project.is_empty()) {
        projects.entry(&container.project).or_default().insert(owner.as_deref());
    }
    // (group, certain): the one group a project runs in, or the one worktree named like it.
    let home_of = |project: &str| -> Option<(String, bool)> {
        match projects.get(project) {
            Some(groups) => match groups.iter().collect::<Vec<_>>()[..] {
                [Some(group)] => Some((group.to_string(), true)),
                _ => None, // also runs somewhere else
            },
            None => {
                let named: Vec<&Worktree> = worktrees.iter().filter(|w| compose_name(&w.name) == project && compose_name(&w.repo_name) != project).collect();
                (named.len() == 1).then(|| (named[0].path.clone(), false))
            }
        }
    };
    let why = |project: &str, certain: bool| if certain { format!("Made by compose project {project}, which only runs here.") } else { format!("Made by a compose project named {project}, like this folder.") };
    for volume in docker.volumes.iter().filter(|v| !v.project.is_empty()) {
        if let Some((group, certain)) = home_of(&volume.project).filter(|(group, _)| only(group, &|c| c.volumes.iter().any(|(v, _)| v == &volume.name))) {
            add(&group, "volume", &volume.name, volume_name(&volume.name), why(&volume.project, certain), volume.size, certain, false);
        }
    }
    for image in docker.images.iter().filter(|i| !i.project.is_empty()) {
        if let Some((group, certain)) = home_of(&image.project).filter(|(group, _)| only(group, &|c| c.image_id == image.id)) {
            add(&group, "image", &image.id, image_name(image), why(&image.project, certain), image.size, certain, false);
        }
    }
    (out, deleted)
}

pub fn is_docker(id: &str) -> bool {
    id.starts_with("docker:")
}

/// Removes one container (stopping it), volume or image by the id `assign` gave it.
pub fn remove_docker(id: &str) -> Result<(), String> {
    let mut parts = id.splitn(4, ':').skip(1);
    let (kind, reference) = (parts.next().unwrap_or(""), parts.next().unwrap_or(""));
    if reference.is_empty() || reference.starts_with('-') {
        return Err("Not a Docker item.".into());
    }
    let docker = tool("docker").ok_or("Docker isn't installed.")?;
    let attempt = |args: &[&str]| match run(&docker, args, DOCKER_SIZES_WAIT) {
        Some(out) if out.ok => Ok(()),
        Some(out) => Err(out.error.trim_start_matches("Error response from daemon: ").to_string()),
        None => Err("Docker couldn't be started.".to_string()),
    };
    match kind {
        "container" => attempt(&["rm", "--force", reference]),
        "volume" => attempt(&["volume", "rm", reference]),
        "image" => attempt(&["image", "rm", reference]).or_else(|e| {
            // An image with several names goes only when forced; one still in use doesn't either way.
            if e.contains("must be forced") && e.contains("multiple repositories") { attempt(&["image", "rm", "--force", reference]) } else { Err(e) }
        }),
        _ => Err("Not a Docker item.".into()),
    }
}

// MARK: Inspecting

#[derive(Serialize, Clone)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Event {
    Git { path: String, status: Option<GitStatus> },
    /// `engine`: "ready", "stopped", "remote" or "missing".
    Docker { engine: &'static str, resources: Vec<Resource>, deleted: Vec<Worktree> },
    Done,
}

/// Asks git where each worktree stands and Docker what belongs to it, reporting as answers come.
pub fn inspect(worktrees: &[Worktree], roots: &[String], send: &(dyn Fn(Event) + Sync)) {
    let git = tool("git");
    let next = AtomicUsize::new(0);
    std::thread::scope(|scope| {
        scope.spawn(|| {
            let (engine, loaded) = match tool("docker") {
                None => ("missing", None),
                Some(docker) if !local_engine(&docker) => ("remote", None),
                Some(docker) => match load_docker(&docker) {
                    Some(loaded) => ("ready", Some(loaded)),
                    None => ("stopped", None),
                },
            };
            let (resources, deleted) = loaded.map(|d| assign(worktrees, &d, roots)).unwrap_or_default();
            send(Event::Docker { engine, resources, deleted });
        });
        for _ in 0..4 {
            scope.spawn(|| {
                while let Some(worktree) = worktrees.get(next.fetch_add(1, Ordering::Relaxed)) {
                    let status = git.as_deref().and_then(|git| git_status(git, worktree));
                    send(Event::Git { path: worktree.path.clone(), status });
                }
            });
        }
    });
    send(Event::Done);
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::clean::scan::{ScanRoot, Scanner};
    use std::sync::atomic::AtomicBool;

    fn worktree(path: &str, repo_name: &str) -> Worktree {
        Worktree { path: path.into(), name: fsx::name(path), repo: String::new(), repo_name: repo_name.into(), branch: None, lost: false, deleted: false, size: 0, modified: 0 }
    }

    fn container(id: &str, project: &str, folder: &str, image: &str, volumes: &[&str]) -> Container {
        Container { id: id.into(), name: format!("{id}-1"), image_id: image.into(), image_name: image.into(), state: "exited".into(), project: project.into(), folder: folder.into(), volumes: volumes.iter().map(|v| (v.to_string(), "/data".to_string())).collect(), ..Default::default() }
    }

    fn scan(dir: &std::path::Path) -> ScanResult {
        let cancel = AtomicBool::new(false);
        let mut progress = |_: u64, _: &str| {};
        Scanner::new(&cancel, &mut progress).run(&[ScanRoot { path: dir.to_string_lossy().into_owned(), title: "T".into() }]).unwrap()
    }

    #[test]
    fn sizes() {
        assert_eq!(parse_size("432.1MB"), 432_100_000);
        assert_eq!(parse_size("193kB (virtual 311MB)"), 193_000);
        assert_eq!(parse_size("0B"), 0);
        assert_eq!(parse_size("N/A"), 0);
    }

    #[test]
    fn compose_names() {
        assert_eq!(compose_name("My App.v2"), "myappv2");
        assert_eq!(compose_name("_qa-1083"), "qa-1083");
    }

    #[test]
    fn picks_the_main_branch() {
        let listing = "refs/heads/main \nrefs/remotes/origin/HEAD refs/remotes/origin/develop\nrefs/remotes/origin/develop \nrefs/remotes/origin/main \n";
        assert_eq!(main_branch(listing), (Some("refs/remotes/origin/develop".into()), true));
        assert_eq!(main_branch("refs/heads/master \n"), (Some("refs/heads/master".into()), false));
        assert_eq!(main_branch("refs/remotes/up/feature \n"), (None, true));
        assert_eq!(short_branch("refs/remotes/origin/release/2"), "release/2");
        assert_eq!(short_branch("refs/heads/main"), "main");
    }

    #[test]
    fn reads_docker_output() {
        let inspect = r#"[{"Id":"c1","Name":"/app-db-1","Image":"sha256:aa","Config":{"Image":"postgres:18","Labels":{"com.docker.compose.project":"app","com.docker.compose.project.working_dir":"/w/one"}},"State":{"Status":"running","Running":true},"Mounts":[{"Type":"volume","Name":"v1","Destination":"/var/lib/postgresql"},{"Type":"bind","Source":"/host_mnt/w/one/src","Destination":"/src"}]}]"#;
        let mut docker = Docker { containers: parse_containers(inspect), ..Default::default() };
        let c = &docker.containers[0];
        assert_eq!((c.name.as_str(), c.image_id.as_str(), c.project.as_str(), c.folder.as_str(), c.running), ("app-db-1", "aa", "app", "/w/one", true));
        assert_eq!(c.binds, ["/w/one/src"]);
        assert_eq!(c.volumes, [("v1".to_string(), "/var/lib/postgresql".to_string())]);
        let usage = r#"{"Images":[{"ID":"sha256:aa","Repository":"postgres","Tag":"18","Size":"432MB","UniqueSize":"400MB"},{"ID":"sha256:aa","Repository":"pg","Tag":"latest","Size":"432MB","UniqueSize":"400MB"}],"Containers":[{"ID":"c1","Size":"193kB"}],"Volumes":[{"Name":"v1","Labels":"com.docker.compose.project=app,com.docker.compose.volume=data","Size":"313.7MB"}]}"#;
        apply_usage(&mut docker, usage);
        assert_eq!(docker.containers[0].size, 193_000);
        assert_eq!(docker.images.len(), 1);
        assert_eq!((docker.images[0].name.as_str(), docker.images[0].size), ("postgres:18", 400_000_000));
        assert_eq!((docker.volumes[0].project.as_str(), docker.volumes[0].size), ("app", 313_700_000));
    }

    #[test]
    fn docker_items_go_to_the_worktree_that_alone_uses_them() {
        let s = fsx::SEP;
        let (one, two) = (format!("{s}w{s}one"), format!("{s}w{s}two"));
        let worktrees = [worktree(&one, "repo"), worktree(&two, "repo")];
        let docker = Docker {
            containers: vec![
                container("a", "repo", &one, "shared", &["only-one", "both"]),
                container("b", "repo", &two, "shared", &["both"]),
                container("c", "repo", &two, "mine", &["both"]),
                container("d", "repo", &format!("{s}w{s}main"), "main-image", &["main-data"]),
                container("e", "solo", &fsx::join(&two, "infra"), "solo-image", &[]),
            ],
            images: vec![Image { id: "mine".into(), name: "api:dev".into(), project: String::new(), size: 5 }, Image { id: "built".into(), name: "solo-web".into(), project: "solo".into(), size: 7 }, Image { id: "old".into(), name: "one-web".into(), project: "one".into(), size: 9 }],
            volumes: vec![Volume { name: "only-one".into(), project: "repo".into(), size: 3 }, Volume { name: "solo_cache".into(), project: "solo".into(), size: 4 }, Volume { name: "one_db".into(), project: "one".into(), size: 8 }],
        };
        let (resources, deleted) = assign(&worktrees, &docker, &[]);
        assert!(deleted.is_empty());
        let of = |path: &str| -> Vec<String> { resources.iter().filter(|r| r.worktree == path).map(|r| format!("{}:{}{}", r.kind, r.name, if r.certain { "" } else { "?" })).collect() };
        // "shared" and "both" are used by the other worktree too; project "one" has no containers left.
        assert_eq!(of(&one), ["container:a-1", "volume:only-one", "volume:one_db?", "image:one-web?"]);
        assert_eq!(of(&two), ["container:b-1", "container:c-1", "image:api:dev", "container:e-1", "image:solo-image", "volume:solo_cache", "image:solo-web"]);
        assert_eq!(resources.iter().find(|r| r.name == "only-one").map(|r| (r.id.as_str(), r.size)), Some(("docker:volume:only-one:only-one", 3)));
    }

    #[test]
    fn containers_of_a_deleted_folder_are_grouped() {
        let dir = std::env::temp_dir().join(format!("cs-gone-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let root = dir.to_string_lossy().into_owned();
        let gone = fsx::join(&root, "old-feature");
        let docker = Docker { containers: vec![container("a", "old", &gone, "img", &["data"]), container("b", "kept", &root, "img2", &[])], ..Default::default() };
        let (resources, deleted) = assign(&[], &docker, &[root.clone()]);
        assert_eq!(deleted.iter().map(|w| (w.name.as_str(), w.deleted)).collect::<Vec<_>>(), [("old-feature", true)]);
        assert_eq!(resources.iter().map(|r| r.kind).collect::<Vec<_>>(), ["container", "volume", "image"]);
        assert!(resources.iter().all(|r| r.worktree == gone));
        // Outside the scanned folders nothing is assumed.
        assert!(assign(&[], &docker, &[]).1.is_empty());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn finds_linked_worktrees_and_forgets_deleted_ones() {
        let dir = std::env::temp_dir().join(format!("cs-wt-{}", std::process::id()));
        let admin = dir.join("repo/.git/worktrees/feature");
        let hidden = dir.join(".claude/worktrees/feature");
        std::fs::create_dir_all(&admin).unwrap();
        std::fs::create_dir_all(&hidden).unwrap();
        std::fs::create_dir_all(dir.join("repo/lib")).unwrap();
        std::fs::write(admin.join("HEAD"), "ref: refs/heads/feat/login\n").unwrap();
        std::fs::write(admin.join("gitdir"), format!("{}\n", hidden.join(".git").display())).unwrap();
        std::fs::write(hidden.join(".git"), format!("gitdir: {}\n", admin.display())).unwrap();
        std::fs::write(hidden.join("code.txt"), "x").unwrap();
        // A submodule's .git file isn't a worktree.
        std::fs::write(dir.join("repo/lib/.git"), "gitdir: ../.git/modules/lib\n").unwrap();

        let found = find(&scan(&dir));
        assert_eq!(found.len(), 1);
        let w = &found[0];
        assert_eq!((w.name.as_str(), w.repo_name.as_str(), w.branch.as_deref(), w.lost), ("feature", "repo", Some("feat/login"), false));
        assert!(w.modified > 0);

        let path = hidden.to_string_lossy().into_owned();
        let link = link(&path).unwrap();
        forget(&link, &path); // still there: kept
        assert!(admin.exists());
        std::fs::remove_dir_all(&hidden).unwrap();
        forget(&link, &path);
        assert!(!admin.exists());
        assert!(dir.join("repo/.git").exists());
        std::fs::remove_dir_all(dir).unwrap();
    }

    /// Against real git, when it's installed.
    #[test]
    fn reads_where_a_branch_stands() {
        let Some(git) = tool("git") else { return };
        let dir = std::env::temp_dir().join(format!("cs-git-{}", std::process::id()));
        let repo = dir.join("repo");
        std::fs::create_dir_all(&repo).unwrap();
        let (repo_path, tree_path) = (repo.to_string_lossy().into_owned(), dir.join("tree").to_string_lossy().into_owned());
        let git_in = |folder: &str, args: &[&str]| {
            let out = run(&git, &[&["-C", folder, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"][..], args].concat(), GIT_WAIT).unwrap();
            assert!(out.ok, "git {args:?}: {}", out.error);
        };
        git_in(&repo_path, &["init", "--quiet", "--initial-branch=main"]);
        std::fs::write(repo.join("a.txt"), "a").unwrap();
        git_in(&repo_path, &["add", "."]);
        git_in(&repo_path, &["commit", "--quiet", "-m", "first"]);
        git_in(&repo_path, &["worktree", "add", "--quiet", "-b", "feature", &tree_path]);

        let found = find(&scan(&dir));
        assert_eq!(found.iter().map(|w| (w.name.as_str(), w.repo_name.as_str(), w.branch.as_deref())).collect::<Vec<_>>(), [("tree", "repo", Some("feature"))]);
        let merged = git_status(&git, &found[0]).unwrap();
        assert_eq!(merged, GitStatus { dirty: 0, ahead: Some(0), unpushed: 0, upstream_gone: false, base: Some("main".into()) });

        std::fs::write(dir.join("tree/b.txt"), "b").unwrap();
        assert_eq!(git_status(&git, &found[0]).unwrap().dirty, 1);
        git_in(&tree_path, &["add", "."]);
        git_in(&tree_path, &["commit", "--quiet", "-m", "second"]);
        let ahead = git_status(&git, &found[0]).unwrap();
        assert_eq!((ahead.dirty, ahead.ahead), (0, Some(1)));
        let _ = crate::clean::remove::delete(&dir.to_string_lossy());
    }
}
