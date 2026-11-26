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
        if let step = ProcessInfo.processInfo.environment["CLEARSPACE_SNAPSHOT_TERMINAL"] {
            runTerminal(model, step: step, dir: dir)
            return
        }
        model.space = .clean
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

    /// Step "setup": builds groups and tabs, runs commands, then quits (which saves).
    /// Step "restore": relaunch with the same CLEARSPACE_TERMINAL_DIR and capture what came back.
    private static func runTerminal(_ model: AppModel, step: String, dir: String) {
        let terminal = model.terminal
        if step == "swipe" {
            runSwipe(model, dir: dir)
            return
        }
        Task { @MainActor in
            model.space = .terminal
            await pause(2.0)
            if step == "setup" {
                let first = terminal.selectedTabID!
                terminal.session(for: first).view.send(txt: "cd /tmp && echo hello-from-first-tab\r")
                let group = terminal.newGroup(name: "skreno", color: .purple)
                let api = terminal.selectedTabID!
                terminal.rename(api, to: "api")
                terminal.setStartupCommand("echo startup-ran-$((40+2))", for: api)
                terminal.newTab(inGroup: group, directory: "/usr/local")
                terminal.setColor(.orange, forTab: terminal.selectedTabID!)
                terminal.newGroup(name: "infra", color: .green)
                terminal.togglePin(first)
                terminal.selectedTabID = first
                await pause(2.5)
                capture("t1-setup-pinned", in: dir)
                terminal.selectedTabID = api
                await pause(1.0)
                capture("t2-setup-group-tab", in: dir)
                model.space = .clean
                await pause(1.0)
                capture("t3-clean-space", in: dir)
                dumpMenus(in: dir)
            } else {
                capture("t4-restored-pinned", in: dir)
                terminal.selectAdjacent(1)
                await pause(1.5)
                capture("t5-restored-api", in: dir)
            }
            NSApp.terminate(nil)
        }
    }

    /// Step "swipe": posts real trackpad scroll events (began → changed… → ended) over the sidebar,
    /// capturing frames mid-drag, mid-spring and settled; then a half swipe that must spring back.
    private static func runSwipe(_ model: AppModel, dir: String) {
        Task { @MainActor in
            model.space = .clean
            await pause(2.0)
            guard let window = NSApp.windows.first(where: \.isVisible) else { return }
            let point = NSPoint(x: 120, y: 300)  // inside the sidebar, window coordinates
            var log: [String] = []
            @MainActor func record(_ label: String) { log.append("\(label): space=\(model.space.rawValue) progress=\(String(format: "%.3f", model.swipeProgress))") }

            // 1. Fingers left 180 pt, quick: should follow, then commit to Terminal.
            post(.began, dx: 0, at: point, in: window)
            for i in 1...12 {
                post(.changed, dx: 15, at: point, in: window)
                await pause(0.016)
                if i == 6 { capture("s1-drag-90pt", in: dir); record("drag 90") }
            }
            capture("s2-drag-180pt", in: dir); record("drag 180")
            post(.ended, dx: 0, at: point, in: window)
            await pause(0.12)
            capture("s3-springing", in: dir); record("springing")
            await pause(1.0)
            capture("s4-settled-terminal", in: dir); record("settled")

            // 2. Slow 60 pt drag back then lift after a pause: too short, must spring back to Terminal.
            post(.began, dx: 0, at: point, in: window)
            for _ in 1...6 { post(.changed, dx: -10, at: point, in: window); await pause(0.03) }
            await pause(0.3)
            record("short drag")
            post(.ended, dx: 0, at: point, in: window)
            await pause(1.0)
            capture("s5-sprang-back", in: dir); record("after short drag")

            // 3. Past the last space: rubber band, then back.
            post(.began, dx: 0, at: point, in: window)
            for _ in 1...10 { post(.changed, dx: 20, at: point, in: window); await pause(0.016) }
            capture("s6-rubber-band", in: dir); record("rubber band")
            post(.ended, dx: 0, at: point, in: window)
            await pause(1.0)
            record("after rubber band")

            // 4. Vertical scroll must not move spaces.
            post(.began, dx: 0, dy: 0, at: point, in: window)
            for _ in 1...10 { post(.changed, dx: 1, dy: -20, at: point, in: window); await pause(0.016) }
            post(.ended, dx: 0, at: point, in: window)
            await pause(0.5)
            record("vertical")
            try? log.joined(separator: "\n").write(toFile: dir + "/swipe.txt", atomically: true, encoding: .utf8)
            NSApp.terminate(nil)
        }
    }

    private enum Phase: Int64 { case began = 1, changed = 2, ended = 4 }

    private static func post(_ phase: Phase, dx: Int32, dy: Int32 = 0, at point: NSPoint, in window: NSWindow) {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase.rawValue)
        cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx))
        cg.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy))
        let screen = window.convertPoint(toScreen: point)
        cg.location = CGPoint(x: screen.x, y: (NSScreen.screens.first?.frame.height ?? 0) - screen.y)
        cg.timestamp = CGEventTimestamp(ProcessInfo.processInfo.systemUptime * 1_000_000_000)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        guard let event = NSEvent(cgEvent: cg) else { return }
        SwipeDebug.feed?(event, window, point)
    }

    private static func dumpMenus(in dir: String) {
        var lines: [String] = []
        for item in NSApp.mainMenu?.items ?? [] {
            for sub in item.submenu?.items ?? [] where !sub.keyEquivalent.isEmpty {
                lines.append("\(item.title) › \(sub.title)  [\(sub.keyEquivalentModifierMask.rawValue)] \(sub.keyEquivalent)")
            }
        }
        try? lines.joined(separator: "\n").write(toFile: dir + "/menus.txt", atomically: true, encoding: .utf8)
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
