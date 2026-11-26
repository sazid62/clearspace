import { api, isDocker, isInside, within, type DockerEngine, type DockerItem, type FsNode, type GitStatus, type LargeFile, type Mode, type Suggestion, type Worktree } from "./api";
import { retryAsAdmin, runRemoval, Store, type Removal, type RemovalHost } from "./removal";

export type CleanerTab = "suggestions" | "folders" | "files" | "worktrees";

/** A worktree with what git and Docker said about it. `git` is undefined until git answers, null when it can't. */
export interface WorktreeGroup extends Worktree {
  git?: GitStatus | null;
  resources: DockerItem[];
}

const KINDS = ["container", "volume", "image"];

/** Everything removable in a worktree: its folder, then containers, volumes and images. */
export function worktreeParts(w: WorktreeGroup): { id: string; size: number; certain: boolean }[] {
  const docker = [...w.resources].sort((a, b) => KINDS.indexOf(a.kind) - KINDS.indexOf(b.kind) || b.size - a.size);
  return [...(w.deleted ? [] : [{ id: w.path, size: w.size, certain: true }]), ...docker];
}

export const worktreeSize = (w: WorktreeGroup) => worktreeParts(w).reduce((n, p) => n + p.size, 0);

/** Nothing here that isn't in the main branch already, and nothing running. */
export const isMerged = (w: WorktreeGroup) => !!w.git && w.git.ahead === 0 && w.git.dirty === 0 && !w.resources.some((r) => r.running);

/** Containers stop before their volumes and images can go; folders come last. */
const removalOrder = (path: string) => (isDocker(path) ? KINDS.findIndex((k) => path.startsWith(`docker:${k}:`)) : KINDS.length);

export const MINIMUM = 20 * 1024 * 1024;

export type TreeRow =
  | { kind: "item"; id: string; node: FsNode; depth: number; fraction: number }
  | { kind: "small"; id: string; size: number; depth: number; fraction: number };

interface State {
  phase: "idle" | "scanning" | "ready";
  tab: CleanerTab;
  query: string;
  scannedFiles: number;
  scanningPath: string;
  summary?: { files: number; millis: number; total: number };
  suggestions: Suggestion[];
  largeFiles: LargeFile[];
  worktrees: WorktreeGroup[];
  /** Git and Docker are still being asked about the worktrees. */
  worktreesPending: boolean;
  docker?: DockerEngine;
  rows: TreeRow[];
  expanded: Set<string>;
  /** Selected path → size. A selected folder covers everything inside it. */
  selection: Map<string, number>;
  removal?: Removal;
  /** Bumped when the tree changes, so derived lists refresh. */
  revision: number;
}

/** Disk Cleaner: scan, three views of the result, selection, and removal. */
export class CleanerModel extends Store<State> implements RemovalHost {
  private root?: FsNode;
  private parents = new Map<FsNode, FsNode>();
  private byPath = new Map<string, FsNode>();
  private scanToken = 0;
  /** Folders that are emptied rather than removed (the Trash). */
  private emptied: string[] = [];
  /** Called after files are removed (the storage numbers change). */
  onFilesRemoved?: () => void;

  constructor() {
    super({
      phase: "idle",
      tab: "suggestions",
      query: "",
      scannedFiles: 0,
      scanningPath: "",
      suggestions: [],
      largeFiles: [],
      worktrees: [],
      worktreesPending: false,
      rows: [],
      expanded: new Set(),
      selection: new Map(),
      revision: 0,
    });
  }

  get busy() {
    return this.state.phase === "scanning" || !!this.state.removal;
  }

  // ---------- Scanning ----------

  startScan() {
    if (this.busy) return;
    const token = ++this.scanToken;
    this.set({ phase: "scanning", scannedFiles: 0, scanningPath: "" });
    void api
      .scan((e) => {
        if (token !== this.scanToken) return;
        if (e.kind === "progress") this.set({ scannedFiles: e.files, scanningPath: e.folder });
        else if (e.kind === "done") {
          this.load(e.root);
          this.emptied = e.emptied;
          this.set({
            phase: "ready",
            suggestions: e.suggestions,
            largeFiles: e.largeFiles,
            worktrees: e.worktrees.map((w) => ({ ...w, resources: [] })),
            worktreesPending: true,
            docker: undefined,
            summary: { files: e.files, millis: e.millis, total: e.root.size },
            selection: new Map(),
            expanded: new Set(),
          });
          this.rebuildRows();
          this.inspectWorktrees(token, e.worktrees);
        } else {
          this.set({ phase: this.root ? "ready" : "idle" });
        }
      })
      .catch(() => this.set({ phase: this.root ? "ready" : "idle" }));
  }

  /** Fills in each worktree's git status and Docker items as they're found. */
  private inspectWorktrees(token: number, worktrees: Worktree[]) {
    void api
      .worktrees(worktrees, (e) => {
        if (token !== this.scanToken) return;
        if (e.kind === "git") this.set({ worktrees: this.state.worktrees.map((w) => (w.path === e.path ? { ...w, git: e.status } : w)) });
        else if (e.kind === "docker") {
          const all = [...this.state.worktrees, ...e.deleted.map((w) => ({ ...w, resources: [] }))];
          this.set({ docker: e.engine, worktrees: all.map((w) => ({ ...w, resources: e.resources.filter((r) => r.worktree === w.path) })) });
        } else this.set({ worktreesPending: false });
      })
      .catch(() => token === this.scanToken && this.set({ worktreesPending: false }));
  }

  cancelScan() {
    void api.cancelScan();
  }

  private load(root: FsNode) {
    this.root = root;
    this.parents.clear();
    this.byPath.clear();
    const walk = (node: FsNode) => {
      for (const child of node.children) {
        this.parents.set(child, node);
        this.byPath.set(child.path, child);
        walk(child);
      }
    };
    walk(root);
  }

  // ---------- Views ----------

  setTab = (tab: CleanerTab) => this.set({ tab });
  setQuery = (query: string) => this.set({ query });

  private rebuildRows() {
    const rows: TreeRow[] = [];
    const share = (size: number, total: number) => (total > 0 ? size / total : 0);
    const walk = (node: FsNode, depth: number) => {
      for (const child of node.children) {
        rows.push({ kind: "item", id: child.path, node: child, depth, fraction: share(child.size, node.size) });
        if (child.dir && this.state.expanded.has(child.path)) walk(child, depth + 1);
      }
      if (depth > 0 && node.small > 0) rows.push({ kind: "small", id: node.path + "#small", size: node.small, depth, fraction: share(node.small, node.size) });
    };
    if (this.root) walk(this.root, 0);
    this.set({ rows, revision: this.state.revision + 1 });
  }

  toggleExpanded(path: string) {
    const expanded = new Set(this.state.expanded);
    if (expanded.has(path)) expanded.delete(path);
    else expanded.add(path);
    this.set({ expanded });
    this.rebuildRows();
  }

  /** Folder-view search: every item over 20 MB whose name matches, biggest first. */
  folderMatches(query: string): FsNode[] {
    const q = query.toLowerCase();
    return [...this.byPath.values()]
      .filter((n) => n.name.toLowerCase().includes(q))
      .sort((a, b) => b.size - a.size)
      .slice(0, 500);
  }

  // ---------- Selection ----------

  isCovered(path: string) {
    for (const key of this.state.selection.keys()) if (isInside(path, key)) return true;
    return false;
  }

  setSelected(path: string, size: number, on: boolean) {
    const selection = new Map(this.state.selection);
    if (on) {
      for (const key of [...selection.keys()]) if (isInside(key, path)) selection.delete(key);
      selection.set(path, size);
    } else {
      selection.delete(path);
    }
    this.set({ selection });
  }

  clearSelection = () => this.set({ selection: new Map() });

  // ---------- Worktrees ----------

  /** Worktrees matching the search, the ones taking the most space first. */
  worktreeList(query: string): WorktreeGroup[] {
    const q = query.toLowerCase();
    const matches = (w: WorktreeGroup) => [w.name, w.path, w.repoName, w.branch ?? "", ...w.resources.map((r) => r.name)].some((t) => t.toLowerCase().includes(q));
    return this.state.worktrees.filter((w) => !q || matches(w)).sort((a, b) => worktreeSize(b) - worktreeSize(a));
  }

  private isPicked(id: string) {
    return this.state.selection.has(id) || this.isCovered(id);
  }

  /** How much of a worktree is ticked. Name-only Docker matches don't count toward "all". */
  worktreeSelection(w: WorktreeGroup): "all" | "some" | "none" {
    const parts = worktreeParts(w);
    const sure = parts.filter((p) => p.certain);
    if (sure.length > 0 && sure.every((p) => this.isPicked(p.id))) return "all";
    return parts.some((p) => this.isPicked(p.id)) ? "some" : "none";
  }

  /** Ticks a worktree's folder and the Docker items that are surely its own, or unticks everything. */
  setWorktreeSelected(w: WorktreeGroup, on: boolean) {
    const selection = new Map(this.state.selection);
    for (const part of worktreeParts(w)) {
      if (!on) selection.delete(part.id);
      else if (part.certain && !this.isCovered(part.id)) {
        for (const key of [...selection.keys()]) if (isInside(key, part.id)) selection.delete(key);
        selection.set(part.id, part.size);
      }
    }
    this.set({ selection });
  }

  mergedSize() {
    return this.state.worktrees.filter(isMerged).reduce((n, w) => n + worktreeSize(w), 0);
  }

  selectMerged() {
    for (const w of this.state.worktrees) if (isMerged(w)) this.setWorktreeSelected(w, true);
  }

  /** Selected worktree folders that hold changes never committed. */
  uncommittedSelected(): string[] {
    return this.state.worktrees.filter((w) => !w.deleted && (w.git?.dirty ?? 0) > 0 && this.isPicked(w.path)).map((w) => w.name);
  }

  safeSize() {
    return this.state.suggestions.filter((s) => s.safety === "safe").reduce((n, s) => n + s.size, 0);
  }

  selectAllSafe() {
    for (const s of this.state.suggestions) if (s.safety === "safe" && !this.isCovered(s.path)) this.setSelected(s.path, s.size, true);
  }

  /** The selection without items already inside another selected folder, biggest first. */
  selectionSummary() {
    const sel = this.state.selection;
    const kept: string[] = [];
    for (const path of [...sel.keys()].sort((a, b) => a.length - b.length)) if (!kept.some((k) => isInside(path, k))) kept.push(path);
    kept.sort((a, b) => (sel.get(b) ?? 0) - (sel.get(a) ?? 0));
    return { paths: kept, size: kept.reduce((n, p) => n + (sel.get(p) ?? 0), 0) };
  }

  // ---------- Removal ----------

  remove(mode: Mode) {
    if (this.state.removal) return;
    const { paths } = this.selectionSummary();
    if (!paths.length) return;
    const items = paths.map((path) => ({ path, size: this.byPath.get(path)?.size ?? this.state.selection.get(path) ?? 0 })).sort((a, b) => removalOrder(a.path) - removalOrder(b.path));
    runRemoval(
      items,
      mode,
      "cleaner",
      (removal) => this.set({ removal }),
      (path) => this.drop(path),
      () => this.onFilesRemoved?.(),
    );
  }

  retryAsAdmin() {
    const removal = this.state.removal;
    if (!removal) return;
    void retryAsAdmin(removal, (r) => this.set({ removal: r }), (path) => this.drop(path)).then(() => this.onFilesRemoved?.());
  }

  finishRemoval() {
    const removal = this.state.removal;
    if (!removal || removal.running || removal.elevating) return;
    this.set({ removal: undefined });
  }

  /** Takes a removed path out of the tree and every list, and subtracts its size from every folder above it. */
  private drop(path: string) {
    const node = this.byPath.get(path);
    const emptied = this.emptied.some((e) => within(path, e) && within(e, path));
    if (node) {
      const freed = node.size;
      const forget = (n: FsNode) => {
        this.byPath.delete(n.path);
        n.children.forEach(forget);
      };
      if (emptied) {
        // The Trash is emptied, not removed.
        node.children.forEach(forget);
        node.children = [];
        node.small = 0;
        node.size = 0;
      } else {
        const parent = this.parents.get(node);
        if (parent) parent.children = parent.children.filter((c) => c !== node);
        forget(node);
      }
      let up = this.parents.get(node);
      while (up) {
        up.size = Math.max(0, up.size - freed);
        up.children.sort((a, b) => b.size - a.size);
        up = this.parents.get(up);
      }
    }
    const selection = new Map([...this.state.selection].filter(([k]) => !within(k, path)));
    this.set({
      selection,
      suggestions: this.state.suggestions.filter((s) => !within(s.path, path)),
      largeFiles: this.state.largeFiles.filter((f) => !within(f.path, path)),
      // A worktree whose folder went stays listed while Docker still holds something for it.
      worktrees: this.state.worktrees
        .map((w) => ({ ...w, resources: w.resources.filter((r) => r.id !== path), ...(!w.deleted && !isDocker(path) && within(w.path, path) ? { deleted: true, size: 0, git: null } : {}) }))
        .filter((w) => !w.deleted || w.resources.length > 0),
      summary: this.state.summary && this.root ? { ...this.state.summary, total: this.root.size } : this.state.summary,
    });
    this.rebuildRows();
  }
}
