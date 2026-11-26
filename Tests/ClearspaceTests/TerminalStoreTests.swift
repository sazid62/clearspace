import Foundation
import Testing
@testable import Clearspace

struct TerminalStoreTests {
    private func workspace() -> TerminalWorkspace {
        let group = TerminalGroup(name: "skreno", color: .purple, directory: "/tmp")
        return TerminalWorkspace(
            groups: [group],
            tabs: [
                TerminalTab(name: "api", color: .green, groupID: group.id, directory: "/tmp/api", startupCommand: "pnpm dev"),
                TerminalTab(directory: "/tmp/loose-1"),
                TerminalTab(groupID: group.id, directory: "/tmp/web"),
                TerminalTab(isPinned: true, directory: "/tmp/pinned"),
                TerminalTab(directory: "/tmp/loose-2"),
            ]
        )
    }

    @Test func savesAndLoadsTheWholeWorkspace() throws {
        let tree = try TempTree()
        let store = TerminalStore(directory: URL(fileURLWithPath: tree.root + "/Terminal"))
        #expect(store.load() == nil)

        var ws = workspace()
        ws.selectedTabID = ws.tabs[2].id
        store.save(ws)
        // A fresh store (as after a restart) reads back the same groups, tabs, colors, order and selection.
        let loaded = try #require(TerminalStore(directory: store.directory).load())
        #expect(loaded == ws)
        #expect(loaded.tabs[0].startupCommand == "pnpm dev")
        #expect(loaded.groups[0].color == .purple)
    }

    @Test func groupsTabsIntoSections() {
        let ws = workspace()
        let group = ws.groups[0].id
        #expect(ws.tabs(in: .pinned).map(\.directory) == ["/tmp/pinned"])
        #expect(ws.tabs(in: .group(group)).map(\.directory) == ["/tmp/api", "/tmp/web"])
        #expect(ws.tabs(in: .loose).map(\.directory) == ["/tmp/loose-1", "/tmp/loose-2"])
        #expect(ws.tabsInSidebarOrder.map(\.directory) == ["/tmp/pinned", "/tmp/api", "/tmp/web", "/tmp/loose-1", "/tmp/loose-2"])
    }

    @Test func tabOfDeletedGroupFallsBackToLoose() {
        var ws = workspace()
        ws.groups = []
        #expect(ws.tabs(in: .loose).count == 4)
    }

    @Test func reorderingOneSectionLeavesOthersInPlace() {
        var ws = workspace()
        let group = ws.groups[0].id
        ws.moveTabs(in: .group(group), from: IndexSet(integer: 1), to: 0)
        #expect(ws.tabs(in: .group(group)).map(\.directory) == ["/tmp/web", "/tmp/api"])
        #expect(ws.tabs(in: .loose).map(\.directory) == ["/tmp/loose-1", "/tmp/loose-2"])
        #expect(ws.tabs.map(\.directory) == ["/tmp/web", "/tmp/loose-1", "/tmp/api", "/tmp/pinned", "/tmp/loose-2"])
    }

    @Test func scrollbackKeepsTheTailAndDropsBlankScreenRows() throws {
        let tree = try TempTree()
        let store = TerminalStore(directory: URL(fileURLWithPath: tree.root))
        let id = UUID()
        let lines = (1...6000).map { "line \($0)" }.joined(separator: "\n") + "\n\n   \n\n"
        store.saveScrollback(lines, for: id)
        let saved = try #require(store.loadScrollback(id)).components(separatedBy: "\n")
        #expect(saved.count == TerminalStore.scrollbackLines)
        #expect(saved.first == "line 1001")
        #expect(saved.last == "line 6000")

        store.saveScrollback("\n  \n", for: id)
        #expect(store.loadScrollback(id) == nil)
    }

    @Test func pruneRemovesScrollbackOfClosedTabs() throws {
        let tree = try TempTree()
        let store = TerminalStore(directory: URL(fileURLWithPath: tree.root))
        let kept = UUID(), closed = UUID()
        store.saveScrollback("keep", for: kept)
        store.saveScrollback("gone", for: closed)
        store.pruneScrollback(keeping: [kept])
        #expect(store.loadScrollback(kept) == "keep")
        #expect(store.loadScrollback(closed) == nil)
    }

    @Test func readsAProcessWorkingDirectory() throws {
        let tree = try TempTree()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        process.currentDirectoryURL = URL(fileURLWithPath: tree.root)
        try process.run()
        defer { process.terminate() }
        let cwd = TerminalSession.workingDirectory(of: process.processIdentifier)
        #expect(cwd == tree.root)
    }
}
