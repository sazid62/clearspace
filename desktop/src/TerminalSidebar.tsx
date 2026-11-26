import { useSyncExternalStore } from "react";
import { Reorder } from "motion/react";
import { ChevronRight, Pin, Plus, Zap, X } from "lucide-react";
import type { TerminalModel } from "./terminalModel";
import { showGroupMenu, showTabMenu } from "./menus";
import { abbreviated, tabsIn, type SectionKey, type TerminalGroup, type TerminalTab } from "./workspace";
import { home } from "./platform";
import { shortcutLabel } from "./shortcuts";

export function TerminalSidebar({ model }: { model: TerminalModel }) {
  const { workspace: ws } = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const pinned = tabsIn(ws, "pinned");
  const loose = tabsIn(ws, "loose");

  return (
    <div
      className="list"
      onContextMenu={(e) => {
        if (e.target === e.currentTarget) {
          e.preventDefault();
          model.edit({ kind: "newGroup" });
        }
      }}
    >
      {pinned.length > 0 && (
        <>
          <div className="section-title">Pinned</div>
          <TabList model={model} section="pinned" tabs={pinned} />
        </>
      )}
      {ws.groups.map((group) => (
        <GroupSection key={group.id} model={model} group={group} tabs={tabsIn(ws, `group:${group.id}`)} />
      ))}
      <div className="section-title">{ws.groups.length === 0 && pinned.length === 0 ? "Tabs" : "Other Tabs"}</div>
      <TabList model={model} section="loose" tabs={loose} />
      <button className="row new-tab" onClick={() => model.newTab(undefined)} title={`New tab (${shortcutLabel("newTab")})`}>
        <Plus size={15} className="row-icon" />
        <span className="row-title">New Tab</span>
      </button>
    </div>
  );
}

function GroupSection({ model, group, tabs }: { model: TerminalModel; group: TerminalGroup; tabs: TerminalTab[] }) {
  return (
    <>
      <div
        className="group-header"
        style={{ ["--dot" as string]: `var(--c-${group.color})` }}
        onClick={() => model.setGroupExpanded(group.id, !group.isExpanded)}
        onDoubleClick={() => model.edit({ kind: "renameGroup", id: group.id })}
        onContextMenu={(e) => {
          e.preventDefault();
          void showGroupMenu(model, group.id);
        }}
      >
        <ChevronRight size={12} className={"chevron" + (group.isExpanded ? " open" : "")} />
        <span className="dot" />
        <span className="group-name">{group.name}</span>
        <button
          className="icon-button hover-only"
          title="New tab in this group"
          onClick={(e) => {
            e.stopPropagation();
            model.newTab(group.id);
          }}
        >
          <Plus size={13} />
        </button>
      </div>
      {group.isExpanded && <TabList model={model} section={`group:${group.id}`} tabs={tabs} />}
    </>
  );
}

/** One section's tabs, reordered by dragging. */
function TabList({ model, section, tabs }: { model: TerminalModel; section: SectionKey; tabs: TerminalTab[] }) {
  return (
    <Reorder.Group
      as="div"
      axis="y"
      values={tabs.map((t) => t.id)}
      onReorder={(ids: string[]) => model.reorder(section, ids)}
      className="tab-list"
    >
      {tabs.map((tab) => (
        <TabRow key={tab.id} model={model} tab={tab} />
      ))}
    </Reorder.Group>
  );
}

function TabRow({ model, tab }: { model: TerminalModel; tab: TerminalTab }) {
  const { workspace, exited } = useSyncExternalStore(model.subscribe, model.getSnapshot);
  const selected = workspace.selectedTabID === tab.id;
  const color = model.colorOf(tab);
  const hasExited = tab.id in exited;
  const subtitle = abbreviated(tab.directory, home);

  return (
    <Reorder.Item
      as="div"
      value={tab.id}
      className={"row tab-row" + (selected ? " selected" : "") + (hasExited ? " exited" : "")}
      style={{ ["--dot" as string]: color ? `var(--c-${color})` : "var(--muted)" }}
      onClick={() => model.select(tab.id)}
      onDoubleClick={() => model.edit({ kind: "renameTab", id: tab.id })}
      onContextMenu={(e) => {
        e.preventDefault();
        model.select(tab.id);
        void showTabMenu(model, tab.id);
      }}
      whileDrag={{ scale: 1.02, boxShadow: "0 6px 18px rgba(0,0,0,0.25)", zIndex: 5 }}
      transition={{ type: "spring", stiffness: 500, damping: 40 }}
    >
      <span className={"dot" + (color ? "" : " hollow")} />
      <span className="tab-text">
        <span className="row-title">{model.title(tab)}</span>
        <span className="row-subtitle">
          {tab.startupCommand && <Zap size={10} className="inline-icon" />}
          {tab.isPinned && <Pin size={10} className="inline-icon" />}
          {hasExited ? "exited" : subtitle}
        </span>
      </span>
      <button
        className="icon-button hover-only"
        title={`Close tab (${shortcutLabel("closeTab")})`}
        onClick={(e) => {
          e.stopPropagation();
          model.close(tab.id);
        }}
      >
        <X size={13} />
      </button>
    </Reorder.Item>
  );
}
