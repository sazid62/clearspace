# Clearspace (desktop)

The cross-platform Clearspace app for macOS, Windows and Linux, built with Tauri 2: a Rust backend
(shells via `portable-pty`) and a React + xterm.js window.

Spaces work as in Arc: each space has its own sidebar, and a two-finger swipe on the sidebar moves
between them (on macOS the trackpad's real phases are read from AppKit, `src-tauri/src/swipe.rs`).

- **Clean** — Disk Cleaner (scan, suggestions, folders, large files, git worktrees with the Docker
  containers, volumes and images started from each; Trash/Recycle Bin or permanent delete,
  administrator retry), App Uninstaller (macOS .app bundles and their leftovers, Windows'
  installed programs via their own uninstaller, Linux packages via Flatpak/Snap/apt/dnf/pacman/zypper
  or AppImage), Maintenance, Status and History. Platform rules live in `src-tauri/src/clean/`.
- **Terminal** — groups, colored tabs, pins and startup commands, restored after a quit or restart.

## Build

Needs Node 20+ and Rust (`brew install rustup && rustup default stable` on a Mac). On Ubuntu also:
`sudo apt install libwebkit2gtk-4.1-dev libappindicator3-dev librsvg2-dev patchelf`.

```sh
npm install
npx tauri build                 # installers for this OS in src-tauri/target/release/bundle/
npx tauri build --bundles app   # macOS: just Clearspace.app
```

CI (`.github/workflows/desktop.yml`) builds macOS (universal), Windows and Ubuntu, and runs the
self-test on each.

## Self-test

`node scripts/selftest.mjs <app binary>` opens the real app with a throwaway data folder, drives it
(shell output, groups, colors, startup command, swipe gestures), quits through the normal save path,
reopens it and checks that everything came back, then scans a small fixture with the Disk Cleaner
(a project, a big log and a linked git worktree), deletes one item, checks that a never-clean folder
is refused, opens the App Uninstaller without removing anything, and opens Maintenance, Status and
History without running anything. Snapshots and logs land
in the printed folder.

## Worktrees

The Disk Cleaner's **Worktrees** view lists every linked git worktree in the scanned folders,
hidden ones (`.claude/worktrees`) included, with what belongs to each:

- its folder, and where its branch stands: *Merged* (nothing that isn't in the main branch),
  uncommitted files, commits on no remote, remote branch deleted;
- the Docker containers started from it (compose's working folder, a dev container's folder, or a
  mounted folder), and the volumes and images nothing outside it uses;
- volumes and images matched only by the compose project's name are marked *Name match* and are
  never ticked with the rest.

Folders already deleted whose containers remain are listed too. Deleting a worktree permanently
also drops its record from the repository, as `git worktree prune` would; moving it to the Trash
keeps the record so it can be put back. Docker items are always deleted for good. Git and Docker
are read through their command-line tools, and only a Docker running on this computer is used.

## Suggestions

Besides known caches, project build folders, worktrees and temp leftovers, the scan suggests:

- any app's caches and logs (`~/Library/Caches`, `~/Library/Logs`, `~/.cache`) and the cache
  folders Chromium and Electron apps keep inside their own folders (`Cache`, `Code Cache`,
  `GPUCache`…); offline web copies (`CacheStorage`) are marked *Review*;
- what removed apps left: on macOS, containers, saved window state and Application Support folders
  named after an identifier no installed app has (Spotlight is asked too, for apps kept elsewhere);
  on Linux, data of Flatpak apps and snaps no longer installed. Always *Review*.

**Never clean** (the lock button, or right-click › Never Clean This) keeps a file or folder, and
everything in it, out of the suggestions and refuses to remove it from either tool.

## Maintenance, Status, History

- **Maintenance** runs system chores only when ticked, showing the command each runs: DNS flush,
  Quick Look and Open With rebuilds, Spotlight reindex, Touch ID for `sudo` (macOS); package-cache
  and log cleanup, SSD trim (Linux); Windows Update cleanup, drive optimization (Windows).
  Administrator tasks share one password prompt.
- **Slim Apps** (Apple silicon) removes the Intel half of universal apps. Only files the code
  signature treats as separately signed code are thinned, on a copy; the copy must verify as well
  as the original and still pass Gatekeeper, then replaces it while the original goes to the Trash.
  App Store apps are skipped.
- **Status** samples processor, memory, swap, disk and network activity, battery and the busiest
  programs every two seconds while open, with a rough health score.
- **History** lists everything removed, slimmed or run, newest first.

## Saved data

Same folder and format as the native macOS app, so tabs carry over between them:

| OS      | Folder                                         |
| ------- | ---------------------------------------------- |
| macOS   | `~/Library/Application Support/Clearspace/Terminal` |
| Windows | `%APPDATA%\Clearspace\Terminal`                |
| Linux   | `~/.local/share/Clearspace/Terminal`           |

Don't run the native and the Tauri app at the same time: both write `workspace.json`.

The never-clean list (`protected.json`) and the history (`history.jsonl`, last 5,000 entries) sit
in a `Clean` folder beside `Terminal`.

## Keys

| Action         | macOS        | Windows / Linux  |
| -------------- | ------------ | ---------------- |
| New tab        | ⌘T           | Ctrl+Shift+T     |
| Close tab      | ⌘W           | Ctrl+Shift+W     |
| Next / prev tab| ⌘⇧] / ⌘⇧[ , ⌃Tab | Ctrl+Tab / Ctrl+Shift+Tab |
| New group      | ⌘⇧N          | Ctrl+Shift+G     |
| Spaces         | ⌃1 / ⌃2      | Ctrl+Shift+1 / 2 |
| Copy / paste   | ⌘C / ⌘V      | Ctrl+Shift+C / V |
