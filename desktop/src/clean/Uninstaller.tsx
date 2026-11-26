import { useEffect, useState, useSyncExternalStore } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";
import { revealItemInDir } from "@tauri-apps/plugin-opener";
import {
  AlertTriangle,
  AppWindow,
  Archive,
  Bolt,
  Box,
  FileCog,
  FileText,
  Folder,
  FolderOpen,
  Globe,
  HelpCircle,
  Home,
  Info,
  Layers,
  Link,
  Monitor,
  PackageX,
  Pencil,
  Play,
  Plus,
  RotateCw,
  Settings,
  SquareTerminal,
  Trash2,
  XCircle,
  type LucideIcon,
} from "lucide-react";
import { abbreviate, bytes, parentOf, nameOf, plural, words, type App, type Leftover } from "./api";
import type { SortOrder, UninstallerModel } from "./uninstallerModel";
import { Checkbox, ConfirmDialog, FileIcon, Hero, LazyList, Modal, Pill, RemovalPanel, SearchField, Spinner, showFileMenu } from "./ui";
import type { Mode } from "./api";
import { isMac, os } from "../platform";

/** Group titles and icons for each kind of leftover, in display order. */
const KINDS: Record<string, { title: string; icon: LucideIcon }> = {
  application: { title: "Application", icon: AppWindow },
  support: { title: os === "linux" ? "App Data" : "Support Files & Scripts", icon: Folder },
  appData: { title: "App Data (Roaming)", icon: Folder },
  localData: { title: "Local App Data", icon: Folder },
  sharedData: { title: "Shared App Data", icon: Folder },
  packageData: { title: "Sandboxed App Data", icon: Box },
  caches: { title: "Caches", icon: Archive },
  preferences: { title: os === "linux" ? "Settings" : "Preferences", icon: Settings },
  containers: { title: "Containers", icon: Box },
  groupContainers: { title: "Group Containers", icon: Layers },
  savedState: { title: "Saved Window State", icon: Monitor },
  webData: { title: "Web Data & Cookies", icon: Globe },
  logs: { title: "Logs", icon: FileText },
  launchItems: { title: "Launch Agents, Daemons & Helpers", icon: Bolt },
  autostart: { title: "Starts at Login", icon: Play },
  shortcuts: { title: os === "windows" ? "Shortcuts" : "Menu Entries", icon: Link },
  commandLineTools: { title: "Command-Line Tools", icon: SquareTerminal },
  homeData: { title: "Data in Your Home Folder", icon: Home },
  receipts: { title: "Installer Receipts", icon: FileCog },
  other: { title: "Other", icon: HelpCircle },
};
const ORDER = Object.keys(KINDS);

export function Uninstaller({ model }: { model: UninstallerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  useEffect(() => model.loadIfNeeded(), [model]);
  const choose = async () => {
    const picked = await openDialog({
      title: "Choose an app to uninstall",
      defaultPath: isMac ? "/Applications" : undefined,
      directory: false,
      filters: isMac ? [{ name: "Applications", extensions: ["app"] }] : [{ name: "Apps", extensions: ["desktop", "AppImage", "appimage"] }],
    }).catch(() => null);
    if (typeof picked === "string") void model.open(picked);
  };
  const canChoose = os !== "windows";
  return (
    <div className="detail-content clean-detail">
      <header className="detail-header" data-tauri-drag-region>
        <div className="detail-titles" data-tauri-drag-region>
          <div className="detail-title">App Uninstaller</div>
          <div className="detail-subtitle">{s.loading && s.apps.length === 0 ? "Loading apps…" : `${plural(s.apps.length, "app")} installed`}</div>
        </div>
        <div className="toolbar">
          <SearchField value={s.query} onChange={model.setQuery} placeholder="Search apps" />
          {canChoose && (
            <button className="icon-button" title="Choose an app from anywhere…" onClick={() => void choose()}>
              <Plus size={16} />
            </button>
          )}
          <button className="icon-button" title="Reload the list of apps" disabled={s.loading} onClick={() => model.reload()}>
            <RotateCw size={15} className={s.loading ? "spin" : ""} />
          </button>
        </div>
      </header>
      <div className="split">
        <AppList model={model} />
        <div className="split-detail">{s.inspected ? <Inspector model={model} app={s.inspected} /> : <Pick onChoose={canChoose ? () => void choose() : undefined} />}</div>
      </div>
      <RemovalPanel removal={s.removal} host={model} />
      <Modal open={!!s.error} onClose={model.dismissError}>
        <h2>Couldn't open that app</h2>
        <p className="help">{s.error}</p>
        <div className="dialog-buttons">
          <button className="primary-button" onClick={model.dismissError}>
            OK
          </button>
        </div>
      </Modal>
    </div>
  );
}

function AppList({ model }: { model: UninstallerModel }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const apps = model.visibleApps();
  return (
    <div className="app-list">
      <div className="app-list-head">
        <b>{s.query ? plural(apps.length, "match") : os === "windows" ? "Installed apps" : "Applications"}</b>
        <select className="select" value={s.sort} onChange={(e) => model.setSort(e.target.value as SortOrder)} aria-label="Sort by">
          <option value="name">By Name</option>
          <option value="size">By Size</option>
        </select>
      </div>
      <div className="app-list-body">
        <LazyList
          items={apps}
          resetKey={s.query + s.sort}
          render={(app) => <AppRow key={app.id} app={app} size={s.sizes.get(app.id) ?? app.size ?? undefined} selected={app.id === s.selectedId} onSelect={() => model.select(app.id)} />}
        />
        {s.loading && s.apps.length === 0 && (
          <div className="list-empty">
            <Spinner size={22} />
            <span>Loading apps…</span>
          </div>
        )}
        {!s.loading && apps.length === 0 && <div className="list-empty">{s.query ? `No app matches “${s.query}”.` : "No apps found."}</div>}
      </div>
    </div>
  );
}

function AppRow({ app, size, selected, onSelect }: { app: App; size?: number; selected: boolean; onSelect: () => void }) {
  return (
    <button
      className={"app-row" + (selected ? " selected" : "")}
      onClick={onSelect}
      onContextMenu={(e) => {
        e.preventDefault();
        if (app.location) void showFileMenu(app.location);
      }}
    >
      <FileIcon path={app.icon ?? app.id} size={30} fallback={AppWindow} />
      <span className="app-text">
        <span className="ellipsis">{app.name}</span>
        <span className="app-sub ellipsis">{app.version ? `Version ${app.version}` : (app.detail ?? " ")}</span>
      </span>
      <span className="app-size numeric">{size != null ? bytes(size) : "—"}</span>
    </button>
  );
}

function Pick({ onChoose }: { onChoose?: () => void }) {
  return (
    <div className="scroll center">
      <div className="welcome">
        <Hero icon={PackageX} tint="linear-gradient(135deg, #ff7a59, #e0245e)" />
        <h1>Remove an app completely</h1>
        <p>
          {os === "windows"
            ? "Pick a program from the list. Clearspace runs its own uninstaller, then finds what it leaves behind in AppData, ProgramData and the Start menu."
            : os === "linux"
              ? "Pick an app from the list. Clearspace removes it with the package manager that installed it, then finds its settings, caches and data in your home folder."
              : "Pick an app from the list. Clearspace finds its preferences, caches, containers, launch agents and other leftovers so nothing is left behind."}
        </p>
        {onChoose && (
          <button className="plain-button large" onClick={onChoose}>
            Choose App…
          </button>
        )}
      </div>
    </div>
  );
}

function Inspector({ model, app }: { model: UninstallerModel; app: App }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const [pending, setPending] = useState<Mode>();
  const w = words();
  const count = s.checked.size;
  const total = s.leftovers.length;
  const disabled = count === 0 || s.searching || s.uninstalling;
  const checkedSize = model.checkedSize();
  return (
    <div className="inspector">
      <div className="app-header">
        <FileIcon path={app.icon ?? app.id} size={60} fallback={AppWindow} />
        <div className="app-header-text">
          <div className="app-name">{app.name}</div>
          <div className="muted ellipsis">{[app.version && `Version ${app.version}`, app.detail].filter(Boolean).join(" · ")}</div>
          {app.location && (
            <button className="link-button small" onClick={() => void revealItemInDir(app.location!)}>
              <FolderOpen size={12} /> {abbreviate(app.location)}
            </button>
          )}
        </div>
        {!s.searching && (
          <div className="app-total">
            <div className="numeric">{bytes(model.totalSize())}</div>
            <span className="muted">{plural(total, "item")} found</span>
          </div>
        )}
      </div>
      {s.running && (
        <div className="banner warn">
          <AlertTriangle size={15} />
          <span>{app.name} is running. Quit it before uninstalling so it can't recreate its files.</span>
          <button className="pill-button" onClick={() => void model.quitApp()}>
            Quit {app.name}
          </button>
        </div>
      )}
      {app.uninstaller && !s.uninstalled && (
        <div className="banner info">
          <PackageX size={15} />
          <span>
            {os === "windows" ? "First run the program's own uninstaller, so Windows forgets it too. " : "First remove the package, so the system forgets it too. "}
            Then remove what it leaves behind below.
          </span>
          <button className="primary-button" disabled={s.uninstalling} onClick={() => void model.runUninstaller()}>
            {s.uninstalling ? <Spinner size={12} /> : null} {s.uninstalling ? "Uninstalling…" : app.uninstaller}
          </button>
        </div>
      )}
      {s.uninstalled && (
        <div className="banner ok">
          <Info size={15} />
          <span>{s.leftovers.length ? `${app.name} is uninstalled. These are the files it left behind.` : `${app.name} is uninstalled and left nothing behind.`}</span>
        </div>
      )}
      {s.uninstallError && (
        <div className="banner error">
          <XCircle size={15} />
          <span>{s.uninstallError}</span>
        </div>
      )}
      {s.searching ? (
        <div className="scroll center">
          <div className="welcome">
            <Spinner size={22} />
            <span className="muted">Looking for related files…</span>
          </div>
        </div>
      ) : (
        <LeftoverList model={model} app={app} />
      )}
      <div className="action-bar">
        <Checkbox checked={total > 0 && count === total} mixed={count > 0 && count < total} disabled={total === 0} title={count === total ? "Deselect all" : "Select all"} onChange={(on) => model.checkAll(on)} />
        <div className="action-text">
          <b>{s.searching ? "Searching…" : `${count} of ${total} selected`}</b>
          <span className="muted numeric">{bytes(checkedSize)}</span>
        </div>
        <div className="spacer" />
        <button className="plain-button" disabled={disabled} onClick={() => setPending("permanent")}>
          Delete Permanently…
        </button>
        <button className="primary-button" disabled={disabled} onClick={() => setPending("trash")}>
          <Trash2 size={14} /> {w.moveToTrash}
        </button>
      </div>
      <ConfirmDialog
        open={pending === "trash"}
        title={`Uninstall ${app.name}?`}
        lines={[]}
        note={`${plural(count, "item")} (${bytes(checkedSize)}) will be moved to the ${w.trash}. You can put them back from the ${w.trash} if you change your mind.${s.running ? `\n\n${app.name} is still running. Quit it first for a clean removal.` : ""}`}
        confirm={w.moveToTrash}
        destructive
        onConfirm={() => model.uninstall("trash")}
        onClose={() => setPending(undefined)}
      />
      <ConfirmDialog
        open={pending === "permanent"}
        title={`Delete ${app.name} permanently?`}
        lines={[]}
        note={`${plural(count, "item")} (${bytes(checkedSize)}) will be erased right away, without going through the ${w.trash}. This can't be undone.`}
        confirm="Delete Permanently"
        destructive
        typeToConfirm={app.name}
        onConfirm={() => model.uninstall("permanent")}
        onClose={() => setPending(undefined)}
      />
    </div>
  );
}

function LeftoverList({ model, app }: { model: UninstallerModel; app: App }) {
  const s = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const groups = new Map<string, Leftover[]>();
  for (const l of s.leftovers) groups.set(l.kind, [...(groups.get(l.kind) ?? []), l]);
  const ordered = [...groups.entries()].sort(([a], [b]) => ORDER.indexOf(a) - ORDER.indexOf(b));
  const nameMatches = s.leftovers.some((l) => l.confidence === "nameOnly");
  return (
    <div className="leftovers">
      {nameMatches && (
        <div className="hint inline">
          <Info size={13} /> Items marked “Name match” only share the app's name, so they start unticked. Check them before removing.
        </div>
      )}
      {ordered.map(([kind, items]) => {
        const meta = KINDS[kind] ?? KINDS.other;
        const Icon = meta.icon;
        const size = items.reduce((n, l) => n + (s.leftoverSizes.get(l.path) ?? 0), 0);
        return (
          <section key={kind} className="leftover-group">
            <div className="group-title">
              <Icon size={13} /> <span>{meta.title}</span>
              <span className="spacer" />
              <span className="numeric">{bytes(size)}</span>
            </div>
            {items.map((l) => (
              <div
                key={l.path}
                className={"leftover-row" + (s.checked.has(l.path) ? " selected" : "")}
                onClick={() => model.setChecked(l.path, !s.checked.has(l.path))}
                onContextMenu={(e) => {
                  e.preventDefault();
                  void showFileMenu(l.path);
                }}
              >
                <Checkbox checked={s.checked.has(l.path)} onChange={(on) => model.setChecked(l.path, on)} />
                <FileIcon path={l.path} size={22} dir={!/\.[a-z0-9]{1,6}$/i.test(l.path)} />
                <div className="clean-text">
                  <div className="clean-title">
                    <span className="ellipsis">{nameOf(l.path)}</span>
                    {l.confidence === "nameOnly" && <Pill text="Name match" tone="orange" title="Matched by name only, not by the app's identifier" />}
                  </div>
                  <div className="clean-subtitle ellipsis">{abbreviate(parentOf(l.path))}</div>
                </div>
                <span className="numeric muted">{s.leftoverSizes.has(l.path) ? bytes(s.leftoverSizes.get(l.path)!) : "…"}</span>
              </div>
            ))}
          </section>
        );
      })}
      {s.mentions.length > 0 && (
        <section className="leftover-group">
          <div className="group-title">
            <Pencil size={13} /> <span>Edit by Hand</span>
          </div>
          <div className="hint inline">
            <Info size={13} /> These files also hold your own settings, so Clearspace leaves them alone. Remove the lines that mention {app.name} yourself.
          </div>
          {s.mentions.map((path) => (
            <div key={path} className="leftover-row plain" onClick={() => void revealItemInDir(path)} onContextMenu={(e) => (e.preventDefault(), void showFileMenu(path))}>
              <FileIcon path={path} size={22} />
              <span className="ellipsis">{abbreviate(path)}</span>
            </div>
          ))}
        </section>
      )}
      {s.leftovers.length === 0 && s.mentions.length === 0 && <div className="list-empty">Nothing related to {app.name} was found.</div>}
    </div>
  );
}
