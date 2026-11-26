// The Terminal space's saved shape. Field names and JSON match the native macOS build
// (TerminalStore.swift), so both read the same workspace.json: optional fields are left out
// when empty, and `isPinned` / `isExpanded` / `directory` are always written.

export const TAB_COLORS = ["gray", "red", "orange", "yellow", "green", "mint", "blue", "purple", "pink"] as const;
export type TabColor = (typeof TAB_COLORS)[number];

export interface TerminalGroup {
  id: string;
  name: string;
  color: TabColor;
  /** New tabs in this group start here. Unset means "same folder as the current tab". */
  directory?: string;
  isExpanded: boolean;
}

export interface TerminalTab {
  id: string;
  /** User-chosen name. Unset shows the folder name instead. */
  name?: string;
  /** Unset takes the group's color. */
  color?: TabColor;
  groupID?: string;
  isPinned: boolean;
  /** Last known folder of the shell; the tab reopens here. */
  directory: string;
  /** Runs every time the tab's shell starts, including after a restart (e.g. `pnpm dev`). */
  startupCommand?: string;
}

export interface Workspace {
  groups: TerminalGroup[];
  tabs: TerminalTab[];
  selectedTabID?: string;
}

export const emptyWorkspace = (): Workspace => ({ groups: [], tabs: [] });

export const newId = () => crypto.randomUUID().toUpperCase();

/** "pinned", "loose", or "group:<id>": which sidebar section a tab sits in. */
export type SectionKey = string;

export function sectionOf(ws: Workspace, tab: TerminalTab): SectionKey {
  if (tab.isPinned) return "pinned";
  if (tab.groupID && ws.groups.some((g) => g.id === tab.groupID)) return `group:${tab.groupID}`;
  return "loose";
}

export const tabsIn = (ws: Workspace, key: SectionKey) => ws.tabs.filter((t) => sectionOf(ws, t) === key);

/** Tabs in the order the sidebar shows them, for next/previous navigation. */
export function sidebarOrder(ws: Workspace): TerminalTab[] {
  return [...tabsIn(ws, "pinned"), ...ws.groups.flatMap((g) => tabsIn(ws, `group:${g.id}`)), ...tabsIn(ws, "loose")];
}

/** Puts one section's tabs in `orderedIds` order, leaving every other tab where it was. */
export function reorderSection(ws: Workspace, key: SectionKey, orderedIds: string[]): Workspace {
  const slots = ws.tabs.map((t, i) => (sectionOf(ws, t) === key ? i : -1)).filter((i) => i >= 0);
  const byId = new Map(ws.tabs.map((t) => [t.id, t]));
  const tabs = [...ws.tabs];
  slots.forEach((slot, n) => {
    const tab = byId.get(orderedIds[n]);
    if (tab) tabs[slot] = tab;
  });
  return { ...ws, tabs };
}

const isColor = (c: unknown): c is TabColor => TAB_COLORS.includes(c as TabColor);
const str = (v: unknown) => (typeof v === "string" && v.length > 0 ? v : undefined);

/** Reads a saved workspace, dropping anything malformed instead of failing. */
export function parseWorkspace(json: string): Workspace | undefined {
  let raw: any;
  try {
    raw = JSON.parse(json);
  } catch {
    return undefined;
  }
  if (!raw || typeof raw !== "object") return undefined;
  const groups: TerminalGroup[] = (Array.isArray(raw.groups) ? raw.groups : [])
    .filter((g: any) => str(g?.id) && str(g?.name))
    .map((g: any) => ({
      id: g.id.toUpperCase(),
      name: g.name,
      color: isColor(g.color) ? g.color : "gray",
      directory: str(g.directory),
      isExpanded: g.isExpanded !== false,
    }));
  const tabs: TerminalTab[] = (Array.isArray(raw.tabs) ? raw.tabs : [])
    .filter((t: any) => str(t?.id) && str(t?.directory))
    .map((t: any) => ({
      id: t.id.toUpperCase(),
      name: str(t.name),
      color: isColor(t.color) ? t.color : undefined,
      groupID: str(t.groupID)?.toUpperCase(),
      isPinned: t.isPinned === true,
      directory: t.directory,
      startupCommand: str(t.startupCommand),
    }));
  return { groups, tabs, selectedTabID: str(raw.selectedTabID)?.toUpperCase() };
}

/** JSON with sorted keys and no empty optionals, like the macOS build writes. */
export function serializeWorkspace(ws: Workspace): string {
  const sorted = (o: object) =>
    Object.fromEntries(
      Object.entries(o)
        .filter(([, v]) => v !== undefined && v !== null)
        .sort(([a], [b]) => (a < b ? -1 : 1)),
    );
  return JSON.stringify(
    sorted({ groups: ws.groups.map(sorted), tabs: ws.tabs.map(sorted), selectedTabID: ws.selectedTabID }),
    null,
    2,
  );
}

/** The last folder name, or "~" for home. */
export function folderName(path: string, home: string): string {
  if (samePath(path, home)) return "~";
  const parts = path.split(/[\\/]/).filter(Boolean);
  return parts[parts.length - 1] ?? path;
}

export function abbreviated(path: string, home: string): string {
  if (home && (path === home || path.startsWith(home + "/") || path.startsWith(home + "\\"))) return "~" + path.slice(home.length);
  return path;
}

const samePath = (a: string, b: string) => a.replace(/[\\/]+$/, "") === b.replace(/[\\/]+$/, "");
