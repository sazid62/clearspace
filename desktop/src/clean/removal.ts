import { api, type AdminResult, type Mode } from "./api";

/** A tiny external store for useSyncExternalStore: replace the state, listeners re-render. */
export class Store<S extends object> {
  private listeners = new Set<() => void>();
  constructor(protected state: S) {}
  subscribe = (listener: () => void) => {
    this.listeners.add(listener);
    return () => void this.listeners.delete(listener);
  };
  getSnapshot = () => this.state;
  protected set(patch: Partial<S>) {
    this.state = { ...this.state, ...patch };
    this.listeners.forEach((l) => l());
  }
}

export interface Outcome {
  path: string;
  size: number;
  error: string | null;
  needsAdmin: boolean;
}

/** Live state of a removal job; drives the progress and summary panel. */
export interface Removal {
  mode: Mode;
  total: number;
  current: string;
  outcomes: Outcome[];
  running: boolean;
  elevating: boolean;
  adminError?: string;
}

export const removed = (r: Removal) => r.outcomes.filter((o) => !o.error);
export const failures = (r: Removal) => r.outcomes.filter((o) => o.error);
export const removedSize = (r: Removal) => removed(r).reduce((n, o) => n + o.size, 0);
export const canRetryAsAdmin = (r: Removal) => !r.running && failures(r).some((o) => o.needsAdmin);

/** What the shared panel needs from a tool. */
export interface RemovalHost {
  retryAsAdmin(): void;
  finishRemoval(): void;
}

/**
 * Runs a removal one item at a time in Rust, reporting each step through `update`, and calls
 * `onRemoved` for every item that went.
 */
export function runRemoval(
  items: { path: string; size: number }[],
  mode: Mode,
  checks: "cleaner" | "uninstaller",
  update: (r: Removal) => void,
  onRemoved: (path: string) => void,
  onFinish: () => void,
) {
  let removal: Removal = { mode, total: items.length, current: "", outcomes: [], running: true, elevating: false };
  update(removal);
  void api.remove(items, mode, checks, (e) => {
    if (e.kind === "start") removal = { ...removal, current: e.path };
    else if (e.kind === "outcome") {
      removal = { ...removal, outcomes: [...removal.outcomes, { path: e.path, size: e.size, error: e.error, needsAdmin: e.needsAdmin }] };
      if (!e.error) onRemoved(e.path);
    } else {
      removal = { ...removal, running: false };
      onFinish();
    }
    update(removal);
  });
}

/** Retries the items that needed more rights behind the system's administrator prompt. */
export async function retryAsAdmin(removal: Removal, update: (r: Removal) => void, onRemoved: (path: string) => void) {
  const paths = failures(removal).filter((o) => o.needsAdmin).map((o) => o.path);
  update({ ...removal, elevating: true, adminError: undefined });
  const result: AdminResult = await api.removeAsAdmin(paths, removal.mode).catch((e) => ({ kind: "failed" as const, message: String(e) }));
  const stillThere = await api.exists(paths).catch(() => paths.map(() => true));
  const gone = new Set(paths.filter((_, i) => !stillThere[i]));
  const outcomes = removal.outcomes.map((o) => {
    if (!o.needsAdmin) return o;
    if (gone.has(o.path)) return { ...o, error: null, needsAdmin: false };
    if (result.kind !== "cancelled") return { ...o, error: "Still there after the administrator retry. The system may be protecting it.", needsAdmin: false };
    return o;
  });
  gone.forEach(onRemoved);
  update({
    ...removal,
    outcomes,
    elevating: false,
    adminError: result.kind === "failed" && gone.size === 0 ? result.message : undefined,
  });
}
