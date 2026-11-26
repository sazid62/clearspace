import { useEffect, useState, useSyncExternalStore } from "react";
import { History as HistoryIcon, Scissors, Trash, Trash2, Wrench, XCircle, type LucideIcon } from "lucide-react";
import { abbreviate, api, bytes, words, type HistoryEntry } from "./api";
import { Store } from "./removal";
import { ConfirmDialog, LazyList, SearchField } from "./ui";

interface State {
  entries: HistoryEntry[];
  loaded: boolean;
  query: string;
}

/** What Clearspace removed, slimmed and ran, newest first. */
export class HistoryModel extends Store<State> {
  constructor() {
    super({ entries: [], loaded: false, query: "" });
  }

  load = () =>
    void api
      .history()
      .then((entries) => this.set({ entries, loaded: true }))
      .catch(() => this.set({ loaded: true }));

  setQuery = (query: string) => this.set({ query });

  clear() {
    void api.clearHistory().then(() => this.set({ entries: [] }));
  }
}

const TOOLS = { cleaner: "Disk Cleaner", uninstaller: "App Uninstaller", maintenance: "Maintenance" };

function describe(e: HistoryEntry): { icon: LucideIcon; verb: string; title: string } {
  if (e.action === "task") return { icon: Wrench, verb: "Ran", title: e.title };
  if (e.action === "slim") return { icon: Scissors, verb: "Slimmed", title: abbreviate(e.title) };
  if (e.action === "trash") return { icon: Trash2, verb: `Moved to the ${words().trash}`, title: abbreviate(e.title) };
  return { icon: XCircle, verb: "Deleted", title: abbreviate(e.title) };
}

const day = (seconds: number) => new Date(seconds * 1000).toLocaleDateString(undefined, { weekday: "long", year: "numeric", month: "long", day: "numeric" });
const time = (seconds: number) => new Date(seconds * 1000).toLocaleTimeString(undefined, { hour: "numeric", minute: "2-digit" });

export function History({ model }: { model: HistoryModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const [confirming, setConfirming] = useState(false);
  useEffect(() => model.load(), [model]);
  const q = s.query.toLowerCase();
  const entries = q ? s.entries.filter((e) => e.title.toLowerCase().includes(q)) : s.entries;
  // Bytes in the Trash only count once it's emptied, so they are told apart.
  const freed = s.entries.filter((e) => e.action === "delete").reduce((n, e) => n + e.size, 0);
  const trashed = s.entries.filter((e) => e.action === "trash" || e.action === "slim").reduce((n, e) => n + e.size, 0);
  const subtitle = !s.loaded
    ? "Loading…"
    : s.entries.length === 0
      ? "Nothing yet"
      : [`${s.entries.length.toLocaleString()} ${s.entries.length === 1 ? "entry" : "entries"}`, freed > 0 ? `${bytes(freed)} deleted` : "", trashed > 0 ? `${bytes(trashed)} moved to the ${words().trash}` : ""].filter(Boolean).join(" · ");
  const rows: ({ kind: "day"; label: string } | { kind: "entry"; entry: HistoryEntry; key: string })[] = [];
  let last = "";
  entries.forEach((entry, i) => {
    const label = day(entry.at);
    if (label !== last) rows.push({ kind: "day", label });
    last = label;
    rows.push({ kind: "entry", entry, key: `${entry.at}-${i}` });
  });
  return (
    <div className="detail-content clean-detail">
      <header className="detail-header" data-tauri-drag-region>
        <div className="detail-titles" data-tauri-drag-region>
          <div className="detail-title">History</div>
          <div className="detail-subtitle">{subtitle}</div>
        </div>
        {s.entries.length > 0 && (
          <div className="toolbar">
            <SearchField value={s.query} onChange={model.setQuery} placeholder="Filter by name or path" />
            <button className="icon-button" title="Clear the history" onClick={() => setConfirming(true)}>
              <Trash size={15} />
            </button>
          </div>
        )}
      </header>
      <div className="clean-list">
        {s.loaded && entries.length === 0 && (
          <div className="list-empty">
            <HistoryIcon size={28} strokeWidth={1.6} />
            <b>{q ? "No matches" : "Nothing yet"}</b>
            <span>{q ? `Nothing in the history matches “${s.query}”.` : "Everything Clearspace removes, slims or runs is listed here, on this computer only."}</span>
          </div>
        )}
        <LazyList
          items={rows}
          resetKey={s.query}
          render={(row) => {
            if (row.kind === "day")
              return (
                <div key={row.label} className="group-title">
                  {row.label}
                </div>
              );
            const { icon: Icon, verb, title } = describe(row.entry);
            return (
              <div key={row.key} className="clean-row history-row">
                <span className="file-icon glyph" style={{ width: 24, height: 24 }}>
                  <Icon size={14} strokeWidth={1.7} />
                </span>
                <div className="clean-text">
                  <div className="clean-title">
                    <span className="ellipsis" title={row.entry.title}>
                      {title}
                    </span>
                  </div>
                  <div className="clean-subtitle ellipsis">
                    {verb} · {TOOLS[row.entry.tool] ?? row.entry.tool} · {time(row.entry.at)}
                  </div>
                </div>
                {row.entry.size > 0 && <span className="size-text">{bytes(row.entry.size)}</span>}
              </div>
            );
          }}
        />
      </div>
      <ConfirmDialog
        open={confirming}
        title="Clear the history?"
        lines={[]}
        note="Only the list goes. Nothing is put back, and nothing else is removed."
        confirm="Clear History"
        destructive
        onConfirm={() => model.clear()}
        onClose={() => setConfirming(false)}
      />
    </div>
  );
}
