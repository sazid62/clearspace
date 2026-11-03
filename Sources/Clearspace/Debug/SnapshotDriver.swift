#if DEBUG
import AppKit

/// Development aid, compiled out of release builds. With CLEARSPACE_SNAPSHOT_DIR set, it walks
/// through the main screens, writes a PNG of the window plus a view-hierarchy dump (frames) for
/// each, then quits. Pair it with CLEARSPACE_SCAN_ROOTS=/some/folder so the scan stays small and
/// triggers no privacy prompts. The dump catches layout overflow a screenshot only shows as blank.
@MainActor
enum SnapshotDriver {
    static func runIfRequested(_ model: AppModel) {
        guard let dir = ProcessInfo.processInfo.environment["CLEARSPACE_SNAPSHOT_DIR"] else { return }
        let appName = ProcessInfo.processInfo.environment["CLEARSPACE_SNAPSHOT_APP"]
        Task { @MainActor in
            await pause(1.5)
            capture("1-cleaner-welcome", in: dir)
            model.cleaner.startScan()
            while model.cleaner.phase != .ready { await pause(0.2) }
            model.cleaner.tab = .folders
            if let first = model.cleaner.treeRows.first, case .item(let node) = first.kind {
                model.cleaner.toggleExpanded(node.path)
                if let child = node.children.first { model.cleaner.setSelected(child.path, size: child.size, true) }
            }
            await pause(1.5)
            capture("2-cleaner-folders", in: dir)
            model.cleaner.tab = .files
            await pause(0.8)
            capture("3-cleaner-files", in: dir)
            model.tool = .uninstaller
            while model.uninstaller.apps.isEmpty { await pause(0.2) }
            await pause(1.0)
            capture("4-uninstaller-empty", in: dir)
            let target = model.uninstaller.apps.first { $0.name == appName } ?? model.uninstaller.apps.first
            model.uninstaller.select(target?.id)
            while model.uninstaller.isSearching { await pause(0.2) }
            await pause(2.0)
            capture("5-uninstaller-app", in: dir)
            NSApp.terminate(nil)
        }
    }

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private static func capture(_ name: String, in dir: String) {
        guard let window = NSApp.windows.first(where: \.isVisible),
              let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir + "/" + name + ".png"))
        var lines: [String] = []
        func dump(_ view: NSView, _ depth: Int) {
            guard depth < 14 else { return }
            lines.append(String(repeating: "  ", count: depth) + "\(type(of: view)) \(view.frame.integral) hidden=\(view.isHidden) alpha=\(view.alphaValue)")
            view.subviews.forEach { dump($0, depth + 1) }
        }
        dump(view, 0)
        try? lines.joined(separator: "\n").write(toFile: dir + "/" + name + ".txt", atomically: true, encoding: .utf8)
    }
}
#endif
