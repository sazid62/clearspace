import { api, type MaintenanceTask, type SlimApp } from "./api";
import { Store } from "./removal";

export type MaintenanceTab = "tasks" | "slim";

/** How a task or an app fared in the last run. */
export interface Outcome {
  ok: boolean;
  message: string;
}

interface State {
  tab: MaintenanceTab;
  tasks: MaintenanceTask[];
  loading: boolean;
  /** Ticked task ids. */
  picked: Set<string>;
  running: Set<string>;
  outcomes: Map<string, Outcome>;
  busy: boolean;
  /** Apple silicon Macs only. */
  slimSupported: boolean;
  slimApps: SlimApp[];
  /** Still looking through the apps. */
  slimListing: boolean;
  slimListed: boolean;
  slimPicked: Set<string>;
  slimRunning?: string;
  slimOutcomes: Map<string, Outcome & { freed: number }>;
  slimBusy: boolean;
}

/** Maintenance: system chores run on request, and slimming universal apps. */
export class MaintenanceModel extends Store<State> {
  /** Called after apps were slimmed (the storage numbers change once the Trash is emptied). */
  onChanged?: () => void;

  constructor() {
    super({
      tab: "tasks",
      tasks: [],
      loading: false,
      picked: new Set(),
      running: new Set(),
      outcomes: new Map(),
      busy: false,
      slimSupported: false,
      slimApps: [],
      slimListing: false,
      slimListed: false,
      slimPicked: new Set(),
      slimOutcomes: new Map(),
      slimBusy: false,
    });
  }

  /** Called when the view opens: the task list changes with the system (Touch ID on or off). */
  load() {
    if (this.state.busy || this.state.loading) return;
    this.set({ loading: true });
    void api
      .maintenanceTasks()
      .then((tasks) => this.set({ tasks, loading: false, picked: new Set([...this.state.picked].filter((id) => tasks.some((t) => t.id === id))) }))
      .catch(() => this.set({ loading: false }));
    void api
      .slimSupported()
      .then((slimSupported) => this.set({ slimSupported }))
      .catch(() => {});
  }

  setTab = (tab: MaintenanceTab) => {
    this.set({ tab });
    if (tab === "slim" && !this.state.slimListed && !this.state.slimListing) this.listSlim();
  };

  // ---------- Tasks ----------

  toggle(id: string, on: boolean) {
    const picked = new Set(this.state.picked);
    if (on) picked.add(id);
    else picked.delete(id);
    this.set({ picked });
  }

  pickedTasks() {
    return this.state.tasks.filter((t) => this.state.picked.has(t.id));
  }

  run() {
    const ids = this.pickedTasks().map((t) => t.id);
    if (!ids.length || this.state.busy) return;
    const outcomes = new Map(this.state.outcomes);
    ids.forEach((id) => outcomes.delete(id));
    this.set({ busy: true, outcomes, running: new Set() });
    void api
      .runMaintenance(ids, (e) => {
        if (e.kind === "start") this.set({ running: new Set([...this.state.running, e.id]) });
        else if (e.kind === "outcome") {
          const running = new Set(this.state.running);
          running.delete(e.id);
          this.set({ running, outcomes: new Map(this.state.outcomes).set(e.id, { ok: e.ok, message: e.message }) });
        } else {
          this.set({ busy: false, running: new Set(), picked: new Set() });
          this.reloadKeepingOutcomes();
        }
      })
      .catch(() => this.set({ busy: false, running: new Set() }));
  }

  /** A finished task can change the list (Touch ID turns into its opposite); its result stays shown. */
  private reloadKeepingOutcomes() {
    void api
      .maintenanceTasks()
      .then((tasks) => this.set({ tasks }))
      .catch(() => {});
  }

  // ---------- Slimming ----------

  listSlim() {
    if (this.state.slimListing || this.state.slimBusy) return;
    this.set({ slimListing: true, slimApps: [], slimPicked: new Set(), slimOutcomes: new Map() });
    void api
      .slimList((e) => {
        if (e.kind === "found") this.set({ slimApps: [...this.state.slimApps, e.app].sort((a, b) => b.intel - a.intel) });
        else if (e.kind === "listed") this.set({ slimListing: false, slimListed: true });
      })
      .catch(() => this.set({ slimListing: false, slimListed: true }));
  }

  toggleSlim(id: string, on: boolean) {
    const slimPicked = new Set(this.state.slimPicked);
    if (on) slimPicked.add(id);
    else slimPicked.delete(id);
    this.set({ slimPicked });
  }

  pickAllSlim(on: boolean) {
    this.set({ slimPicked: on ? new Set(this.state.slimApps.filter((a) => !this.state.slimOutcomes.get(a.id)?.ok).map((a) => a.id)) : new Set() });
  }

  pickedSlim() {
    return this.state.slimApps.filter((a) => this.state.slimPicked.has(a.id));
  }

  slim() {
    const ids = this.pickedSlim().map((a) => a.id);
    if (!ids.length || this.state.slimBusy) return;
    this.set({ slimBusy: true });
    void api
      .slimRun(ids, (e) => {
        if (e.kind === "start") this.set({ slimRunning: e.id });
        else if (e.kind === "outcome") {
          const picked = new Set(this.state.slimPicked);
          picked.delete(e.id);
          this.set({ slimPicked: picked, slimOutcomes: new Map(this.state.slimOutcomes).set(e.id, { ok: !e.error, message: e.error ?? "", freed: e.freed }) });
        } else if (e.kind === "finished") {
          this.set({ slimBusy: false, slimRunning: undefined });
          this.onChanged?.();
        }
      })
      .catch(() => this.set({ slimBusy: false, slimRunning: undefined }));
  }
}
