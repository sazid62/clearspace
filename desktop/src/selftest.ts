// Development aid (see selftest_mode in lib.rs): drives the real UI, writes snapshots and a log,
// then closes the window through the normal save-on-quit path.
import { invoke } from "@tauri-apps/api/core";
import { getCurrentWindow } from "@tauri-apps/api/window";
import { toPng } from "html-to-image";
import { terminal } from "./App";
import { os } from "./platform";
import { cleaner, history, maintenance, status, uninstaller } from "./CleanSpace";
import { api, iconUrl } from "./clean/api";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const lines: string[] = [];
let scenarioName = "selftest";
const log = (line: string) => {
  lines.push(line);
  void invoke("selftest_write", { name: `${scenarioName}.log`, text: lines.join("\n") });
};

async function snap(name: string) {
  log(`snap ${name}…`);
  try {
    const png = await Promise.race([
      toPng(document.body, { pixelRatio: 1, cacheBust: false }),
      sleep(6000).then(() => Promise.reject("timed out (window probably covered)")),
    ]);
    await invoke("selftest_write", { name: `${name}.png`, pngBase64: png.split(",")[1] });
  } catch (e) {
    log(`snapshot ${name} failed: ${e}`);
  }
}

const space = () => document.querySelector(".space-button.selected")?.textContent ?? "?";
const strip = () => (document.querySelector(".pager-strip") as HTMLElement | null)?.style.transform ?? "?";
const write = (id: string, data: string) => invoke("pty_write", { id, data });
const buffer = (id: string) => terminal.existingSession(id)?.scrollbackText() ?? "";

/** Trackpad-style wheel events on the sidebar (deltaX > 0 = fingers moving left with natural scrolling). */
async function wheel(dx: number, dy: number, count: number, every = 16) {
  const pager = document.querySelector(".pager")!;
  for (let i = 0; i < count; i++) {
    pager.dispatchEvent(new WheelEvent("wheel", { deltaX: dx, deltaY: dy, deltaMode: 0, bubbles: true, cancelable: true }));
    await sleep(every);
  }
}

// Two-finger swipes over the sidebar. On macOS they go through the native tracker (swipe.rs) with
// real trackpad phases; elsewhere they are wheel events, as the web view sees them there.
type Phase = "began" | "changed" | "ended" | "other";
const feed = (phase: Phase, dx = 0, dy = 0, momentum = false) =>
  invoke<boolean>("swipe_feed", { sample: { phase, momentum, precise: true, inside: true, dx, dy, t: performance.now() / 1000 } });
let swallowedCoasting = true;

async function fingersDown() {
  if (os === "macos") await feed("began");
}

/** Fingers move `dx` px per step (+ = right), `count` steps, `every` ms apart. */
async function move(dx: number, dy: number, count: number, every = 16) {
  if (os !== "macos") return wheel(-dx, dy, count, every);
  for (let i = 0; i < count; i++) {
    await feed("changed", dx, dy);
    await sleep(every);
  }
}

/** Fingers lift; with `coast`, the content keeps coasting the way a flick does. */
async function lift(coast?: number) {
  const decay = [13, 11, 9.5, 8, 7, 6, 5, 4.2, 3.5, 3, 2.5, 2, 1.6, 1.3, 1, 0.8];
  if (os !== "macos") {
    if (coast) for (const d of decay) await wheel(-Math.sign(coast) * d, 0, 1);
    return;
  }
  await feed("ended");
  if (coast) for (const d of decay) swallowedCoasting = (await feed("other", Math.sign(coast) * d, 0, true)) && swallowedCoasting;
}

function clickSpace(title: string) {
  const button = [...document.querySelectorAll<HTMLButtonElement>(".space-button")].find((b) => b.title.startsWith(title));
  button?.click();
}

export async function run(scenario: string) {
  scenarioName = scenario;
  const swipeTrace: string[] = [];
  (window as { __swipeTrace?: string[] }).__swipeTrace = swipeTrace;
  window.addEventListener("error", (e) => log(`error: ${e.message}`));
  window.addEventListener("unhandledrejection", (e) => log(`rejection: ${e.reason}`));
  log(`os=${os} scenario=${scenario}`);
  await sleep(2500);
  if (scenario === "setup") {
    await snap("1-launch");
    clickSpace("Terminal");
    await sleep(1500);
    await snap("2-terminal");
    const first = terminal.workspace.selectedTabID!;
    await write(first, os === "windows" ? "cd $env:TEMP; echo hello-from-42\r" : "cd /tmp && echo hello-from-$((40+2))\r");
    await sleep(1500);
    // The output line itself, not the typed command (which also contains the text).
    log(`first tab output has hello-from-42: ${/^hello-from-42\s*$/m.test(buffer(first))}`);

    const group = terminal.newGroup("skreno", "purple");
    const api = terminal.workspace.selectedTabID!;
    terminal.rename(api, "api");
    terminal.setStartupCommand(api, os === "windows" ? "echo startup-ran-42" : "echo startup-ran-$((40+2))");
    terminal.newTab(group, os === "windows" ? undefined : "/usr");
    terminal.setTabColor(terminal.workspace.selectedTabID!, "orange");
    terminal.newGroup("infra", "green");
    terminal.togglePin(first);
    terminal.select(first);
    await sleep(2500);
    await snap("3-groups");
    const at = (x: number, y: number) => {
      const chain: string[] = [];
      for (let el = document.elementFromPoint(x, y); el && chain.length < 6; el = el.parentElement) chain.push(el.tagName.toLowerCase() + "." + [...el.classList].join("."));
      return chain.join(" < ");
    };
    log(`bottom of terminal: ${at(700, window.innerHeight - 5)}`);
    const deck = document.querySelector(".deck")!.getBoundingClientRect();
    const term = document.querySelector(".term:not([style*='none'])")!.getBoundingClientRect();
    const screen = document.querySelector(".term:not([style*='none']) .xterm-screen")?.getBoundingClientRect();
    log(`deck ${deck.top}-${deck.bottom}, term ${term.top}-${term.bottom}, xterm-screen ${screen?.top}-${screen?.bottom}`);
    terminal.edit({ kind: "newGroup" });
    await sleep(600);
    await snap("4-dialog");
    terminal.edit(undefined);
    await sleep(400);

    // Fingers right 90px, then rest (snapshot pause) and lift: under 40%, so it springs back to Terminal.
    await fingersDown();
    await move(15, 0, 6);
    log(`mid-swipe 90px: space=${space()} strip=${strip()}`);
    await snap("5-mid-swipe");
    await sleep(1200);
    await lift();
    await sleep(900);
    log(`after resting at 90px: space=${space()} strip=${strip()}`);
    log(`trace so far: ${swipeTrace.join(" | ")}`);

    // One continuous 180px swipe: past 40%, commits to Clean.
    await fingersDown();
    await move(15, 0, 12);
    await lift();
    await sleep(1200);
    log(`after 180px swipe: space=${space()} strip=${strip()}`);
    await snap("6-after-swipe");

    // A short 60px flick toward Terminal that then coasts: its speed carries it over.
    await fingersDown();
    await move(-15, 0, 4);
    await lift(-1);
    await sleep(1200);
    log(`after short flick: space=${space()} strip=${strip()}`);

    // And back to Clean the same way.
    await fingersDown();
    await move(15, 0, 4);
    await lift(1);
    await sleep(1200);
    log(`after flick back: space=${space()} strip=${strip()}`);

    // Short slow swipe toward Terminal: must spring back.
    await fingersDown();
    await move(-4, 0, 10, 40);
    await lift();
    await sleep(1200);
    log(`after short swipe: space=${space()} strip=${strip()}`);

    // Past the first space: rubber band, then back.
    await fingersDown();
    await move(20, 0, 10);
    log(`rubber band: space=${space()} strip=${strip()}`);
    await snap("7-rubber-band");
    await sleep(1200);
    await lift();
    await sleep(900);
    log(`after rubber band: space=${space()} strip=${strip()}`);

    // Vertical scrolling must not change spaces.
    await fingersDown();
    await move(-1, 20, 10);
    await lift();
    await sleep(1200);
    log(`after vertical: space=${space()} strip=${strip()}`);
    log(`coasting after a swipe swallowed: ${swallowedCoasting}`);

    clickSpace("Terminal");
    await sleep(1000);
    await snap("8-terminal-again");
    log(`workspace: ${JSON.stringify(terminal.workspace)}`);
    log(`swipe trace:\n  ${swipeTrace.join("\n  ")}`);
  } else if (scenario === "clean") {
    await cleanScenario().catch((e) => log(`clean scenario stopped: ${e}`));
  } else {
    clickSpace("Terminal");
    await sleep(2500);
    await snap("r1-restored");
    const shown = [...document.querySelectorAll<HTMLElement>(".term")].filter((el) => el.style.display !== "none");
    const selected = terminal.existingSession(terminal.workspace.selectedTabID!)?.element;
    log(`terminals shown: ${shown.length}, it is the selected tab's: ${shown[0] === selected}`);
    const ws = terminal.workspace;
    log(`strip at page: ${strip()} page width ${(document.querySelector(".pager") as HTMLElement).clientWidth}`);
    log(`groups: ${ws.groups.map((g) => `${g.name}/${g.color}`).join(", ")}`);
    log(`tabs: ${ws.tabs.map((t) => `${terminal.title(t)}${t.isPinned ? "(pinned)" : ""}@${t.directory}${t.color ? "#" + t.color : ""}`).join(" | ")}`);
    const first = ws.tabs.find((t) => t.isPinned)!;
    log(`pinned tab restored scrollback: ${buffer(first.id).includes("hello-from-42")}, divider: ${buffer(first.id).includes("restored")}`);
    const api = ws.tabs.find((t) => t.name === "api")!;
    terminal.select(api.id);
    const start = Date.now();
    while (!/^startup-ran-42$/m.test(buffer(api.id)) && Date.now() - start < 8000) await sleep(200);
    log(`api startup command ran: ${/^startup-ran-42$/m.test(buffer(api.id))} after ${Date.now() - start} ms`);
    log(`api command typed once: ${(buffer(api.id).match(/echo startup-ran/g) ?? []).length === 1}`);
    await snap("r2-api-tab");
  }
  await invoke("selftest_write", { name: `${scenario}.log`, text: lines.join("\n") });
  await getCurrentWindow().close();
}

const click = (selector: string, text?: string) => {
  const el = [...document.querySelectorAll<HTMLElement>(selector)].find((e) => !text || e.textContent?.includes(text));
  el?.click();
  return !!el;
};

async function until(test: () => boolean, ms: number) {
  const start = Date.now();
  while (!test() && Date.now() - start < ms) await sleep(150);
  return test();
}

/** Disk Cleaner on a fixture (CLEARSPACE_SCAN_ROOTS), then the App Uninstaller — looking only. */
async function cleanScenario() {
  clickSpace("Clean");
  await sleep(800);
  click(".row", "Disk Cleaner");
  await sleep(1200);
  await snap("c1-welcome");
  log(`welcome shows Start Scan: ${!!document.querySelector(".welcome .primary-button")}`);
  log(`sidebar storage: ${document.querySelector(".sidebar-storage")?.textContent ?? "none"}`);

  click(".welcome .primary-button", "Start Scan");
  log(`scan finished: ${await until(() => cleaner.getSnapshot().phase === "ready", 30000)}`);
  const st = cleaner.getSnapshot();
  log(`suggestions: ${st.suggestions.map((x) => `${x.title}/${x.safety}`).join(" | ")}`);
  log(`large files: ${st.largeFiles.length}, folder rows: ${st.rows.length}`);
  await sleep(500);
  await snap("c2-suggestions");

  click(".hint .pill-button", "Select All Safe");
  await sleep(300);
  const picked = cleaner.selectionSummary();
  log(`selected after Select All Safe: ${picked.paths.map((p) => p.split(/[\\/]/).pop()).join(",")}`);

  click(".segment", "Folders");
  await sleep(400);
  click(".clean-row button.disclosure");
  await sleep(500);
  log(`folder rows after opening the top folder: ${cleaner.getSnapshot().rows.length}`);
  await snap("c3-folders");
  click(".segment", "Large Files");
  await sleep(400);
  await snap("c4-large-files");
  click(".segment", "Worktrees");
  await until(() => !cleaner.getSnapshot().worktreesPending, 20000);
  log(`worktrees: ${cleaner.getSnapshot().worktrees.filter((w) => !w.deleted).map((w) => `${w.name}@${w.branch} in ${w.repoName}`).join(" | ")}`);
  await sleep(400);
  await snap("c4-worktrees");
  click(".segment", "Suggestions");
  await sleep(300);

  click(".action-bar .danger-button", "Delete Permanently");
  await sleep(500);
  await snap("c5-confirm");
  click(".dialog .danger-button", "Delete Permanently");
  log(`removal finished: ${await until(() => !!cleaner.getSnapshot().removal && !cleaner.getSnapshot().removal!.running, 20000)}`);
  await sleep(400);
  await snap("c6-summary");
  const removal = cleaner.getSnapshot().removal!;
  log(`removed: ${removal.outcomes.filter((o) => !o.error).length}, failed: ${removal.outcomes.filter((o) => o.error).map((o) => o.error).join(";")}`);
  const exists = await invoke<boolean[]>("clean_exists", { paths: picked.paths });
  log(`removed items gone from disk: ${exists.every((e) => !e)}`);
  click(".dialog .primary-button", "Done");
  await sleep(400);
  log(`suggestions after removal: ${cleaner.getSnapshot().suggestions.map((x) => x.title).join(" | ")}`);

  // The guard refuses the scanned folder itself.
  const root = cleaner.getSnapshot().rows[0]?.id ?? "";
  const refusal = await new Promise<string>((resolve) => {
    void import("./clean/api").then(({ api }) =>
      api.remove([{ path: root, size: 0 }], "permanent", "cleaner", (e) => {
        if (e.kind === "outcome") resolve(String(e.error));
      }),
    );
  });
  log(`guard on scanned folder: ${refusal}`);

  // Never clean: a marked folder leaves the suggestions and the removal refuses it.
  const kept = cleaner.getSnapshot().suggestions.find((x) => x.title.startsWith("node_modules"))?.path ?? "";
  await cleaner.protect(kept);
  log(`never clean hides suggestion: ${!!kept && !cleaner.getSnapshot().suggestions.some((x) => x.path === kept)}`);
  const protectedRefusal = await new Promise<string>((resolve) =>
    void api.remove([{ path: kept, size: 0 }], "permanent", "cleaner", (e) => {
      if (e.kind === "outcome") resolve(String(e.error));
    }),
  );
  log(`never clean refused: ${protectedRefusal}`);
  const stillThere = await invoke<boolean[]>("clean_exists", { paths: [kept] });
  log(`never clean kept it on disk: ${stillThere[0]}`);
  await cleaner.unprotect(kept);
  log(`never clean list after removing it: ${cleaner.getSnapshot().protected.length}`);

  if (os === "macos") {
    const res = await fetch(iconUrl("/Applications", 32)).catch(() => undefined);
    log(`icon handler: ${res?.status} ${res?.headers.get("content-type")} ${(await res?.arrayBuffer())?.byteLength ?? 0} bytes`);
  }

  click(".row", "App Uninstaller");
  log(`apps loaded: ${await until(() => uninstaller.getSnapshot().apps.length > 0 && !uninstaller.getSnapshot().loading, 30000)}`);
  const apps = uninstaller.getSnapshot().apps;
  log(`apps: ${apps.length}, first: ${apps.slice(0, 5).map((a) => a.name).join(", ")}`);
  await sleep(1500);
  await snap("c7-app-list");
  // Linux and Windows get an app from the self-test script; macOS takes one that's installed.
  const target = apps.find((a) => a.name.startsWith("Selftest Fixture ")) ?? apps.find((a) => a.uninstaller === null && !/clearspace/i.test(a.name)) ?? apps[0];
  if (target) {
    uninstaller.select(target.id);
    log(`inspected ${target.name}: ${await until(() => !uninstaller.getSnapshot().searching, 30000)}`);
    await sleep(1200);
    const u = uninstaller.getSnapshot();
    log(`leftovers: ${u.leftovers.length} (${[...new Set(u.leftovers.map((l) => l.kind))].join(",")}), checked ${u.checked.size}, mentions ${u.mentions.length}`);
    await snap("c8-inspector");
    click(".inspector .primary-button", os === "windows" ? "Recycle" : "Trash");
    await sleep(500);
    await snap("c9-uninstall-confirm");
    log(`uninstall confirm open: ${!!document.querySelector(".dialog")}`);
    click(".dialog .plain-button", "Cancel");
    await sleep(400);
    log(`nothing removed: ${!uninstaller.getSnapshot().removal}`);
  }

  // The other tools, looking only: nothing is run, slimmed or cleared.
  click(".row", "Maintenance");
  log(`maintenance loaded: ${await until(() => maintenance.getSnapshot().tasks.length > 0, 15000)}`);
  const m = maintenance.getSnapshot();
  log(`maintenance tasks: ${m.tasks.length} (${m.tasks.map((t) => t.id).join(",")}), slim supported: ${m.slimSupported}`);
  await sleep(600);
  await snap("c10-maintenance");

  click(".row", "Status");
  log(`status loaded: ${await until(() => !!status.getSnapshot().latest, 15000)}`);
  await until(() => status.getSnapshot().cpu.length >= 2, 6000);
  const v = status.getSnapshot().latest;
  if (v) log(`status: health ${v.health.score}, cores ${v.cores}, memory ${v.memoryTotal > 0}, disk ${v.diskTotal > 0}, programs ${v.byCpu.length > 0}, readings ${status.getSnapshot().cpu.length}`);
  await snap("c11-status");

  click(".row", "History");
  log(`history loaded: ${await until(() => history.getSnapshot().loaded, 10000)}`);
  const h = history.getSnapshot().entries;
  log(`history: ${h.length} entries, newest: ${h[0] ? `${h[0].action} ${h[0].title.split(/[\\/]/).pop()} by ${h[0].tool}` : "none"}`);
  await sleep(400);
  await snap("c12-history");
}
