# Clearspace

A native macOS app with two tools for getting disk space back:

- **Disk Cleaner** scans your Home folder, Applications and per-user temp files, then shows everything biggest first. There are three views:
  - **Suggestions** lists known caches and leftovers, tagged *Safe* or *Review*.
  - **Folders** is a size tree you can expand, with items under 20 MB folded into one row.
  - **Large Files** lists every single file over 20 MB.

  Tick what you want gone, then move it to the Trash or delete it permanently.
- **App Uninstaller** lists your installed apps with their sizes. Pick one, or drop any `.app` on the window, and it finds everything that app left around the system: preferences, caches, containers, group containers, saved state, web data, logs, launch agents and daemons, and installer receipts. Review the list, then remove it all in one go.

Nothing is removed until you choose it, and every removal is confirmed first. Items you lack permission for can be retried with the standard macOS administrator prompt.

Requires macOS 14 Sonoma or later. Universal binary (Apple silicon and Intel).

## Install

1. Download `Clearspace-<version>.dmg` from [Releases](../../releases), open it, and drag **Clearspace** into **Applications**.
2. The app is ad-hoc signed, not notarized. The first time, right-click it in Applications and choose **Open**, then **Open** again. If macOS still refuses, run:
   ```sh
   xattr -dr com.apple.quarantine /Applications/Clearspace.app
   ```
3. Recommended: give it **Full Disk Access** (System Settings › Privacy & Security › Full Disk Access). Without it, macOS hides Mail, Safari, other apps' data and the Trash, and may ask for permission several times during a scan. The app shows a shortcut to this setting.

Because the app is ad-hoc signed, macOS ties its permissions to that exact build. After installing a new version, turn Full Disk Access off and on again for it.

## Safety

**Disk Cleaner** refuses to touch:
- Your Home folder itself, or top-level folders such as Documents, Desktop, Library, Library/Caches and Containers
- Anything inside Keychains or `~/.ssh`
- Anything outside the scanned folders
- Clearspace itself

Selecting `~/.Trash` empties it instead of moving it.

**App Uninstaller** matches files by the app's bundle identifier (`com.vendor.app`) or by its name as a whole word. This means "Paste" never matches "PasteBar".
- Items that match **only by name** are marked *Name match* and start unticked, so you check them first.
- It never looks inside other apps' sandboxes, iCloud Drive, cloud storage, Mail or Messages.
- It never lists a top-level Library folder.
- It won't remove apps that ship with macOS.

Moving to the Trash is the default and can be undone with *Put Back*.

## Build from source

Needs only the Xcode Command Line Tools (`xcode-select --install`).

```sh
scripts/build.sh              # dist/Clearspace.app + dist/Clearspace-<version>.dmg
scripts/build.sh --app-only   # just the app
ARCHS=arm64 scripts/build.sh  # one architecture, faster
swift test                    # unit tests (Swift Testing)
```

The build script compiles release binaries for each architecture and merges them with `lipo`. It renders the icon and DMG background with `scripts/artwork.swift`, signs ad-hoc, and packages the DMG. For the styled drag-to-Applications window it uses [dmgbuild](https://github.com/dmgbuild/dmgbuild), installed into `.build/` on first run. Without network access it falls back to a plain DMG.

The version comes from `CFBundleShortVersionString` in `Support/Info.plist`.

## Layout

```
Sources/Clearspace/
  App/           app entry, window, sidebar, menu commands
  Core/          file-system helpers, removal (Trash / delete / admin retry), storage info
  DiskCleaner/   scanner, suggestion catalogue, safety guard, model and views
  Uninstaller/   app catalogue, leftover finder, model and views
  UI/            shared components and the removal progress panel
  Debug/         snapshot driver for checking layouts (debug builds only)
Tests/           scanner, leftover finder, safety guard and remover tests
scripts/         build, artwork and DMG settings
legacy/          the original Python disk cleaner and shell uninstaller this app replaces
```
