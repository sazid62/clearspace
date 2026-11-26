import { useEffect, useLayoutEffect, useRef, useSyncExternalStore } from "react";
import { FolderPlus, Plus, RotateCw, SquareTerminal } from "lucide-react";
import type { TerminalModel } from "./terminalModel";
import { showTerminalMenu } from "./menus";
import { abbreviated } from "./workspace";
import { home } from "./platform";
import { shortcutLabel } from "./shortcuts";

/**
 * The Terminal space's page. Every tab's terminal lives in one "deck" element for the app's whole
 * life; only the selected one is displayed, so switching tabs or spaces never restarts a shell.
 */
export function TerminalDetail({ model, active }: { model: TerminalModel; active: boolean }) {
  const { workspace, exited, sessionsVersion } = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const deck = useRef<HTMLDivElement>(null);
  const tab = workspace.selectedTabID ? workspace.tabs.find((t) => t.id === workspace.selectedTabID) : undefined;

  // Shells start the first time the space is shown, so startup commands (servers, watchers) run then.
  useEffect(() => {
    if (active && deck.current) void model.activate(deck.current);
  }, [active]);

  // Show the selected tab's terminal, sized to the deck, and give it the keyboard.
  useLayoutEffect(() => {
    if (!deck.current) return;
    for (const el of Array.from(deck.current.children) as HTMLElement[]) el.style.display = "none";
    if (!tab) return;
    const session = model.existingSession(tab.id);
    if (!session) return;
    session.element.style.display = "block";
    session.fit();
    if (active) requestAnimationFrame(() => session.focus());
  }, [tab?.id, active, sessionsVersion]);

  useEffect(() => {
    const el = deck.current;
    if (!el) return;
    const observer = new ResizeObserver(() => {
      const id = model.workspace.selectedTabID;
      if (id) model.existingSession(id)?.fit();
    });
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  return (
    <div className="detail-content terminal-detail">
      <header className="detail-header" data-tauri-drag-region>
        <div className="detail-titles" data-tauri-drag-region>
          <div className="detail-title">{tab ? model.title(tab) : "Terminal"}</div>
          {tab && <div className="detail-subtitle">{abbreviated(tab.directory, home)}</div>}
        </div>
        <div className="toolbar">
          <button className="icon-button" title={`New group (${shortcutLabel("newGroup")})`} onClick={() => model.edit({ kind: "newGroup" })}>
            <FolderPlus size={16} />
          </button>
          <button className="icon-button" title={`New tab (${shortcutLabel("newTab")})`} onClick={() => model.newTab()}>
            <Plus size={17} />
          </button>
        </div>
      </header>
      <div
        className="deck"
        ref={deck}
        onContextMenu={(e) => {
          e.preventDefault();
          if (tab) void showTerminalMenu(model, tab.id);
        }}
      />
      {tab && tab.id in exited && (
        <div className="exited-bar">
          <span>
            Shell exited{exited[tab.id] != null ? ` with code ${exited[tab.id]}` : ""}.
          </span>
          <button className="pill-button" onClick={() => model.restart(tab.id)}>
            <RotateCw size={13} /> Restart
          </button>
        </div>
      )}
      {!tab && workspace.tabs.length === 0 && (
        <div className="empty overlay">
          <div className="empty-badge">
            <SquareTerminal size={34} strokeWidth={1.6} />
          </div>
          <h1>No tabs</h1>
          <p>Open a tab to start a shell. Tabs, groups and colors come back after you quit or restart.</p>
          <button className="primary-button" onClick={() => model.newTab()}>
            New Tab
          </button>
        </div>
      )}
    </div>
  );
}
