import SwiftTerm
import SwiftUI

// MARK: - Sidebar

/// Sidebar content for the Terminal space: Pinned, then each group, then loose tabs.
struct TerminalSidebar: View {
    @Environment(TerminalModel.self) private var model

    var body: some View {
        let ws = model.workspace
        List(selection: selection) {
            let pinned = ws.tabs(in: .pinned)
            if !pinned.isEmpty {
                Section("Pinned") {
                    ForEach(pinned) { TabRow(tab: $0) }
                        .onMove { model.moveTabs(in: .pinned, from: $0, to: $1) }
                }
            }
            ForEach(ws.groups) { group in
                Section(isExpanded: expanded(group.id)) {
                    ForEach(ws.tabs(in: .group(group.id))) { TabRow(tab: $0) }
                        .onMove { model.moveTabs(in: .group(group.id), from: $0, to: $1) }
                } header: {
                    GroupHeader(group: group)
                }
            }
            Section(ws.groups.isEmpty && pinned.isEmpty ? "Tabs" : "Other Tabs") {
                ForEach(ws.tabs(in: .loose)) { TabRow(tab: $0) }
                    .onMove { model.moveTabs(in: .loose, from: $0, to: $1) }
                Button { model.newTab(inGroup: nil) } label: {
                    Label("New Tab", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("New tab (⌘T)")
            }
        }
        .contextMenu {
            Button("New Tab") { model.newTab() }
            Button("New Group…") { model.editing = .newGroup(movingTab: nil) }
        }
    }

    private var selection: Binding<UUID?> {
        Binding(get: { model.selectedTabID }, set: { model.selectedTabID = $0 })
    }

    private func expanded(_ id: UUID) -> Binding<Bool> {
        Binding(get: { model.group(id)?.isExpanded ?? true }, set: { model.setExpanded($0, group: id) })
    }
}

private struct TabRow: View {
    @Environment(TerminalModel.self) private var model
    let tab: TerminalTab
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            ColorDot(color: model.color(of: tab))
            VStack(alignment: .leading, spacing: 1) {
                Text(model.title(of: tab))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            if hovering {
                Button { model.close(tab.id) } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .help("Close tab")
            } else if tab.startupCommand != nil {
                Image(systemName: "bolt.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Runs “\(tab.startupCommand ?? "")” when it starts")
            }
        }
        .padding(.vertical, 2)
        .tag(tab.id)
        .onHover { hovering = $0 }
        .contextMenu { TabMenu(tab: tab) }
    }

    private var subtitle: String {
        if let code = model.exited[tab.id] { return "Exited" + (code.map { " (\($0))" } ?? "") }
        return TerminalModel.abbreviated(tab.directory)
    }
}

private struct TabMenu: View {
    @Environment(TerminalModel.self) private var model
    let tab: TerminalTab

    var body: some View {
        Button("Rename…") { model.editing = .renameTab(tab.id) }
        Button("Startup Command…") { model.editing = .startupCommand(tab.id) }
        Menu("Color") {
            Button("Group Color") { model.setColor(nil, forTab: tab.id) }
            Divider()
            ForEach(TabColor.allCases) { color in
                Button { model.setColor(color, forTab: tab.id) } label: { ColorMenuLabel(color: color) }
            }
        }
        Menu("Move to Group") {
            ForEach(model.workspace.groups) { group in
                Button(group.name) { model.move(tab.id, toGroup: group.id) }
                    .disabled(group.id == tab.groupID && !tab.isPinned)
            }
            if !model.workspace.groups.isEmpty { Divider() }
            Button("New Group…") { model.editing = .newGroup(movingTab: tab.id) }
            if tab.groupID != nil {
                Button("Remove from Group") { model.move(tab.id, toGroup: nil) }
            }
        }
        Button(tab.isPinned ? "Unpin" : "Pin") { model.togglePin(tab.id) }
        Divider()
        Button("Duplicate") { model.duplicate(tab.id) }
        Button("Reveal in Finder") { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: tab.directory) }
        Divider()
        Button("Close Tab") { model.close(tab.id) }
    }
}

private struct GroupHeader: View {
    @Environment(TerminalModel.self) private var model
    let group: TerminalGroup

    var body: some View {
        HStack(spacing: 6) {
            ColorDot(color: group.color)
            Text(group.name)
            Spacer()
            Button { model.newTab(inGroup: group.id) } label: { Image(systemName: "plus") }
                .buttonStyle(.borderless)
                .help("New tab in \(group.name)")
        }
        .contextMenu {
            Button("New Tab in Group") { model.newTab(inGroup: group.id) }
            Button("Rename…") { model.editing = .renameGroup(group.id) }
            Menu("Color") {
                ForEach(TabColor.allCases) { color in
                    Button { model.setColor(color, forGroup: group.id) } label: { ColorMenuLabel(color: color) }
                }
            }
            Button(group.directory == nil ? "Set Start Folder…" : "Change Start Folder…") { model.chooseDirectory(forGroup: group.id) }
            if group.directory != nil {
                Button("Clear Start Folder") { model.setDirectory(nil, forGroup: group.id) }
            }
            Divider()
            Button("Ungroup Tabs") { model.deleteGroup(group.id, closingTabs: false) }
            Button("Close Group and Its Tabs") { model.deleteGroup(group.id, closingTabs: true) }
        }
    }
}

struct ColorDot: View {
    let color: TabColor?

    var body: some View {
        Circle()
            .fill(color?.color ?? Color.secondary.opacity(0.35))
            .frame(width: 8, height: 8)
    }
}

private struct ColorMenuLabel: View {
    let color: TabColor

    var body: some View {
        // Menus render SF Symbols, not custom shapes, so the swatch is a tinted circle symbol.
        Label {
            Text(color.title)
        } icon: {
            Image(systemName: "circle.fill").foregroundStyle(color.color)
        }
    }
}

// MARK: - Detail

struct TerminalSpaceView: View {
    @Environment(TerminalModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        @Bindable var model = model
        Group {
            if let tab = model.selectedTab {
                VStack(spacing: 0) {
                    TerminalHost(session: model.session(for: tab.id))
                    if let code = model.exited[tab.id] {
                        ExitedBar(code: code) { model.restart(tab.id) }
                    }
                }
                .navigationTitle(model.title(of: tab))
                .navigationSubtitle(TerminalModel.abbreviated(tab.directory))
            } else {
                ContentUnavailableView {
                    Label("No Tabs", systemImage: "terminal")
                } description: {
                    Text("Open a tab to start a shell. Tabs, groups and colors come back after you quit or restart.")
                } actions: {
                    Button("New Tab") { model.newTab() }
                        .keyboardShortcut(.defaultAction)
                }
                .navigationTitle("Terminal")
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.editing = .newGroup(movingTab: nil) } label: {
                    Label("New Group", systemImage: "folder.badge.plus")
                }
                .help("New group")
                Button { model.newTab() } label: {
                    Label("New Tab", systemImage: "plus")
                }
                .help("New tab (⌘T)")
            }
        }
        .sheet(item: $model.editing) { TerminalEditSheet(edit: $0) }
        .onAppear { model.setAppearance(dark: colorScheme == .dark) }
        .onChange(of: colorScheme) { _, scheme in model.setAppearance(dark: scheme == .dark) }
    }
}

private struct ExitedBar: View {
    let code: Int32?
    let restart: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "stop.circle").foregroundStyle(.secondary)
            Text("Shell exited" + (code.map { " with code \($0)" } ?? ""))
            Spacer()
            Button("Restart", action: restart)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.bar)
    }
}

/// Hosts the selected tab's SwiftTerm view. Swapping tabs swaps the subview, so the other shells keep running untouched.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(session, to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard container.subviews.first !== session.view else { return }
        attach(session, to: container)
    }

    private func attach(_ session: TerminalSession, to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let view = session.view
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
    }
}

// MARK: - Dialogs

private struct TerminalEditSheet: View {
    @Environment(TerminalModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let edit: TerminalEdit
    @State private var text = ""
    @State private var color: TabColor = .blue

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .font(isCommand ? .body.monospaced() : .body)
                .onSubmit(commit)
            if case .newGroup = edit {
                HStack(spacing: 8) {
                    ForEach(TabColor.allCases) { option in
                        Button { color = option } label: {
                            Circle()
                                .fill(option.color)
                                .frame(width: 18, height: 18)
                                .overlay(Circle().strokeBorder(.primary.opacity(option == color ? 0.8 : 0), lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(option.title)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: commit)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear(perform: load)
    }

    private var isCommand: Bool { if case .startupCommand = edit { true } else { false } }

    private var title: String {
        switch edit {
        case .renameTab: "Rename Tab"
        case .startupCommand: "Startup Command"
        case .newGroup: "New Group"
        case .renameGroup: "Rename Group"
        }
    }

    private var message: String? {
        switch edit {
        case .startupCommand: "Runs each time this tab's shell starts, including after you quit or restart your Mac. Leave empty for none."
        case .renameTab: "Leave empty to show the folder name."
        default: nil
        }
    }

    private var placeholder: String {
        switch edit {
        case .startupCommand: "pnpm dev"
        case .renameTab: "Tab name"
        default: "Group name"
        }
    }

    private var confirmTitle: String {
        if case .newGroup = edit { return "Create" }
        return "Save"
    }

    private func load() {
        switch edit {
        case .renameTab(let id): text = model.tab(id)?.name ?? ""
        case .startupCommand(let id): text = model.tab(id)?.startupCommand ?? ""
        case .renameGroup(let id): text = model.group(id)?.name ?? ""
        case .newGroup:
            let used = Set(model.workspace.groups.map(\.color))
            color = TabColor.allCases.first { !used.contains($0) && $0 != .gray } ?? .blue
        }
    }

    private func commit() {
        switch edit {
        case .renameTab(let id): model.rename(id, to: text)
        case .startupCommand(let id): model.setStartupCommand(text, for: id)
        case .renameGroup(let id): model.renameGroup(id, to: text)
        case .newGroup(let tabID): model.newGroup(name: text, color: color, moving: tabID)
        }
        dismiss()
    }
}
