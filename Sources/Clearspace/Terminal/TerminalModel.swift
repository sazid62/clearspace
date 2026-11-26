import AppKit
import Observation

/// The Terminal space: groups and tabs (saved to disk on every change) plus one live shell per tab.
@MainActor @Observable
final class TerminalModel {
    private(set) var workspace: TerminalWorkspace
    /// Tabs whose shell has exited, with the exit code.
    private(set) var exited: [UUID: Int32?] = [:]
    /// Drives the rename / startup-command / group dialogs.
    var editing: TerminalEdit?

    @ObservationIgnored private var sessions: [UUID: TerminalSession] = [:]
    @ObservationIgnored private let store: TerminalStore
    @ObservationIgnored private var isActive = false
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var savedScrollback: [UUID: Int] = [:]
    @ObservationIgnored private var restoredAt: Date?

    init(store: TerminalStore = .standard) {
        self.store = store
        if let saved = store.load() {
            workspace = saved
            restoredAt = Self.modificationDate(of: store.directory.appendingPathComponent("workspace.json"))
        } else {
            workspace = TerminalWorkspace()
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveEverything() }
        }
    }

    // MARK: - Lifecycle

    /// Called the first time the Terminal space is shown: starts every tab's shell, so startup
    /// commands (servers, watchers) run, and begins tracking folders.
    func activate() {
        guard !isActive else { return }
        isActive = true
        if workspace.tabs.isEmpty {
            newTab()
        } else {
            for tab in workspace.tabs { _ = session(for: tab.id) }
            if workspace.selectedTabID.flatMap(tab(_:)) == nil { workspace.selectedTabID = workspace.tabsInSidebarOrder.first?.id }
        }
        store.pruneScrollback(keeping: Set(workspace.tabs.map(\.id)))
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self else { return }
                self.refreshDirectories()
                tick += 1
                if tick % 15 == 0 { self.saveScrollback() }  // every ~30 s, so a crash or power cut loses little
            }
        }
    }

    func session(for id: UUID) -> TerminalSession {
        if let existing = sessions[id] { return existing }
        let session = TerminalSession(id: id)
        session.onExit = { [weak self] code in self?.exited[id] = code }
        sessions[id] = session
        if let text = store.loadScrollback(id) {
            session.showRestored(text, savedAt: restoredAt)
        }
        if let tab = tab(id) {
            session.start(directory: tab.directory, startupCommand: tab.startupCommand)
        }
        return session
    }

    func restart(_ id: UUID) {
        guard let tab = tab(id), let session = sessions[id] else { return }
        exited[id] = nil
        session.view.feed(text: "\r\n")
        session.start(directory: tab.directory, startupCommand: tab.startupCommand)
    }

    func setAppearance(dark: Bool) {
        sessions.values.forEach { $0.applyAppearance(dark: dark) }
    }

    // MARK: - Lookup

    func tab(_ id: UUID) -> TerminalTab? { workspace.tabs.first { $0.id == id } }
    func group(_ id: UUID) -> TerminalGroup? { workspace.groups.first { $0.id == id } }

    var selectedTab: TerminalTab? { workspace.selectedTabID.flatMap(tab(_:)) }

    var selectedTabID: UUID? {
        get { workspace.selectedTabID }
        set { if newValue != nil { update { $0.selectedTabID = newValue } } }
    }

    /// The tab's own name, else its folder. Shell-set titles (oh-my-zsh's "user@host:path") are ignored: too long for a sidebar.
    func title(of tab: TerminalTab) -> String {
        if let name = tab.name, !name.isEmpty { return name }
        return Self.folderName(tab.directory)
    }

    func color(of tab: TerminalTab) -> TabColor? {
        tab.color ?? tab.groupID.flatMap(group(_:))?.color
    }

    // MARK: - Tabs

    /// Opens a tab next to the current one: same group, starting in the group's folder or the current tab's folder.
    func newTab(inGroup groupID: UUID? = nil, directory: String? = nil) {
        let current = selectedTab
        let targetGroup = groupID ?? (current?.isPinned == false ? current?.groupID : nil)
        let folder = directory
            ?? targetGroup.flatMap(group(_:))?.directory
            ?? current.flatMap { sessions[$0.id]?.currentDirectory ?? $0.directory }
            ?? NSHomeDirectory()
        let tab = TerminalTab(groupID: targetGroup, directory: folder)
        update {
            if let current, let index = $0.tabs.firstIndex(where: { $0.id == current.id }), $0.section(of: current) == $0.section(of: tab) {
                $0.tabs.insert(tab, at: index + 1)
            } else {
                $0.tabs.append(tab)
            }
            $0.selectedTabID = tab.id
        }
        _ = session(for: tab.id)
    }

    func duplicate(_ id: UUID) {
        guard let original = tab(id) else { return }
        var copy = original
        copy.id = UUID()
        copy.directory = sessions[id]?.currentDirectory ?? original.directory
        update {
            let index = $0.tabs.firstIndex { $0.id == id } ?? $0.tabs.count - 1
            $0.tabs.insert(copy, at: index + 1)
            $0.selectedTabID = copy.id
        }
        _ = session(for: copy.id)
    }

    func close(_ id: UUID) {
        let order = workspace.tabsInSidebarOrder.map(\.id)
        sessions.removeValue(forKey: id)?.terminate()
        store.removeScrollback(id)
        exited[id] = nil
        update {
            $0.tabs.removeAll { $0.id == id }
            if $0.selectedTabID == id {
                let remaining = order.filter { $0 != id }
                let position = order.firstIndex(of: id) ?? 0
                $0.selectedTabID = remaining.isEmpty ? nil : remaining[min(position, remaining.count - 1)]
            }
        }
    }

    func closeSelected() {
        if let id = workspace.selectedTabID { close(id) }
    }

    func selectAdjacent(_ step: Int) {
        let order = workspace.tabsInSidebarOrder.map(\.id)
        guard !order.isEmpty else { return }
        let current = workspace.selectedTabID.flatMap { order.firstIndex(of: $0) } ?? 0
        let next = (current + step + order.count) % order.count
        selectedTabID = order[next]
    }

    func rename(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTab(id) { $0.name = trimmed.isEmpty ? nil : trimmed }
    }

    func setColor(_ color: TabColor?, forTab id: UUID) { updateTab(id) { $0.color = color } }
    func togglePin(_ id: UUID) { updateTab(id) { $0.isPinned.toggle() } }

    func setStartupCommand(_ command: String, for id: UUID) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        updateTab(id) { $0.startupCommand = trimmed.isEmpty ? nil : trimmed }
    }

    func move(_ id: UUID, toGroup groupID: UUID?) {
        updateTab(id) {
            $0.groupID = groupID
            $0.isPinned = false
        }
    }

    func moveTabs(in section: TabSection, from source: IndexSet, to destination: Int) {
        update { $0.moveTabs(in: section, from: source, to: destination) }
    }

    // MARK: - Groups

    @discardableResult
    func newGroup(name: String, color: TabColor, moving tabID: UUID? = nil) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let group = TerminalGroup(name: trimmed.isEmpty ? "Group \(workspace.groups.count + 1)" : trimmed, color: color)
        update { $0.groups.append(group) }
        if let tabID { move(tabID, toGroup: group.id) } else { newTab(inGroup: group.id) }
        return group.id
    }

    func renameGroup(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        updateGroup(id) { $0.name = trimmed }
    }

    func setColor(_ color: TabColor, forGroup id: UUID) { updateGroup(id) { $0.color = color } }

    func setDirectory(_ directory: String?, forGroup id: UUID) { updateGroup(id) { $0.directory = directory } }

    func setExpanded(_ expanded: Bool, group id: UUID) { updateGroup(id) { $0.isExpanded = expanded } }

    /// Removes the group. Its tabs either stay open as loose tabs or close with it.
    func deleteGroup(_ id: UUID, closingTabs: Bool) {
        let members = workspace.tabs.filter { $0.groupID == id && !$0.isPinned }.map(\.id)
        if closingTabs { members.forEach(close) }
        update {
            $0.groups.removeAll { $0.id == id }
            for index in $0.tabs.indices where $0.tabs[index].groupID == id { $0.tabs[index].groupID = nil }
        }
    }

    func chooseDirectory(forGroup id: UUID) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use Folder"
        panel.message = "New tabs in this group start in this folder"
        if let current = group(id)?.directory { panel.directoryURL = URL(fileURLWithPath: current) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDirectory(url.path, forGroup: id)
    }

    // MARK: - Saving

    private func update(_ change: (inout TerminalWorkspace) -> Void) {
        var copy = workspace
        change(&copy)
        guard copy != workspace else { return }
        workspace = copy
        store.save(copy)
    }

    private func updateTab(_ id: UUID, _ change: (inout TerminalTab) -> Void) {
        update { ws in
            guard let index = ws.tabs.firstIndex(where: { $0.id == id }) else { return }
            change(&ws.tabs[index])
        }
    }

    private func updateGroup(_ id: UUID, _ change: (inout TerminalGroup) -> Void) {
        update { ws in
            guard let index = ws.groups.firstIndex(where: { $0.id == id }) else { return }
            change(&ws.groups[index])
        }
    }

    /// Records where each shell is now, so tabs reopen in the same folder.
    private func refreshDirectories() {
        update { ws in
            for index in ws.tabs.indices {
                if let cwd = sessions[ws.tabs[index].id]?.currentDirectory { ws.tabs[index].directory = cwd }
            }
        }
    }

    private func saveScrollback() {
        for (id, session) in sessions {
            let text = session.scrollbackText
            let hash = text.hashValue
            guard savedScrollback[id] != hash else { continue }
            savedScrollback[id] = hash
            store.saveScrollback(text, for: id)
        }
    }

    /// On quit (including a restart or shutdown): save folders, layout and scrollback.
    func saveEverything() {
        guard isActive else { return }
        refreshDirectories()
        saveScrollback()
        store.save(workspace)
    }

    // MARK: - Helpers

    static func folderName(_ path: String) -> String {
        if path == NSHomeDirectory() { return "~" }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private static func modificationDate(of url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

/// A pending dialog in the Terminal space.
enum TerminalEdit: Identifiable {
    case renameTab(UUID)
    case startupCommand(UUID)
    case newGroup(movingTab: UUID?)
    case renameGroup(UUID)

    var id: String {
        switch self {
        case .renameTab(let id): "rename-\(id)"
        case .startupCommand(let id): "startup-\(id)"
        case .newGroup(let id): "group-\(id?.uuidString ?? "new")"
        case .renameGroup(let id): "rename-group-\(id)"
        }
    }
}
