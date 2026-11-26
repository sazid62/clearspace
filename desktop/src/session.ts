import { Channel, invoke } from "@tauri-apps/api/core";
import { openUrl } from "@tauri-apps/plugin-opener";
import { readText, writeText } from "@tauri-apps/plugin-clipboard-manager";
import { Terminal, type ITheme } from "@xterm/xterm";
import { FitAddon } from "@xterm/addon-fit";
import { WebLinksAddon } from "@xterm/addon-web-links";
import { isMac } from "./platform";

type PtyEvent = { kind: "data"; data: string } | { kind: "exit"; code: number | null };

const FONT = '"SF Mono", Menlo, "Cascadia Mono", Consolas, "Ubuntu Mono", "DejaVu Sans Mono", monospace';

const DARK: ITheme = { background: "#1c1c1e", foreground: "#e6e6e6", cursor: "#e6e6e6", selectionBackground: "#3a4a6b" };
const LIGHT: ITheme = { background: "#ffffff", foreground: "#1a1a1a", cursor: "#1a1a1a", selectionBackground: "#b4cdf5" };

export const prefersDark = () => window.matchMedia("(prefers-color-scheme: dark)").matches;

/**
 * One tab's shell: an xterm.js view plus the pty behind it. Lives as long as the tab, across tab
 * and space switches, so running commands keep going while you look elsewhere.
 */
export class Session {
  readonly element: HTMLDivElement;
  readonly term: Terminal;
  private readonly fitAddon = new FitAddon();
  /** Folder reported by the shell itself (OSC 7), used where the OS can't be asked (Windows). */
  reportedDirectory?: string;
  running = false;
  onExit?: (code: number | null) => void;
  /** Our own shortcuts; returning true keeps the key away from the shell. */
  onShortcut?: (event: KeyboardEvent) => boolean;

  constructor(readonly id: string, deck: HTMLElement) {
    this.element = document.createElement("div");
    this.element.className = "term";
    this.element.style.display = "none"; // the deck shows only the selected tab
    deck.appendChild(this.element);
    this.term = new Terminal({
      fontFamily: FONT,
      fontSize: 13,
      lineHeight: 1.15,
      scrollback: 10_000,
      cursorBlink: true,
      macOptionIsMeta: false, // keep Option for typing characters such as # and €, like Terminal.app
      allowProposedApi: true,
      theme: prefersDark() ? DARK : LIGHT,
    });
    this.term.loadAddon(this.fitAddon);
    this.term.loadAddon(new WebLinksAddon((_event, uri) => void openUrl(uri)));
    this.term.open(this.element);

    this.term.onData((data) => void invoke("pty_write", { id, data }).catch(() => {}));
    this.term.onResize(({ cols, rows }) => void invoke("pty_resize", { id, cols, rows }).catch(() => {}));
    this.term.parser.registerOscHandler(7, (data) => {
      const dir = folderFromOsc7(data);
      if (dir) this.reportedDirectory = dir;
      return true;
    });
    this.term.attachCustomKeyEventHandler((event) => {
      if (event.type !== "keydown") return true;
      if (this.onShortcut?.(event)) return false;
      // Ctrl+C stays an interrupt on Windows and Linux, so copy/paste use Ctrl+Shift as in their terminals.
      if (!isMac && event.ctrlKey && event.shiftKey && event.code === "KeyC") {
        void this.copySelection();
        return false;
      }
      if (!isMac && event.ctrlKey && event.shiftKey && event.code === "KeyV") {
        void this.pasteClipboard();
        return false;
      }
      return true;
    });
  }

  setDark(dark: boolean) {
    this.term.options.theme = dark ? DARK : LIGHT;
  }

  /** Shows the previous session's output dimmed, then a divider, before the new shell prints anything. */
  showRestored(text: string, savedAt?: number) {
    const when = savedAt
      ? " · " + new Date(savedAt).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" })
      : "";
    this.term.write("\x1b[2m" + text.replace(/\r?\n/g, "\r\n") + "\x1b[0m\r\n");
    this.term.write(`\x1b[2m──── restored${when} ────\x1b[0m\r\n`);
  }

  async start(directory: string, startupCommand?: string) {
    this.fit();
    const events = new Channel<PtyEvent>();
    events.onmessage = (event) => {
      if (event.kind === "data") {
        this.term.write(event.data);
      } else {
        this.running = false;
        this.onExit?.(event.code);
      }
    };
    this.running = true;
    try {
      await invoke("pty_spawn", {
        id: this.id,
        cwd: directory,
        cols: this.term.cols,
        rows: this.term.rows,
        startup: startupCommand ?? null,
        events,
      });
    } catch (error) {
      this.running = false;
      this.term.write(`\r\n\x1b[31mCould not start a shell: ${error}\x1b[0m\r\n`);
      this.onExit?.(null);
    }
  }

  /** Resizes to the visible area; a hidden terminal has no size, so it waits until shown. */
  fit() {
    if (this.element.offsetWidth > 0 && this.element.offsetHeight > 0) this.fitAddon.fit();
  }

  focus() {
    this.term.focus();
  }

  /** The normal-screen buffer as text (full-screen apps such as vim use the other buffer and are skipped). */
  scrollbackText(): string {
    const buffer = this.term.buffer.normal;
    const lines: string[] = [];
    for (let y = 0; y < buffer.length; y++) {
      const line = buffer.getLine(y);
      if (!line) continue;
      // A wrapped line continues the previous one, so join them back into one line.
      if (line.isWrapped && lines.length) lines[lines.length - 1] += line.translateToString(true);
      else lines.push(line.translateToString(true));
    }
    return lines.join("\n");
  }

  async copySelection() {
    const text = this.term.getSelection();
    if (text) await writeText(text);
  }

  async pasteClipboard() {
    const text = await readText().catch(() => "");
    if (text) this.term.paste(text);
  }

  kill() {
    this.running = false;
    void invoke("pty_kill", { id: this.id });
  }

  dispose() {
    this.kill();
    this.term.dispose();
    this.element.remove();
  }
}

/** "file://host/Users/me/x" → "/Users/me/x"; "file://localhost/C:/Users/me" → "C:\Users\me". */
export function folderFromOsc7(data: string): string | undefined {
  try {
    const url = new URL(data);
    if (url.protocol !== "file:") return undefined;
    const path = decodeURIComponent(url.pathname);
    if (/^\/[A-Za-z]:/.test(path)) return path.slice(1).replace(/\//g, "\\");
    return path || undefined;
  } catch {
    return undefined;
  }
}
