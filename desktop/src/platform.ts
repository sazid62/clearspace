import { invoke } from "@tauri-apps/api/core";
import { homeDir } from "@tauri-apps/api/path";

/** Set once at startup, before the first render. */
export let os: "macos" | "windows" | "linux" | string = "macos";
export let isMac = true;
export let home = "";

export async function initPlatform() {
  os = await invoke<string>("platform");
  isMac = os === "macos";
  home = await homeDir().catch(() => "");
  document.documentElement.dataset.os = os;
}

/** ⌘ on macOS, Ctrl elsewhere — for labels in menus and tooltips. */
export const mod = () => (isMac ? "⌘" : "Ctrl+");
