import Foundation
import SwiftUI

/// A tint for tabs and groups. Stored by name so the saved file stays readable.
enum TabColor: String, Codable, CaseIterable, Identifiable {
    case gray, red, orange, yellow, green, mint, blue, purple, pink

    var id: Self { self }
    var title: String { rawValue.capitalized }

    var color: Color {
        switch self {
        case .gray: .gray
        case .red: .red
        case .orange: .orange
        case .yellow: .yellow
        case .green: .green
        case .mint: .mint
        case .blue: .blue
        case .purple: .purple
        case .pink: .pink
        }
    }
}

struct TerminalGroup: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var color: TabColor
    /// New tabs in this group start here. Nil means "same folder as the current tab".
    var directory: String?
    var isExpanded = true
}

struct TerminalTab: Codable, Identifiable, Equatable {
    var id = UUID()
    /// User-chosen name. Nil shows the folder name instead.
    var name: String?
    /// Nil takes the group's color.
    var color: TabColor?
    var groupID: UUID?
    var isPinned = false
    /// Last known working directory of the shell; the tab reopens here.
    var directory: String
    /// Runs every time the tab's shell starts, including after a restart (e.g. `pnpm dev`).
    var startupCommand: String?
}

/// Everything the Terminal space restores: groups, tabs in sidebar order, and the selection.
struct TerminalWorkspace: Codable, Equatable {
    var groups: [TerminalGroup] = []
    var tabs: [TerminalTab] = []
    var selectedTabID: UUID?
}

/// Where a tab sits in the sidebar. Each tab is in exactly one section.
enum TabSection: Hashable {
    case pinned
    case group(UUID)
    case loose
}

extension TerminalWorkspace {
    func section(of tab: TerminalTab) -> TabSection {
        if tab.isPinned { return .pinned }
        if let groupID = tab.groupID, groups.contains(where: { $0.id == groupID }) { return .group(groupID) }
        return .loose
    }

    func tabs(in section: TabSection) -> [TerminalTab] {
        tabs.filter { self.section(of: $0) == section }
    }

    /// Tabs in the order the sidebar shows them, for next/previous navigation.
    var tabsInSidebarOrder: [TerminalTab] {
        var ordered = tabs(in: .pinned)
        for group in groups { ordered += tabs(in: .group(group.id)) }
        return ordered + tabs(in: .loose)
    }

    /// Reorders tabs inside one section (List `onMove` semantics) and leaves every other tab where it was.
    mutating func moveTabs(in section: TabSection, from source: IndexSet, to destination: Int) {
        let slots = tabs.indices.filter { self.section(of: tabs[$0]) == section }
        var sectionTabs = slots.map { tabs[$0] }
        sectionTabs.move(fromOffsets: source, toOffset: destination)
        for (slot, tab) in zip(slots, sectionTabs) { tabs[slot] = tab }
    }
}

/// Reads and writes the workspace file and each tab's saved scrollback.
struct TerminalStore {
    let directory: URL

    /// `~/Library/Application Support/Clearspace/Terminal`, or `CLEARSPACE_TERMINAL_DIR` when set (tests, snapshots).
    static var standard: TerminalStore {
        if let override = ProcessInfo.processInfo.environment["CLEARSPACE_TERMINAL_DIR"] {
            return TerminalStore(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return TerminalStore(directory: base.appendingPathComponent("Clearspace/Terminal", isDirectory: true))
    }

    /// Lines of scrollback kept per tab.
    static let scrollbackLines = 5000

    private var workspaceURL: URL { directory.appendingPathComponent("workspace.json") }
    private var scrollbackDirectory: URL { directory.appendingPathComponent("scrollback", isDirectory: true) }
    private func scrollbackURL(_ id: UUID) -> URL { scrollbackDirectory.appendingPathComponent(id.uuidString + ".txt") }

    func load() -> TerminalWorkspace? {
        guard let data = try? Data(contentsOf: workspaceURL) else { return nil }
        return try? JSONDecoder().decode(TerminalWorkspace.self, from: data)
    }

    func save(_ workspace: TerminalWorkspace) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(workspace) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: workspaceURL, options: .atomic)
    }

    func loadScrollback(_ id: UUID) -> String? {
        guard let text = try? String(contentsOf: scrollbackURL(id), encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    func saveScrollback(_ text: String, for id: UUID) {
        let trimmed = Self.trimmed(text, maxLines: Self.scrollbackLines)
        if trimmed.isEmpty {
            removeScrollback(id)
            return
        }
        try? FileManager.default.createDirectory(at: scrollbackDirectory, withIntermediateDirectories: true)
        try? trimmed.write(to: scrollbackURL(id), atomically: true, encoding: .utf8)
    }

    func removeScrollback(_ id: UUID) {
        try? FileManager.default.removeItem(at: scrollbackURL(id))
    }

    /// Deletes scrollback files whose tab no longer exists.
    func pruneScrollback(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(at: scrollbackDirectory, includingPropertiesForKeys: nil) else { return }
        for file in files {
            guard let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent), ids.contains(id) else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
        }
    }

    /// Drops trailing blank lines (the unused part of the screen) and keeps the last `maxLines`.
    static func trimmed(_ text: String, maxLines: Int) -> String {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeLast() }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        return lines.joined(separator: "\n")
    }
}
