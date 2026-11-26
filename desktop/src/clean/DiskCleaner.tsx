import { useState, useSyncExternalStore, type ReactNode } from "react";
import { Box, ChevronRight, CircleDashed, CheckCircle2, Clock, Database, Folder, GitBranch, Home, LayoutGrid, Layers, RotateCw, Search, ShieldAlert, Sparkles, Trash2, XCircle, type LucideIcon } from "lucide-react";
import { abbreviate, api, bytes, isDocker, nameOf, parentOf, plural, relative, words, type Storage } from "./api";
import { worktreeParts, worktreeSize, type CleanerModel, type TreeRow, type WorktreeGroup } from "./cleanerModel";
import { Checkbox, ConfirmDialog, FileIcon, Hero, LazyList, Pill, RemovalPanel, SearchField, Segmented, SizeColumn, Spinner, UsageBar, showFileMenu } from "./ui";
import type { Mode } from "./api";
import { isMac, os } from "../platform";

export function DiskCleaner({ model, storage }: { model: CleanerModel; storage?: Storage }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const subtitle =
    s.phase === "idle"
      ? "Find what's using your disk"
      : s.phase === "scanning"
        ? "Scanning…"
        : s.summary
          ? `${bytes(s.summary.total)} in ${plural(s.summary.files, "file")} · scanned in ${duration(s.summary.millis)}`
          : "";
  return (
    <div className="detail-content clean-detail">
      <header className="detail-header" data-tauri-drag-region>
        <div className="detail-titles" data-tauri-drag-region>
          <div className="detail-title">Disk Cleaner</div>
          <div className="detail-subtitle">{subtitle}</div>
        </div>
        {s.phase === "ready" && (
          <div className="toolbar">
            <SearchField value={s.query} onChange={model.setQuery} placeholder="Filter by name or path" />
            <button className="icon-button" title="Scan again" disabled={!!s.removal} onClick={() => model.startScan()}>
              <RotateCw size={15} />
            </button>
          </div>
        )}
      </header>
      {s.phase === "idle" && <Welcome model={model} storage={storage} />}
      {s.phase === "scanning" && <Scanning files={s.scannedFiles} folder={s.scanningPath} onCancel={() => model.cancelScan()} />}
      {s.phase === "ready" && <Results model={model} storage={storage} />}
      <RemovalPanel removal={s.removal} host={model} />
    </div>
  );
}

function duration(ms: number) {
  const secs = Math.max(1, Math.round(ms / 1000));
  return secs < 60 ? `${secs}s` : `${Math.floor(secs / 60)}m ${secs % 60}s`;
}

function Welcome({ model, storage }: { model: CleanerModel; storage?: Storage }) {
  const scopes = os === "windows" ? [{ icon: Home, title: "Your user folder" }, { icon: Clock, title: "Temporary files" }] : [
    { icon: Home, title: "Home folder" },
    ...(isMac ? [{ icon: LayoutGrid, title: "Applications" }] : []),
    { icon: Clock, title: "Temporary files" },
  ];
  return (
    <div className="scroll center">
      <div className="welcome">
        <Hero icon={Sparkles} tint="linear-gradient(135deg, #40c8e0, #1a7fd6)" />
        <h1>See what's filling your disk</h1>
        <p>
          Clearspace measures {os === "windows" ? "your user folder, including app data and temporary files" : isMac ? "your Home folder, Applications and temporary files" : "your home folder and temporary files"}, then lists everything biggest first.
          Nothing is removed until you pick it.
        </p>
        {storage && <StorageCard storage={storage} />}
        <div className="chips">
          {scopes.map(({ icon: Icon, title }) => (
            <span key={title} className="chip">
              <Icon size={13} /> {title}
            </span>
          ))}
        </div>
        <button className="primary-button large" autoFocus onClick={() => model.startScan()}>
          <Search size={14} /> Start Scan
        </button>
        {storage?.fullDiskAccess === false && <FullDiskAccessCallout />}
      </div>
    </div>
  );
}

export function StorageCard({ storage }: { storage: Storage }) {
  const used = Math.max(0, storage.total - storage.available);
  return (
    <div className="storage-card">
      <div className="storage-row">
        <span className="storage-name">{storage.name}</span>
        <span className="numeric muted">{bytes(storage.available)} available</span>
      </div>
      <UsageBar fraction={storage.total ? used / storage.total : 0} />
      <div className="storage-row small muted">
        <span className="numeric">{bytes(used)} used</span>
        <span className="numeric">{bytes(storage.total)} total</span>
      </div>
    </div>
  );
}

export function FullDiskAccessCallout() {
  return (
    <div className="callout">
      <ShieldAlert size={18} className="callout-icon" />
      <div>
        <b>Give Clearspace Full Disk Access</b>
        <div className="muted">Without it, macOS asks for permission folder by folder and hides some caches from the scan.</div>
      </div>
      <button className="plain-button" onClick={() => void api.openSettings("fullDiskAccess")}>
        Open Settings
      </button>
    </div>
  );
}

function Scanning({ files, folder, onCancel }: { files: number; folder: string; onCancel: () => void }) {
  return (
    <div className="scroll center">
      <div className="welcome">
        <Spinner size={30} />
        <h2>Scanning your disk…</h2>
        <div className="muted numeric">{files.toLocaleString()} files checked</div>
        <div className="scan-path ellipsis">{abbreviate(folder)}</div>
        <button className="plain-button large" onClick={onCancel}>
          Cancel
        </button>
      </div>
    </div>
  );
}

function Results({ model, storage }: { model: CleanerModel; storage?: Storage }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  return (
    <>
      <div className="results-bar">
        <Segmented
          id="cleaner"
          value={s.tab}
          onChange={model.setTab}
          options={[
            { value: "suggestions", label: "Suggestions" },
            { value: "folders", label: "Folders" },
            { value: "files", label: "Large Files" },
            { value: "worktrees", label: "Worktrees" },
          ]}
        />
        {storage && (
          <div className="compact-storage">
            <span className="numeric">
              {bytes(storage.available)} available of {bytes(storage.total)}
            </span>
            <UsageBar fraction={storage.total ? (storage.total - storage.available) / storage.total : 0} />
          </div>
        )}
      </div>
      {s.tab === "suggestions" && <Suggestions model={model} />}
      {s.tab === "folders" && <Folders model={model} />}
      {s.tab === "files" && <LargeFiles model={model} />}
      {s.tab === "worktrees" && <Worktrees model={model} />}
      <ActionBar model={model} />
    </>
  );
}

function Hint({ children, action }: { children: ReactNode; action?: ReactNode }) {
  return (
    <div className="hint">
      <span>{children}</span>
      {action}
    </div>
  );
}

function EmptyList({ title, text }: { title: string; text: string }) {
  return (
    <div className="list-empty">
      <CheckCircle2 size={28} strokeWidth={1.6} />
      <b>{title}</b>
      <span>{text}</span>
    </div>
  );
}

function Suggestions({ model }: { model: CleanerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const q = s.query.toLowerCase();
  const items = q ? s.suggestions.filter((x) => x.title.toLowerCase().includes(q) || x.path.toLowerCase().includes(q)) : s.suggestions;
  const largest = Math.max(items[0]?.size ?? 1, 1);
  const safe = model.safeSize();
  return (
    <>
      <Hint action={safe > 0 && <button className="pill-button" onClick={() => model.selectAllSafe()}>Select All Safe ({bytes(safe)})</button>}>
        Caches, project build folders, git worktrees, temp leftovers, videos and downloads. <b>Safe</b> items come back on their own; check the rest before removing. Quit browsers before removing their caches.
      </Hint>
      <div className="clean-list">
        <LazyList
          items={items}
          resetKey={s.query}
          render={(x) => <CleanerRow key={x.path} model={model} path={x.path} size={x.size} title={x.title} subtitle={abbreviate(x.path)} note={x.note} safety={x.safety} fraction={x.size / largest} />}
        />
        {items.length === 0 &&
          (q ? <EmptyList title="No matches" text={`Nothing matches “${s.query}”.`} /> : <EmptyList title="Nothing to suggest" text="Nothing over 20 MB worth cleaning was found. Try the Folders and Large Files views." />)}
      </div>
    </>
  );
}

function Folders({ model }: { model: CleanerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const searching = s.query.length > 0;
  const matches = searching ? model.folderMatches(s.query) : [];
  const largest = Math.max(matches[0]?.size ?? 1, 1);
  return (
    <>
      <Hint>{searching ? "Folders and files over 20 MB whose name matches." : "Everything is sorted biggest first. Open a folder to look inside; items under 20 MB are grouped as small items."}</Hint>
      <div className="clean-list">
        {searching ? (
          <LazyList items={matches} resetKey={s.query} render={(n) => <CleanerRow key={n.path} model={model} path={n.path} size={n.size} title={n.name} subtitle={abbreviate(parentOf(n.path))} dir={n.dir} fraction={n.size / largest} />} />
        ) : (
          <LazyList items={s.rows} render={(row) => <TreeRowView key={row.id} model={model} row={row} />} />
        )}
        {searching && matches.length === 0 && <EmptyList title="No matches" text={`Nothing over 20 MB is named “${s.query}”.`} />}
      </div>
    </>
  );
}

function TreeRowView({ model, row }: { model: CleanerModel; row: TreeRow }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  if (row.kind === "small") {
    return (
      <div className="clean-row small-items" style={{ paddingLeft: 12 + 26 + 20 + row.depth * 18 }}>
        <Layers size={18} className="muted" />
        <span className="row-title muted italic">Small items (under 20 MB each)</span>
        <SizeColumn size={row.size} fraction={row.fraction} muted />
      </div>
    );
  }
  const n = row.node;
  const openable = n.dir && (n.children.length > 0 || n.small > 0);
  return (
    <CleanerRow
      model={model}
      path={n.path}
      size={n.size}
      title={n.name}
      subtitle={row.depth === 0 ? abbreviate(n.path) : undefined}
      dir={n.dir}
      fraction={row.fraction}
      depth={row.depth}
      disclosure={openable ? (s.expanded.has(n.path) ? "open" : "closed") : "leaf"}
    />
  );
}

function LargeFiles({ model }: { model: CleanerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const q = s.query.toLowerCase();
  const files = q ? s.largeFiles.filter((f) => f.path.toLowerCase().includes(q)) : s.largeFiles;
  const largest = Math.max(files[0]?.size ?? 1, 1);
  return (
    <>
      <Hint>Single files over 20 MB, biggest first.</Hint>
      <div className="clean-list">
        <LazyList
          items={files}
          resetKey={s.query}
          render={(f) => <CleanerRow key={f.path} model={model} path={f.path} size={f.size} title={nameOf(f.path)} subtitle={`${abbreviate(parentOf(f.path))} · modified ${relative(f.modified)}`} fraction={f.size / largest} />}
        />
        {files.length === 0 && (q ? <EmptyList title="No matches" text={`No large file matches “${s.query}”.`} /> : <EmptyList title="No large files" text="No single file over 20 MB was found." />)}
      </div>
    </>
  );
}

const DOCKER_NOTE = {
  ready: "",
  missing: "",
  stopped: " Docker isn't running, so containers, volumes and images aren't listed.",
  remote: " Docker is set to another computer, so its containers, volumes and images aren't listed.",
};

function Worktrees({ model }: { model: CleanerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const list = model.worktreeList(s.query);
  const largest = Math.max(list[0] ? worktreeSize(list[0]) : 1, 1);
  const merged = model.mergedSize();
  return (
    <>
      <Hint action={merged > 0 && <button className="pill-button" onClick={() => model.selectMerged()}>Select Merged ({bytes(merged)})</button>}>
        Every extra checkout made with git worktree, wherever it is, with the Docker containers, volumes and images started from it. <b>Merged</b> ones hold nothing that isn't in the main branch already.
        {s.worktreesPending ? " Asking git and Docker…" : DOCKER_NOTE[s.docker ?? "missing"]}
      </Hint>
      <div className="clean-list">
        <LazyList items={list} step={60} resetKey={s.query} render={(w) => <WorktreeRows key={w.path} model={model} worktree={w} largest={largest} />} />
        {list.length === 0 &&
          (s.query ? (
            <EmptyList title="No matches" text={`No worktree matches “${s.query}”.`} />
          ) : s.worktreesPending ? (
            <EmptyList title="Looking for leftovers" text="No worktree folders were found. Checking Docker for containers left by deleted ones…" />
          ) : (
            <EmptyList title="No worktrees" text="No git worktree was found in the scanned folders, and Docker holds nothing for a deleted one." />
          ))}
      </div>
    </>
  );
}

type Badge = { text: string; tone: "green" | "orange" | "gray"; title: string };

/** Where a worktree stands, as the pills beside its name. */
function badges(w: WorktreeGroup): Badge[] {
  const out: Badge[] = [];
  if (w.deleted) out.push({ text: "Folder deleted", tone: "gray", title: "The folder is gone; only what Docker kept for it is left." });
  if (w.lost) out.push({ text: "Unlinked", tone: "orange", title: "Its repository is gone or no longer lists this checkout." });
  const g = w.git;
  if (g) {
    if (g.dirty > 0) out.push({ text: `${g.dirty.toLocaleString()} uncommitted`, tone: "orange", title: "Files changed or added here that were never committed. They are lost with the folder." });
    if (g.ahead === 0 && g.dirty === 0) out.push({ text: "Merged", tone: "green", title: `Every commit here is already in ${g.base}.` });
    else if (g.unpushed > 0) out.push({ text: `${g.unpushed.toLocaleString()} unpushed`, tone: "orange", title: "Commits that aren't on any remote. They stay in the repository on this computer when the folder goes." });
    else if (g.ahead) out.push({ text: "Not merged", tone: "gray", title: `${plural(g.ahead, "commit")} not in ${g.base} yet.` });
    if (g.upstreamGone) out.push({ text: "Remote branch deleted", tone: "gray", title: "Its branch was pushed and has since been deleted on the remote, as happens after a merged pull request." });
  }
  if (w.resources.some((r) => r.running)) out.push({ text: "Running", tone: "orange", title: "A container started from this folder is running now." });
  return out;
}

const PART_ICONS: Record<string, LucideIcon> = { container: Box, volume: Database, image: Layers };

/** One worktree, and under it each thing it holds when Docker has some. */
function WorktreeRows({ model, worktree: w, largest }: { model: CleanerModel; worktree: WorktreeGroup; largest: number }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const total = worktreeSize(w);
  const state = model.worktreeSelection(w);
  const covered = !w.deleted && model.isCovered(w.path);
  const facts = [w.repoName, w.deleted ? "" : (w.branch ?? "detached HEAD"), w.modified ? `changed ${relative(w.modified)}` : ""].filter(Boolean).join(" · ");
  const counts = ["container", "volume", "image"].map((kind) => [kind, w.resources.filter((r) => r.kind === kind).length] as const).filter(([, n]) => n > 0);
  return (
    <div className="worktree">
      <div
        className={"clean-row tall" + (state === "all" || covered ? " selected" : "")}
        onClick={() => !covered && model.setWorktreeSelected(w, state !== "all")}
        onContextMenu={(e) => {
          e.preventDefault();
          if (!w.deleted) void showFileMenu(w.path);
        }}
      >
        <Checkbox checked={state === "all" || covered} mixed={!covered && state === "some"} disabled={covered} title={covered ? "Included because its folder is selected" : "Select the folder and what Docker holds for it"} onChange={(on) => model.setWorktreeSelected(w, on)} />
        {w.deleted ? (
          <span className="file-icon glyph" style={{ width: 26, height: 26 }}>
            <GitBranch size={16} strokeWidth={1.6} />
          </span>
        ) : (
          <FileIcon path={w.path} size={26} dir fallback={GitBranch} />
        )}
        <div className="clean-text">
          <div className="clean-title">
            <span className="ellipsis">{w.name}</span>
            {badges(w).map((b) => (
              <Pill key={b.text} text={b.text} tone={b.tone} title={b.title} />
            ))}
          </div>
          {facts && <div className="clean-subtitle ellipsis">{facts}</div>}
          <div className="clean-subtitle ellipsis">{abbreviate(w.path)}</div>
          {counts.length > 0 && <div className="clean-note">Docker: {counts.map(([kind, n]) => plural(n, kind)).join(", ")}</div>}
        </div>
        <SizeColumn size={total} fraction={total / largest} />
      </div>
      {w.resources.length > 0 &&
        worktreeParts(w).map((part) => {
          const item = w.resources.find((r) => r.id === part.id);
          const picked = s.selection.has(part.id) || model.isCovered(part.id);
          const Icon = item ? PART_ICONS[item.kind] : Folder;
          return (
            <div key={part.id} className={"clean-row part" + (picked ? " selected" : "")} onClick={() => !model.isCovered(part.id) && model.setSelected(part.id, part.size, !picked)}>
              <Checkbox checked={picked} disabled={model.isCovered(part.id)} title="Select to remove" onChange={(on) => model.setSelected(part.id, part.size, on)} />
              <span className="file-icon glyph" style={{ width: 22, height: 22 }}>
                <Icon size={15} strokeWidth={1.6} />
              </span>
              <div className="clean-text">
                <div className="clean-title">
                  <span className="row-title ellipsis">{item ? item.name : "Files"}</span>
                  {item?.running && <Pill text="Running" tone="orange" title="Removing it stops it first." />}
                  {item && !item.certain && <Pill text="Name match" tone="orange" title="Matched only by the compose project's name. Check it's this folder's before removing." />}
                </div>
                <div className="clean-subtitle ellipsis">{item ? `${item.kind[0].toUpperCase()}${item.kind.slice(1)} · ${item.detail}` : "The checkout folder and everything in it"}</div>
              </div>
              <SizeColumn size={part.size} fraction={total > 0 ? part.size / total : 0} />
            </div>
          );
        })}
    </div>
  );
}

function CleanerRow({
  model,
  path,
  size,
  title,
  subtitle,
  note,
  safety,
  dir,
  fraction,
  depth = 0,
  disclosure,
}: {
  model: CleanerModel;
  path: string;
  size: number;
  title: string;
  subtitle?: string;
  note?: string;
  safety?: "safe" | "review";
  dir?: boolean;
  fraction: number;
  depth?: number;
  /** Absent in flat lists. */
  disclosure?: "leaf" | "closed" | "open";
}) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const covered = model.isCovered(path);
  const selected = covered || s.selection.has(path);
  return (
    <div
      className={"clean-row" + (selected ? " selected" : "") + (note ? " tall" : "")}
      onClick={() => !covered && model.setSelected(path, size, !selected)}
      onDoubleClick={() => disclosure && disclosure !== "leaf" && model.toggleExpanded(path)}
      onContextMenu={(e) => {
        e.preventDefault();
        void showFileMenu(path);
      }}
    >
      <Checkbox checked={selected} disabled={covered} title={covered ? "Included because its folder is selected" : "Select to remove"} onChange={(on) => model.setSelected(path, size, on)} />
      {disclosure && (
        <span style={{ paddingLeft: depth * 18 }} className="disclosure-wrap">
          {disclosure === "leaf" ? (
            <span className="disclosure" />
          ) : (
            <button
              className="disclosure"
              aria-label={disclosure === "open" ? "Collapse" : "Expand"}
              onClick={(e) => {
                e.stopPropagation();
                model.toggleExpanded(path);
              }}
            >
              <ChevronRight size={12} strokeWidth={2.6} className={"chevron" + (disclosure === "open" ? " open" : "")} />
            </button>
          )}
        </span>
      )}
      <FileIcon path={path} size={26} dir={dir ?? !/\.[a-z0-9]{1,5}$/i.test(path)} />
      <div className="clean-text">
        <div className="clean-title">
          <span className="ellipsis">{title}</span>
          {safety && <Pill text={safety === "safe" ? "Safe" : "Review"} tone={safety === "safe" ? "green" : "orange"} />}
        </div>
        {subtitle && <div className="clean-subtitle ellipsis">{subtitle}</div>}
        {note && <div className="clean-note">{note}</div>}
      </div>
      <SizeColumn size={size} fraction={fraction} />
    </div>
  );
}

function ActionBar({ model }: { model: CleanerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const [pending, setPending] = useState<Mode>();
  const summary = model.selectionSummary();
  const count = summary.paths.length;
  const w = words();
  const what = `${plural(count, "item")} (${bytes(summary.size)})`;
  const lines = summary.paths.slice(0, 8).map(abbreviate);
  if (count > 8) lines.push(`…and ${count - 8} more`);
  const emptiesTrash = summary.paths.some((p) => s.suggestions.some((x) => x.path === p && x.title === "Trash contents"));
  const uncommitted = model.uncommittedSelected();
  const notes = [
    emptiesTrash ? `The ${w.trash} will be emptied permanently.` : "",
    uncommitted.length > 0 ? `Changes never committed in ${uncommitted.slice(0, 3).join(", ")}${uncommitted.length > 3 ? ` and ${uncommitted.length - 3} more` : ""} go with ${uncommitted.length === 1 ? "it" : "them"}.` : "",
    summary.paths.some(isDocker) ? `Docker containers are stopped, and Docker items are deleted for good${pending === "trash" ? `, not moved to the ${w.trash}` : ""}.` : "",
    pending === "trash" ? `Space is freed once you empty the ${w.trash}.` : "This can't be undone.",
  ]
    .filter(Boolean)
    .join(" ");
  return (
    <>
      <div className="action-bar">
        {count === 0 ? <CircleDashed size={20} className="muted" /> : <CheckCircle2 size={20} className="accent" />}
        <div className="action-text">
          <b>{count === 0 ? "Nothing selected" : `${plural(count, "item")} selected`}</b>
          <span className="muted numeric">{count === 0 ? "Tick items to remove them" : bytes(summary.size)}</span>
        </div>
        <div className="spacer" />
        {count > 0 && (
          <button className="link-button" onClick={model.clearSelection}>
            Clear
          </button>
        )}
        <button className="plain-button" disabled={count === 0} title={`Moves to the ${w.trash}. Space is freed once you empty it.`} onClick={() => setPending("trash")}>
          <Trash2 size={14} /> {w.moveToTrash}
        </button>
        <button className="danger-button" disabled={count === 0} onClick={() => setPending("permanent")}>
          <XCircle size={14} /> Delete Permanently
        </button>
      </div>
      <ConfirmDialog
        open={!!pending}
        title={pending === "permanent" ? `Permanently delete ${what}?` : `Move ${what} to the ${w.trash}?`}
        lines={lines}
        note={notes}
        confirm={pending === "permanent" ? "Delete Permanently" : w.moveToTrash}
        destructive
        onConfirm={() => pending && model.remove(pending)}
        onClose={() => setPending(undefined)}
      />
    </>
  );
}

