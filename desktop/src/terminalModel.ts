import { invoke } from "@tauri-apps/api/core";
import { open } from "@tauri-apps/plugin-dialog";
import { prefersDark, Session } from "./session";
import { home } from "./platform";
import {
  emptyWorkspace,
  folderName,
  newId,
  parseWorkspace,
  reorderSection,
  sectionOf,
  serializeWorkspace,
  sidebarOrder,
  type SectionKey,
  type TabColor,
  type TerminalGroup,
  type TerminalTab,
  type Workspace,
} from "./workspace";

/** A pending dialog in the Terminal space. */
export type TerminalEdit =
  | { kind: "renameTab"; id: string }
  | { kind: "startupCommand"; id: string }
  | { kind: "newGroup"; movingTab?: string }
  | { kind: "renameGroup"; id: string };

export interface TerminalState {
  workspace: Workspace;
  /** Tabs whose shell has exited, with the exit code. */
  exited: Record<string, number | null>;
  editing?: TerminalEdit;
  /** Bumped whenever a shell's view is created or removed, so the deck re-picks what to show. */
  sessionsVersion: number;
}

/**
 * The Terminal space: groups and tabs (saved to disk on every change) plus one live shell per tab.
 * A tiny external store so React reads it with useSyncExternalStore.
 */
export class TerminalModel {
  private state: TerminalState = { workspace: emptyWorkspace(), exited: {}, sessionsVersion: 0 };
  private listeners = new Set<() => void>();
  private sessions = new Map<string, Session>();
  private savedScrollback = new Map<string, string>();
  private restoredAt?: number;
  private deck?: HTMLElement;
  private active = false;
  private loaded: Promise<void>;
  /** Our shortcuts, so a focused terminal doesn't send them to the shell. */
  isShortcut: (event: KeyboardEvent) => boolean = () => false;

  constructor() {
    this.loaded = invoke<{ json: string; savedAt?: number } | null>("load_workspace").then((saved) => {
      const ws = saved ? parseWorkspace(saved.json) : undefined;
      if (ws) {
        this.restoredAt = saved?.savedAt;
        this.set({ workspace: ws });
      }
    });
    window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", (e) => {
      this.sessions.forEach((s) => s.setDark(e.matches));
    });
  }

  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  };
  getSnapshot = () => this.state;

  private set(change: Partial<TerminalState>) {
    this.state = { ...this.state, ...change };
    this.listeners.forEach((l) => l());
  }

  get workspace() {
    return this.state.workspace;
  }

  // MARK: Lifecycle

  /** Called when the Terminal space first shows: starts every tab's shell (so startup commands run) and begins tracking folders. */
  async activate(deck: HTMLElement) {
    this.deck = deck;
    if (this.active) return;
    this.active = true;
    await this.loaded;
    const ws = this.workspace;
    if (ws.tabs.length === 0) {
      this.newTab();
    } else {
      ws.tabs.forEach((t) => this.session(t.id));
      if (!ws.tabs.some((t) => t.id === ws.selectedTabID)) this.update((w) => ({ ...w, selectedTabID: sidebarOrder(w)[0]?.id }));
    }
    void invoke("prune_scrollback", { keep: ws.tabs.map((t) => t.id) });
    // Logout, restart and Dock › Quit can end the app without asking it first; leaving the window
    // (opening the Apple menu, switching apps) comes before all of them, so save then too.
    const saveOnLeave = () => void this.saveEverything();
    window.addEventListener("blur", saveOnLeave);
    document.addEventListener("visibilitychange", () => document.hidden && saveOnLeave());
    let tick = 0;
    setInterval(() => {
      void this.refreshDirectories();
      if (++tick % 5 === 0) void this.saveScrollback(); // every ~10 s, so a crash or power cut loses little
    }, 2000);
  }

  session(id: string): Session {
    const existing = this.sessions.get(id);
    if (existing) return existing;
    if (!this.deck) throw new Error("terminal deck not ready");
    const session = new Session(id, this.deck);
    session.setDark(prefersDark());
    session.onShortcut = (e) => this.isShortcut(e);
    session.onExit = (code) => this.set({ exited: { ...this.state.exited, [id]: code } });
    this.sessions.set(id, session);
    this.set({ sessionsVersion: this.state.sessionsVersion + 1 });
    const tab = this.tab(id);
    void invoke<string | null>("load_scrollback", { id }).then((text) => {
      if (text) session.showRestored(text, this.restoredAt);
      if (tab) void session.start(tab.directory, tab.startupCommand);
    });
    return session;
  }

  existingSession(id: string) {
    return this.sessions.get(id);
  }

  restart(id: string) {
    const tab = this.tab(id);
    const session = this.sessions.get(id);
    if (!tab || !session) return;
    const { [id]: _, ...exited } = this.state.exited;
    this.set({ exited });
    session.term.write("\r\n");
    void session.start(tab.directory, tab.startupCommand);
  }

  // MARK: Lookup

  tab = (id: string) => this.workspace.tabs.find((t) => t.id === id);
  group = (id: string) => this.workspace.groups.find((g) => g.id === id);

  get selectedTab() {
    const id = this.workspace.selectedTabID;
    return id ? this.tab(id) : undefined;
  }

  select(id: string) {
    this.update((w) => ({ ...w, selectedTabID: id }));
  }

  /** The tab's own name, else its folder. */
  title = (tab: TerminalTab) => tab.name || folderName(tab.directory, home);

  colorOf = (tab: TerminalTab): TabColor | undefined => tab.color ?? (tab.groupID ? this.group(tab.groupID)?.color : undefined);

  /** Where the shell is now: the OS answer (macOS, Linux) or what the shell last reported (Windows). */
  private liveDirectory(id: string) {
    return this.sessions.get(id)?.reportedDirectory;
  }

  // MARK: Tabs

  /** Opens a tab next to the current one: same group, starting in the group's folder or the current tab's folder. */
  newTab(groupID?: string, directory?: string) {
    const current = this.selectedTab;
    const targetGroup = groupID ?? (current && !current.isPinned ? current.groupID : undefined);
    const folder =
      directory ??
      (targetGroup ? this.group(targetGroup)?.directory : undefined) ??
      (current ? this.liveDirectory(current.id) ?? current.directory : undefined) ??
      home;
    const tab: TerminalTab = { id: newId(), groupID: targetGroup, isPinned: false, directory: folder };
    this.update((w) => {
      const tabs = [...w.tabs];
      const index = current ? tabs.findIndex((t) => t.id === current.id) : -1;
      if (current && index >= 0 && sectionOf(w, current) === sectionOf(w, tab)) tabs.splice(index + 1, 0, tab);
      else tabs.push(tab);
      return { ...w, tabs, selectedTabID: tab.id };
    });
    this.session(tab.id);
  }

  duplicate(id: string) {
    const original = this.tab(id);
    if (!original) return;
    const copy: TerminalTab = { ...original, id: newId(), directory: this.liveDirectory(id) ?? original.directory };
    this.update((w) => {
      const tabs = [...w.tabs];
      tabs.splice(tabs.findIndex((t) => t.id === id) + 1, 0, copy);
      return { ...w, tabs, selectedTabID: copy.id };
    });
    this.session(copy.id);
  }

  close(id: string) {
    const order = sidebarOrder(this.workspace).map((t) => t.id);
    this.sessions.get(id)?.dispose();
    this.sessions.delete(id);
    this.set({ sessionsVersion: this.state.sessionsVersion + 1 });
    void invoke("remove_scrollback", { id });
    const { [id]: _, ...exited } = this.state.exited;
    this.set({ exited });
    this.update((w) => {
      let selectedTabID = w.selectedTabID;
      if (selectedTabID === id) {
        const remaining = order.filter((t) => t !== id);
        const position = Math.max(0, order.indexOf(id));
        selectedTabID = remaining[Math.min(position, remaining.length - 1)];
      }
      return { ...w, tabs: w.tabs.filter((t) => t.id !== id), selectedTabID };
    });
  }

  closeSelected() {
    const id = this.workspace.selectedTabID;
    if (id) this.close(id);
  }

  selectAdjacent(step: number) {
    const order = sidebarOrder(this.workspace).map((t) => t.id);
    if (!order.length) return;
    const current = Math.max(0, order.indexOf(this.workspace.selectedTabID ?? ""));
    this.select(order[(current + step + order.length) % order.length]);
  }

  rename(id: string, name: string) {
    this.updateTab(id, (t) => ({ ...t, name: name.trim() || undefined }));
  }

  setTabColor(id: string, color?: TabColor) {
    this.updateTab(id, (t) => ({ ...t, color }));
  }

  togglePin(id: string) {
    this.updateTab(id, (t) => ({ ...t, isPinned: !t.isPinned }));
  }

  setStartupCommand(id: string, command: string) {
    this.updateTab(id, (t) => ({ ...t, startupCommand: command.trim() || undefined }));
  }

  moveToGroup(id: string, groupID?: string) {
    this.updateTab(id, (t) => ({ ...t, groupID, isPinned: false }));
  }

  reorder(section: SectionKey, orderedIds: string[]) {
    this.update((w) => reorderSection(w, section, orderedIds));
  }

  // MARK: Groups

  newGroup(name: string, color: TabColor, movingTab?: string) {
    const group: TerminalGroup = { id: newId(), name: name.trim() || `Group ${this.workspace.groups.length + 1}`, color, isExpanded: true };
    this.update((w) => ({ ...w, groups: [...w.groups, group] }));
    if (movingTab) this.moveToGroup(movingTab, group.id);
    else this.newTab(group.id);
    return group.id;
  }

  renameGroup(id: string, name: string) {
    if (name.trim()) this.updateGroup(id, (g) => ({ ...g, name: name.trim() }));
  }

  setGroupColor(id: string, color: TabColor) {
    this.updateGroup(id, (g) => ({ ...g, color }));
  }

  setGroupExpanded(id: string, isExpanded: boolean) {
    this.updateGroup(id, (g) => ({ ...g, isExpanded }));
  }

  setGroupDirectory(id: string, directory?: string) {
    this.updateGroup(id, (g) => ({ ...g, directory }));
  }

  async chooseGroupDirectory(id: string) {
    const picked = await open({ directory: true, defaultPath: this.group(id)?.directory, title: "New tabs in this group start in this folder" });
    if (typeof picked === "string") this.setGroupDirectory(id, picked);
  }

  /** Removes the group. Its tabs either stay open as loose tabs or close with it. */
  deleteGroup(id: string, closingTabs: boolean) {
    if (closingTabs) this.workspace.tabs.filter((t) => t.groupID === id && !t.isPinned).forEach((t) => this.close(t.id));
    this.update((w) => ({
      ...w,
      groups: w.groups.filter((g) => g.id !== id),
      tabs: w.tabs.map((t) => (t.groupID === id ? { ...t, groupID: undefined } : t)),
    }));
  }

  // MARK: Dialogs

  edit(editing?: TerminalEdit) {
    this.set({ editing });
  }

  // MARK: Saving

  private update(change: (w: Workspace) => Workspace) {
    const next = change(this.workspace);
    if (serializeWorkspace(next) === serializeWorkspace(this.workspace)) return;
    this.set({ workspace: next });
    void invoke("save_workspace", { json: serializeWorkspace(next) });
  }

  private updateTab(id: string, change: (t: TerminalTab) => TerminalTab) {
    this.update((w) => ({ ...w, tabs: w.tabs.map((t) => (t.id === id ? change(t) : t)) }));
  }

  private updateGroup(id: string, change: (g: TerminalGroup) => TerminalGroup) {
    this.update((w) => ({ ...w, groups: w.groups.map((g) => (g.id === id ? change(g) : g)) }));
  }

  /** Records where each shell is now, so tabs reopen in the same folder. */
  private async refreshDirectories() {
    const ids = [...this.sessions.keys()];
    const fromOS = await invoke<Record<string, string>>("pty_cwd", { ids }).catch(() => ({}) as Record<string, string>);
    this.update((w) => ({
      ...w,
      tabs: w.tabs.map((t) => {
        const dir = fromOS[t.id] ?? this.liveDirectory(t.id);
        return dir && dir !== t.directory ? { ...t, directory: dir } : t;
      }),
    }));
  }

  private async saveScrollback() {
    await Promise.all(
      [...this.sessions].map(async ([id, session]) => {
        const text = session.scrollbackText();
        if (this.savedScrollback.get(id) === text) return;
        this.savedScrollback.set(id, text);
        await invoke("save_scrollback", { id, text }).catch(() => {});
      }),
    );
  }

  /** On quit (including a restart or shutdown): save folders, layout and scrollback. */
  async saveEverything() {
    if (!this.active) return;
    await this.refreshDirectories();
    await this.saveScrollback();
    await invoke("save_workspace", { json: serializeWorkspace(this.workspace) });
  }
}
