import { isMac } from "./platform";

export type Action = "newTab" | "closeTab" | "nextTab" | "prevTab" | "newGroup" | "space:clean" | "space:terminal";

/**
 * Keyboard shortcuts handled in the page. On macOS the menu bar owns ⌘T, ⌘W, ⌘⇧[ ] and ⌃1/⌃2
 * (built in Rust), so only ⌃Tab is left here. On Windows and Linux plain Ctrl+T/W/1 belong to the
 * shell (Ctrl+W deletes a word), so ours add Shift, as Windows Terminal and GNOME Terminal do.
 */
export function matchShortcut(e: KeyboardEvent): Action | undefined {
  const { ctrlKey: ctrl, shiftKey: shift, altKey: alt, metaKey: meta, code } = e;
  if (alt || meta) return undefined;
  if (ctrl && code === "Tab") return shift ? "prevTab" : "nextTab";
  if (isMac) return undefined;
  if (ctrl && code === "PageDown") return "nextTab";
  if (ctrl && code === "PageUp") return "prevTab";
  if (!ctrl || !shift) return undefined;
  switch (code) {
    case "KeyT":
      return "newTab";
    case "KeyW":
      return "closeTab";
    case "KeyG":
      return "newGroup";
    case "Digit1":
      return "space:clean";
    case "Digit2":
      return "space:terminal";
  }
  return undefined;
}

/** How a shortcut reads on this OS, for tooltips. */
export function shortcutLabel(action: Action): string {
  if (isMac) {
    return {
      newTab: "⌘T",
      closeTab: "⌘W",
      nextTab: "⌘⇧]",
      prevTab: "⌘⇧[",
      newGroup: "⌘⇧N",
      "space:clean": "⌃1",
      "space:terminal": "⌃2",
    }[action];
  }
  return {
    newTab: "Ctrl+Shift+T",
    closeTab: "Ctrl+Shift+W",
    nextTab: "Ctrl+Tab",
    prevTab: "Ctrl+Shift+Tab",
    newGroup: "Ctrl+Shift+G",
    "space:clean": "Ctrl+Shift+1",
    "space:terminal": "Ctrl+Shift+2",
  }[action];
}
