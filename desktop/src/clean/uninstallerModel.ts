import { api, type App, type Inspection, type Leftover, type Mode } from "./api";
import { retryAsAdmin, runRemoval, Store, type Removal, type RemovalHost } from "./removal";
import { os } from "../platform";

export type SortOrder = "name" | "size";

interface State {
  apps: App[];
  loading: boolean;
  /** Measured sizes (the app plus what it owns). */
  sizes: Map<string, number>;
  query: string;
  sort: SortOrder;
  selectedId?: string;
  inspected?: App;
  leftovers: Leftover[];
  leftoverSizes: Map<string, number>;
  mentions: string[];
  searching: boolean;
  checked: Set<string>;
  running: boolean;
  /** The app's own uninstaller is running (Windows, Linux). */
  uninstalling: boolean;
  /** It ran: what's listed now is what it left behind. */
  uninstalled: boolean;
  uninstallError?: string;
  removal?: Removal;
  error?: string;
}

/** App Uninstaller: the app list, one app's leftovers, and removal. */
export class UninstallerModel extends Store<State> implements RemovalHost {
  private loaded = false;
  private inspection = 0;
  private runningTimer?: number;
  onFilesRemoved?: () => void;

  constructor() {
    super({
      apps: [],
      loading: false,
      sizes: new Map(),
      query: "",
      sort: "name",
      leftovers: [],
      leftoverSizes: new Map(),
      mentions: [],
      searching: false,
      checked: new Set(),
      running: false,
      uninstalling: false,
      uninstalled: false,
    });
  }

  // ---------- App list ----------

  visibleApps(): App[] {
    const { apps, query, sort, sizes } = this.state;
    const q = query.toLowerCase();
    const matches = q ? apps.filter((a) => a.name.toLowerCase().includes(q) || (a.detail ?? "").toLowerCase().includes(q)) : apps;
    if (sort !== "size") return matches;
    const size = (a: App) => sizes.get(a.id) ?? a.size ?? -1;
    return [...matches].sort((a, b) => size(b) - size(a));
  }

  loadIfNeeded() {
    if (!this.loaded) this.reload();
  }

  reload() {
    if (this.state.loading) return;
    this.loaded = true;
    this.set({ loading: true });
    api
      .apps()
      .then((apps) => {
        this.set({ apps, loading: false });
        if (this.state.selectedId && !apps.some((a) => a.id === this.state.selectedId) && !this.state.uninstalled) this.select(undefined);
        void api.measureApps((batch) => {
          const sizes = new Map(this.state.sizes);
          for (const { id, size } of batch) sizes.set(id, size);
          this.set({ sizes });
        });
      })
      .catch((e) => this.set({ loading: false, error: String(e) }));
  }

  setQuery = (query: string) => this.set({ query });
  setSort = (sort: SortOrder) => this.set({ sort });

  select(id: string | undefined) {
    if (id === this.state.selectedId && !this.state.uninstalled) return;
    const app = id ? this.state.apps.find((a) => a.id === id) : undefined;
    this.set({ selectedId: id });
    if (app) this.inspect(app);
    else this.clearInspection();
  }

  /** An app chosen with the file picker (from Downloads, another disk…). */
  async open(path: string) {
    try {
      const app = await api.openApp(path);
      if (!this.state.apps.some((a) => a.id === app.id)) {
        this.set({ apps: [...this.state.apps, app].sort((a, b) => a.name.localeCompare(b.name)) });
      }
      this.set({ selectedId: app.id });
      this.inspect(app);
    } catch (e) {
      this.set({ error: String(e) });
    }
  }

  dismissError = () => this.set({ error: undefined });

  // ---------- Inspection ----------

  private inspect(app: App, keepUninstalled = false) {
    const token = ++this.inspection;
    this.set({
      inspected: app,
      leftovers: [],
      leftoverSizes: new Map(),
      mentions: [],
      checked: new Set(),
      searching: true,
      running: false,
      uninstalled: keepUninstalled,
      uninstallError: undefined,
    });
    this.watchRunning();
    void api
      .inspect(app.id, (e) => {
        if (token !== this.inspection) return;
        if (e.kind === "found") this.found(e.inspection);
        else if (e.kind === "size") this.set({ leftoverSizes: new Map(this.state.leftoverSizes).set(e.path, e.size) });
        else {
          const footprint = this.state.leftovers.filter((l) => l.confidence === "exact").reduce((n, l) => n + (this.state.leftoverSizes.get(l.path) ?? 0), 0);
          if (!keepUninstalled) this.set({ sizes: new Map(this.state.sizes).set(app.id, footprint + (this.state.leftovers.some((l) => l.kind === "application") ? 0 : app.size ?? 0)) });
        }
      })
      .catch((err) => token === this.inspection && this.set({ searching: false, error: String(err) }));
  }

  private found(inspection: Inspection) {
    // Name-only matches might belong to something else, so they start unticked.
    this.set({
      leftovers: inspection.leftovers,
      mentions: inspection.mentions,
      checked: new Set(inspection.leftovers.filter((l) => l.confidence === "exact").map((l) => l.path)),
      searching: false,
    });
  }

  private clearInspection() {
    this.inspection++;
    window.clearInterval(this.runningTimer);
    this.set({ inspected: undefined, leftovers: [], leftoverSizes: new Map(), mentions: [], checked: new Set(), searching: false, running: false, uninstalled: false });
  }

  totalSize() {
    return this.state.leftovers.reduce((n, l) => n + (this.state.leftoverSizes.get(l.path) ?? 0), 0);
  }

  checkedSize() {
    let n = 0;
    for (const p of this.state.checked) n += this.state.leftoverSizes.get(p) ?? 0;
    return n;
  }

  setChecked(path: string, on: boolean) {
    const checked = new Set(this.state.checked);
    if (on) checked.add(path);
    else checked.delete(path);
    this.set({ checked });
  }

  checkAll(on: boolean) {
    this.set({ checked: on ? new Set(this.state.leftovers.map((l) => l.path)) : new Set() });
  }

  // ---------- Running app ----------

  /** Re-checks every few seconds while an app is shown (once on Windows, where asking is slow). */
  private watchRunning() {
    window.clearInterval(this.runningTimer);
    const check = () => {
      const app = this.state.inspected;
      if (!app || this.state.uninstalled) return;
      void api.isRunning(app.id).then((running) => this.state.inspected?.id === app.id && this.set({ running })).catch(() => {});
    };
    check();
    if (os !== "windows") this.runningTimer = window.setInterval(check, 2500);
  }

  async quitApp() {
    const app = this.state.inspected;
    if (!app) return;
    await api.quit(app.id).catch(() => {});
    window.setTimeout(() => this.watchRunning(), 1200);
  }

  // ---------- The app's own uninstaller (Windows, Linux packages) ----------

  async runUninstaller() {
    const app = this.state.inspected;
    if (!app || this.state.uninstalling) return;
    this.set({ uninstalling: true, uninstallError: undefined });
    try {
      await api.runUninstaller(app.id);
      this.set({ uninstalling: false });
      // What remains is what it left behind.
      this.inspect(app, true);
    } catch (e) {
      this.set({ uninstalling: false, uninstallError: String(e) });
    }
  }

  // ---------- Removal ----------

  uninstall(mode: Mode) {
    if (this.state.removal) return;
    const items = this.state.leftovers.filter((l) => this.state.checked.has(l.path)).map((l) => ({ path: l.path, size: this.state.leftoverSizes.get(l.path) ?? 0 }));
    if (!items.length) return;
    runRemoval(
      items,
      mode,
      "uninstaller",
      (removal) => this.set({ removal }),
      () => {},
      () => this.onFilesRemoved?.(),
    );
  }

  retryAsAdmin() {
    const removal = this.state.removal;
    if (!removal) return;
    void retryAsAdmin(removal, (r) => this.set({ removal: r }), () => {}).then(() => this.onFilesRemoved?.());
  }

  finishRemoval() {
    const removal = this.state.removal;
    if (!removal || removal.running || removal.elevating) return;
    this.set({ removal: undefined });
    const app = this.state.inspected;
    if (!app) return;
    void api.exists([app.location ?? app.id]).then(([stillThere]) => {
      const appGone = this.state.leftovers.some((l) => l.kind === "application") ? !stillThere : this.state.uninstalled;
      if (appGone) {
        this.set({ apps: this.state.apps.filter((a) => a.id !== app.id), selectedId: undefined });
        this.clearInspection();
        this.reload();
      } else {
        this.inspect(app, this.state.uninstalled);
      }
    });
  }
}
