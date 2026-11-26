import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case cleaner, uninstaller

    var id: Self { self }

    var title: String {
        switch self {
        case .cleaner: "Disk Cleaner"
        case .uninstaller: "App Uninstaller"
        }
    }

    var symbol: String {
        switch self {
        case .cleaner: "internaldrive"
        case .uninstaller: "xmark.app"
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .cleaner: "1"
        case .uninstaller: "2"
        }
    }
}

/// Top-level modes, like Arc's spaces. Each brings its own sidebar and tint; switch with ⌃1/⌃2,
/// the dots at the bottom of the sidebar, or a two-finger swipe on the sidebar.
enum Space: String, CaseIterable, Identifiable {
    case clean, terminal

    var id: Self { self }

    var title: String {
        switch self {
        case .clean: "Clean"
        case .terminal: "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .clean: "sparkles"
        case .terminal: "terminal"
        }
    }

    var tint: Color {
        switch self {
        case .clean: .teal
        case .terminal: .purple
        }
    }

    var shortcut: KeyEquivalent {
        switch self {
        case .clean: "1"
        case .terminal: "2"
        }
    }
}

@MainActor @Observable
final class AppModel {
    var space: Space = Space(rawValue: UserDefaults.standard.string(forKey: "space") ?? "") ?? .clean {
        didSet {
            UserDefaults.standard.set(space.rawValue, forKey: "space")
            let all = Space.allCases
            spaceDirection = (all.firstIndex(of: space) ?? 0) >= (all.firstIndex(of: oldValue) ?? 0) ? 1 : -1
        }
    }
    /// +1 when the last switch went to a later space, −1 to an earlier one (drives the detail's slide-in side).
    private(set) var spaceDirection = 1
    /// Live two-finger swipe over the sidebar, in sidebar widths (negative = fingers moving left, toward the next space).
    var swipeProgress: CGFloat = 0
    var tool: Tool = .cleaner
    private(set) var storage = StorageInfo.current()
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess()
    let cleaner = DiskCleanerModel()
    let uninstaller = UninstallerModel()
    let terminal = TerminalModel()

    static let spaceAnimation = Animation.spring(response: 0.42, dampingFraction: 0.86)

    /// Every space change goes through here so clicks, shortcuts and swipes share one spring.
    func go(to space: Space) {
        withAnimation(Self.spaceAnimation) {
            self.space = space
            swipeProgress = 0
        }
    }

    func show(_ tool: Tool) {
        go(to: .clean)
        self.tool = tool
    }

    func showSpace(offset: Int) {
        let all = Space.allCases
        let index = all.firstIndex(of: space) ?? 0
        go(to: all[(index + offset + all.count) % all.count])
    }

    init() {
        cleaner.onFilesRemoved = { [weak self] in self?.refresh() }
        uninstaller.onFilesRemoved = { [weak self] in self?.refresh() }
    }

    func refresh() {
        storage = .current()
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }
}
