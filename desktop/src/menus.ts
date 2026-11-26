import { CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu } from "@tauri-apps/api/menu";
import type { TerminalModel } from "./terminalModel";
import { TAB_COLORS, type TabColor } from "./workspace";

const colorTitle = (c: TabColor) => c[0].toUpperCase() + c.slice(1);
const separator = () => PredefinedMenuItem.new({ item: "Separator" });

/** Native right-click menu for a tab. */
export async function showTabMenu(model: TerminalModel, id: string) {
  const tab = model.tab(id);
  if (!tab) return;
  const groups = model.workspace.groups;

  const colors = await Submenu.new({
    text: "Color",
    items: [
      await CheckMenuItem.new({ text: "Group Color", checked: !tab.color, action: () => model.setTabColor(id, undefined) }),
      await separator(),
      ...(await Promise.all(
        TAB_COLORS.map((c) => CheckMenuItem.new({ text: colorTitle(c), checked: tab.color === c, action: () => model.setTabColor(id, c) })),
      )),
    ],
  });

  const move = await Submenu.new({
    text: "Move to Group",
    items: [
      ...(await Promise.all(
        groups.map((g) =>
          CheckMenuItem.new({ text: g.name, checked: tab.groupID === g.id && !tab.isPinned, action: () => model.moveToGroup(id, g.id) }),
        ),
      )),
      ...(groups.length ? [await separator()] : []),
      await MenuItem.new({ text: "New Group…", action: () => model.edit({ kind: "newGroup", movingTab: id }) }),
      await MenuItem.new({ text: "Remove from Group", enabled: !!tab.groupID, action: () => model.moveToGroup(id, undefined) }),
    ],
  });

  const menu = await Menu.new({
    items: [
      await MenuItem.new({ text: "Rename…", action: () => model.edit({ kind: "renameTab", id }) }),
      await MenuItem.new({ text: "Startup Command…", action: () => model.edit({ kind: "startupCommand", id }) }),
      colors,
      await MenuItem.new({ text: tab.isPinned ? "Unpin" : "Pin", action: () => model.togglePin(id) }),
      move,
      await separator(),
      await MenuItem.new({ text: "Duplicate", action: () => model.duplicate(id) }),
      await MenuItem.new({ text: "Restart Shell", action: () => model.restart(id) }),
      await separator(),
      await MenuItem.new({ text: "Close Tab", action: () => model.close(id) }),
    ],
  });
  await menu.popup();
}

/** Native right-click menu for a group header. */
export async function showGroupMenu(model: TerminalModel, id: string) {
  const group = model.group(id);
  if (!group) return;
  const colors = await Submenu.new({
    text: "Color",
    items: await Promise.all(
      TAB_COLORS.map((c) => CheckMenuItem.new({ text: colorTitle(c), checked: group.color === c, action: () => model.setGroupColor(id, c) })),
    ),
  });
  const folder = await Submenu.new({
    text: "Start Folder",
    items: [
      await MenuItem.new({ text: group.directory ? `In ${group.directory}` : "Same as current tab", enabled: false }),
      await separator(),
      await MenuItem.new({ text: "Choose Folder…", action: () => void model.chooseGroupDirectory(id) }),
      await MenuItem.new({ text: "Clear", enabled: !!group.directory, action: () => model.setGroupDirectory(id, undefined) }),
    ],
  });
  const menu = await Menu.new({
    items: [
      await MenuItem.new({ text: "New Tab in Group", action: () => model.newTab(id) }),
      await MenuItem.new({ text: "Rename…", action: () => model.edit({ kind: "renameGroup", id }) }),
      colors,
      folder,
      await separator(),
      await MenuItem.new({ text: "Ungroup (Keep Tabs)", action: () => model.deleteGroup(id, false) }),
      await MenuItem.new({ text: "Delete Group and Close Tabs", action: () => model.deleteGroup(id, true) }),
    ],
  });
  await menu.popup();
}

/** Right-click inside a terminal: copy, paste, clear. */
export async function showTerminalMenu(model: TerminalModel, id: string) {
  const session = model.existingSession(id);
  if (!session) return;
  const menu = await Menu.new({
    items: [
      await MenuItem.new({ text: "Copy", enabled: session.term.hasSelection(), action: () => void session.copySelection() }),
      await MenuItem.new({ text: "Paste", action: () => void session.pasteClipboard() }),
      await MenuItem.new({ text: "Select All", action: () => session.term.selectAll() }),
      await separator(),
      await MenuItem.new({ text: "Clear", action: () => session.term.clear() }),
    ],
  });
  await menu.popup();
}
