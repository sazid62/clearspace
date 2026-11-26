import { Channel, convertFileSrc, invoke } from "@tauri-apps/api/core";
import { home, os } from "../platform";

// ---------- Types shared with src-tauri/src/clean ----------

export interface FsNode {
  path: string;
  name: string;
  dir: boolean;
  size: number;
  /** Total of the children under 20 MB, shown as one "small items" row. */
  small: number;
  children: FsNode[];
}

export interface LargeFile {
  path: string;
  size: number;
  /** Seconds since 1970. */
  modified: number;
}

export type Safety = "safe" | "review";

export interface Suggestion {
  path: string;
  title: string;
  note: string;
  safety: Safety;
  size: number;
}

/** A linked git worktree found by the scan, or a deleted folder Docker still holds things for. */
export interface Worktree {
  path: string;
  name: string;
  /** The repository's main checkout ("" when unknown). */
  repo: string;
  repoName: string;
  /** null on a detached HEAD. */
  branch: string | null;
  /** Its repository is gone or no longer lists this checkout. */
  lost: boolean;
  /** The folder is gone; only what Docker kept for it is left. */
  deleted: boolean;
  size: number;
  /** Seconds since 1970; 0 when unknown. */
  modified: number;
}

export interface GitStatus {
  /** Files changed or added and never committed. */
  dirty: number;
  /** Commits that aren't in the main branch; null when there's none to compare with. */
  ahead: number | null;
  /** Commits that aren't on any remote. */
  unpushed: number;
  upstreamGone: boolean;
  /** The main branch compared with. */
  base: string | null;
}

/** A Docker container, volume or image that belongs to one worktree. `id` starts with "docker:". */
export interface DockerItem {
  id: string;
  worktree: string;
  kind: "container" | "volume" | "image";
  name: string;
  detail: string;
  size: number;
  /** False when matched only by the compose project's name. */
  certain: boolean;
  running: boolean;
}

export type DockerEngine = "ready" | "stopped" | "remote" | "missing";

export type WorktreeEvent =
  | { kind: "git"; path: string; status: GitStatus | null }
  | { kind: "docker"; engine: DockerEngine; resources: DockerItem[]; deleted: Worktree[] }
  | { kind: "done" };

export type ScanEvent =
  | { kind: "progress"; files: number; folder: string }
  | { kind: "done"; root: FsNode; largeFiles: LargeFile[]; suggestions: Suggestion[]; worktrees: Worktree[]; files: number; millis: number; emptied: string[] }
  | { kind: "cancelled" };

export interface Storage {
  name: string;
  total: number;
  available: number;
  fullDiskAccess: boolean | null;
}

export type Mode = "trash" | "permanent";

export type RemoveEvent =
  | { kind: "start"; path: string }
  | { kind: "outcome"; path: string; size: number; error: string | null; needsAdmin: boolean }
  | { kind: "finished" };

export type AdminResult = { kind: "completed" } | { kind: "cancelled" } | { kind: "failed"; message: string };

export interface App {
  id: string;
  name: string;
  version: string | null;
  detail: string | null;
  location: string | null;
  icon: string | null;
  /** Label for the app's own uninstaller (Windows programs, Linux packages). */
  uninstaller: string | null;
  size: number | null;
}

export type Confidence = "exact" | "nameOnly";

export interface Leftover {
  path: string;
  kind: string;
  confidence: Confidence;
}

export interface Inspection {
  leftovers: Leftover[];
  mentions: string[];
}

export type InspectEvent = { kind: "found"; inspection: Inspection } | { kind: "size"; path: string; size: number } | { kind: "done" };

// ---------- Calls ----------

export const api = {
  storage: () => invoke<Storage>("clean_storage"),
  scan: (onEvent: (e: ScanEvent) => void) => {
    const events = new Channel<ScanEvent>();
    events.onmessage = onEvent;
    return invoke("clean_scan", { events });
  },
  cancelScan: () => invoke("clean_scan_cancel"),
  remove: (items: { path: string; size: number }[], mode: Mode, checks: "cleaner" | "uninstaller", onEvent: (e: RemoveEvent) => void) => {
    const events = new Channel<RemoveEvent>();
    events.onmessage = onEvent;
    return invoke("clean_remove", { items, mode, checks, events });
  },
  removeAsAdmin: (paths: string[], mode: Mode) => invoke<AdminResult>("clean_remove_admin", { paths, mode }),
  exists: (paths: string[]) => invoke<boolean[]>("clean_exists", { paths }),
  worktrees: (worktrees: Worktree[], onEvent: (e: WorktreeEvent) => void) => {
    const events = new Channel<WorktreeEvent>();
    events.onmessage = onEvent;
    return invoke("clean_worktrees", { worktrees, events });
  },
  openSettings: (pane: "fullDiskAccess" | "appManagement") => invoke("clean_open_settings", { pane }),
  apps: () => invoke<App[]>("apps_list"),
  measureApps: (onSizes: (sizes: { id: string; size: number }[]) => void) => {
    const events = new Channel<{ id: string; size: number }[]>();
    events.onmessage = onSizes;
    return invoke("apps_measure", { events });
  },
  inspect: (id: string, onEvent: (e: InspectEvent) => void) => {
    const events = new Channel<InspectEvent>();
    events.onmessage = onEvent;
    return invoke("apps_inspect", { id, events });
  },
  openApp: (path: string) => invoke<App>("apps_open", { path }),
  isRunning: (id: string) => invoke<boolean>("apps_running", { id }),
  quit: (id: string) => invoke("apps_quit", { id }),
  runUninstaller: (id: string) => invoke("apps_uninstall", { id }),
};

// ---------- Formatting ----------

/** Sizes the way the system's own file manager shows them (Explorer counts in 1024s). */
export function bytes(n: number): string {
  const base = os === "windows" ? 1024 : 1000;
  const units = ["bytes", "KB", "MB", "GB", "TB"];
  if (n < base) return n === 0 ? "Zero KB" : `${n} bytes`;
  let value = n;
  let unit = 0;
  while (value >= base && unit < units.length - 1) {
    value /= base;
    unit++;
  }
  const digits = value < 10 ? 2 : value < 100 ? 1 : 0;
  return `${Number(value.toFixed(digits)).toLocaleString(undefined, { maximumFractionDigits: digits })} ${units[unit]}`;
}

export const plural = (n: number, noun: string) => `${n.toLocaleString()} ${noun}${n === 1 ? "" : "s"}`;

export const sep = () => (os === "windows" ? "\\" : "/");

/** Comparison key: Windows paths ignore case. */
const key = (p: string) => (os === "windows" ? p.toLowerCase() : p);

/** True when `path` is inside `folder` (not the folder itself). */
export const isInside = (path: string, folder: string) => key(path).startsWith(key(folder.replace(/[\\/]$/, "")) + sep());

export const within = (path: string, folder: string) => key(path) === key(folder) || isInside(path, folder);

export function parentOf(path: string) {
  const i = path.lastIndexOf(sep());
  return i <= 0 ? path : path.slice(0, i);
}

export const nameOf = (path: string) => path.slice(path.lastIndexOf(sep()) + 1) || path;

/** Docker items travel through selection and removal as "docker:<kind>:<reference>:<name>". */
export const isDocker = (path: string) => path.startsWith("docker:");

/** "~/Library/Caches" for paths in the home folder; "Docker image api:dev" for Docker items. */
export function abbreviate(path: string) {
  if (isDocker(path)) {
    const [, kind, , ...name] = path.split(":");
    return `Docker ${kind} ${name.join(":")}`;
  }
  if (!home) return path;
  const h = home.replace(/[\\/]$/, "");
  if (key(path) === key(h)) return "~";
  if (isInside(path, h)) return "~" + path.slice(h.length);
  return path;
}

export function relative(seconds: number) {
  const diff = (seconds * 1000 - Date.now()) / 1000;
  const rtf = new Intl.RelativeTimeFormat(undefined, { numeric: "auto" });
  const steps: [number, Intl.RelativeTimeFormatUnit][] = [
    [60, "second"],
    [3600, "minute"],
    [86400, "hour"],
    [604800, "day"],
    [2629800, "week"],
    [31557600, "month"],
  ];
  const abs = Math.abs(diff);
  let divisor = 1;
  for (const [limit, unit] of steps) {
    if (abs < limit) return rtf.format(Math.round(diff / divisor), unit);
    divisor = limit;
  }
  return rtf.format(Math.round(diff / 31557600), "year");
}

/** What the system calls its Trash and file manager. */
export const words = () => ({
  trash: os === "windows" ? "Recycle Bin" : "Trash",
  moveToTrash: os === "windows" ? "Move to Recycle Bin" : "Move to Trash",
  reveal: os === "macos" ? "Show in Finder" : os === "windows" ? "Show in File Explorer" : "Show in Files",
  computer: os === "macos" ? "Mac" : "computer",
});

/** The system's icon for a file, folder or app (served by the icon:// handler in Rust). */
export const iconUrl = (path: string, points: number) => `${convertFileSrc(path, "icon")}?s=${points}`;
