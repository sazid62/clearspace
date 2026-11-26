import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            ZStack {
                switch model.space {
                case .clean:
                    Group {
                        switch model.tool {
                        case .cleaner: DiskCleanerView()
                        case .uninstaller: UninstallerView()
                        }
                    }
                    .transition(detailTransition)
                case .terminal:
                    TerminalSpaceView()
                        .onAppear { model.terminal.activate() }
                        .transition(detailTransition)
                }
            }
            // While a swipe heads toward another space the page behind it dims and drifts with the fingers.
            .opacity(Double(1 - towardNeighbour * 0.35))
            .offset(x: (model.swipeProgress < 0 ? -32 : 32) * towardNeighbour)
        }
        .frame(minWidth: 1000, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        #if DEBUG
        .task { SnapshotDriver.runIfRequested(model) }
        #endif
    }

    /// 0…1: how far the current swipe has gone toward a space that exists (0 when rubber-banding at an end).
    private var towardNeighbour: CGFloat {
        let all = Space.allCases
        let index = all.firstIndex(of: model.space) ?? 0
        let p = model.swipeProgress
        guard (p < 0 && index < all.count - 1) || (p > 0 && index > 0) else { return 0 }
        return min(abs(p), 1)
    }

    /// The new space's page slides in from the side it came from; the old one just fades.
    private var detailTransition: AnyTransition {
        .asymmetric(
            insertion: .opacity.combined(with: .offset(x: CGFloat(model.spaceDirection) * 60)),
            removal: .opacity
        )
    }
}

/// Arc-style sidebar: every space's sidebar sits side by side and the strip follows a two-finger
/// swipe, rubber-bands at the ends, and springs to the nearest space when the fingers lift.
private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    private var index: Int { Space.allCases.firstIndex(of: model.space) ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shift = shown(model.swipeProgress)
            HStack(spacing: 0) {
                ForEach(Space.allCases) { space in
                    SpacePage(space: space)
                        .frame(width: width)
                        .allowsHitTesting(space == model.space && model.swipeProgress == 0)
                        .accessibilityHidden(space != model.space)
                }
            }
            .offset(x: (shift - CGFloat(index)) * width)
            .frame(width: width, height: geo.size.height, alignment: .leading)
            .clipped()
            .background(SwipeTracker(
                onChange: { model.swipeProgress = $0 / width },
                onEnd: { settle(distance: $0, velocity: $1, width: width) }
            ))
        }
        .background(alignment: .top) {
            // Each space's tint fades in as its page slides into view.
            ZStack {
                ForEach(Space.allCases) { space in
                    LinearGradient(colors: [space.tint.opacity(0.12), .clear], startPoint: .top, endPoint: .center)
                        .opacity(weight(of: space))
                }
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                SpaceSwitcher()
            }
        }
    }

    /// The swipe as drawn, in sidebar widths: free between spaces, rubber-banded past the first and last.
    private func shown(_ progress: CGFloat) -> CGFloat {
        let last = Space.allCases.count - 1
        let pastEdge = (index == 0 && progress > 0) || (index == last && progress < 0)
        guard pastEdge else { return max(-1, min(1, progress)) }
        let d = abs(progress)
        return (progress < 0 ? -1 : 1) * (1 - 1 / (d * 0.55 + 1))  // same curve as iOS scroll views
    }

    private func weight(of space: Space) -> Double {
        let position = CGFloat(index) - shown(model.swipeProgress)
        let i = CGFloat(Space.allCases.firstIndex(of: space) ?? 0)
        return Double(max(0, 1 - abs(position - i)))
    }

    /// Fingers lifted: go to the neighbour if the swipe (plus its flick) passed 40%, else spring back.
    private func settle(distance: CGFloat, velocity: CGFloat, width: CGFloat) {
        let all = Space.allCases
        let projected = distance + velocity * 0.18
        var target = index
        if projected < -width * 0.4, index < all.count - 1 { target += 1 }
        if projected > width * 0.4, index > 0 { target -= 1 }
        model.go(to: all[target])
    }
}

private struct SpacePage: View {
    @Environment(AppModel.self) private var model
    let space: Space

    var body: some View {
        switch space {
        case .clean:
            List(selection: selection) {
                Section("Tools") {
                    ForEach(Tool.allCases) { tool in
                        Label(tool.title, systemImage: tool.symbol)
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
        case .terminal:
            TerminalSidebar()
        }
    }

    private var selection: Binding<Tool?> {
        Binding(get: { model.tool }, set: { if let tool = $0 { model.tool = tool } })
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                    Text(model.storage.volumeName).font(.callout.weight(.medium)).lineLimit(1)
                }
                UsageBar(fraction: model.storage.usedFraction).frame(height: 6)
                Text("\(Bytes.format(model.storage.available)) available of \(Bytes.format(model.storage.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.hasFullDiskAccess {
                Label("Full Disk Access on", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button { Permissions.openFullDiskAccessSettings() } label: {
                    Label("Grant Full Disk Access", systemImage: "exclamationmark.shield.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Lets Clearspace see every folder without repeated permission prompts")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The space buttons at the bottom of the sidebar; the highlight pill glides to the current one.
private struct SpaceSwitcher: View {
    @Environment(AppModel.self) private var model
    @Namespace private var pill

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Space.allCases) { space in
                let selected = model.space == space
                Button { model.go(to: space) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: space.symbol)
                        if selected {
                            Text(space.title)
                                .font(.callout.weight(.medium))
                                .fixedSize()
                                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                        }
                    }
                    .padding(.horizontal, selected ? 10 : 8)
                    .frame(height: 26)
                    .foregroundStyle(selected ? space.tint : .secondary)
                    .background {
                        if selected {
                            Capsule()
                                .fill(space.tint.opacity(0.15))
                                .matchedGeometryEffect(id: "pill", in: pill)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help("\(space.title) (⌃\(space.shortcut.character))")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// Follows a horizontal two-finger trackpad swipe over the sidebar. Reports the finger travel in
/// points (positive = fingers moving right) while it happens, then the travel and speed when the
/// fingers lift. Vertical scrolling passes through to the list untouched.
private struct SwipeTracker: NSViewRepresentable {
    let onChange: (CGFloat) -> Void
    let onEnd: (CGFloat, CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.view = view
        context.coordinator.parent = self
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.parent = self
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        enum Axis { case undecided, horizontal, vertical }

        weak var view: NSView?
        var parent: SwipeTracker?
        private var monitor: Any?
        private var axis = Axis.vertical
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var samples: [(time: TimeInterval, dx: CGFloat)] = []

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                let consume = MainActor.assumeIsolated { self?.handle(event, window: event.window, at: event.locationInWindow) ?? false }
                return consume ? nil : event
            }
            #if DEBUG
            SwipeDebug.feed = { [weak self] event, window, point in _ = self?.handle(event, window: window, at: point) }
            #endif
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        /// True when the event belongs to a horizontal swipe, so the list doesn't scroll as well.
        private func handle(_ event: NSEvent, window: NSWindow?, at location: NSPoint) -> Bool {
            // The coasting that follows a swipe belongs to it.
            if !event.momentumPhase.isEmpty { return axis == .horizontal }

            if event.phase == .began {
                guard event.hasPreciseScrollingDeltas, let view, window === view.window,
                      view.bounds.contains(view.convert(location, from: nil)) else {
                    axis = .vertical
                    return false
                }
                axis = .undecided
                dx = 0; dy = 0; samples = []
            }
            guard axis != .vertical else { return false }

            if event.phase == .changed {
                // Follow the fingers whichever way "natural scrolling" is set.
                let step = event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
                dx += step
                dy += abs(event.scrollingDeltaY)
                samples.append((event.timestamp, step))
                samples.removeAll { event.timestamp - $0.time > 0.1 }
                if axis == .undecided, hypot(dx, dy) > 6 {
                    axis = abs(dx) > dy * 1.2 ? .horizontal : .vertical
                }
                if axis == .horizontal { parent?.onChange(dx) }
                return axis == .horizontal
            }

            if event.phase == .ended || event.phase == .cancelled {
                guard axis == .horizontal else { axis = .vertical; return false }
                samples.removeAll { event.timestamp - $0.time > 0.1 }  // fingers that paused before lifting carry no flick
                var velocity: CGFloat = 0
                if let first = samples.first, event.timestamp - first.time > 0.01 {
                    velocity = samples.reduce(0) { $0 + $1.dx } / CGFloat(event.timestamp - first.time)
                }
                parent?.onEnd(dx, velocity)
                return true  // keep axis = .horizontal so the momentum events that follow are swallowed
            }
            return axis == .horizontal
        }
    }
}

#if DEBUG
/// Lets the snapshot driver push synthetic scroll events through the real swipe logic.
@MainActor enum SwipeDebug {
    static var feed: ((NSEvent, NSWindow, NSPoint) -> Void)?
}
#endif
