import SwiftUI

struct UninstallerView: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HSplitView {
            AppListPane()
                .frame(minWidth: 250, idealWidth: 290, maxWidth: 400)
            AppDetailPane()
                .frame(minWidth: 480, maxWidth: .infinity)
        }
        .navigationTitle("App Uninstaller")
        .navigationSubtitle(model.isLoadingApps && model.apps.isEmpty ? "Loading apps…" : "\(plural(model.apps.count, "app")) installed")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { model.chooseApp() } label: {
                    Label("Choose App…", systemImage: "plus.app")
                }
                .help("Choose an app from anywhere on your Mac")
                Button { model.reloadApps() } label: {
                    Label("Reload", systemImage: "arrow.clockwise")
                }
                .help("Reload the list of apps")
                .disabled(model.isLoadingApps)
            }
        }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search apps")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { $0.pathExtension.lowercased() == "app" }) else { return false }
            model.open(url)
            return true
        }
        .task { model.loadAppsIfNeeded() }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)) { _ in
            model.refreshRunningState()
        }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            model.refreshRunningState()
        }
        .modifier(RemovalOverlay(host: model))
    }
}

// MARK: - App list

private struct AppListPane: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let apps = model.visibleApps
        VStack(spacing: 0) {
            HStack {
                Text(model.query.isEmpty ? "Applications" : "\(plural(apps.count, "match"))")
                    .font(.headline)
                Spacer()
                Picker("Sort by", selection: $model.sortOrder) {
                    ForEach(AppSortOrder.allCases) { Text("By \($0.rawValue)").tag($0) }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            Divider()
            List(selection: Binding(get: { model.selectedAppID }, set: { model.select($0) })) {
                ForEach(apps) { app in
                    AppRow(app: app, size: model.appSizes[app.path])
                }
            }
            .listStyle(.inset)
            .overlay {
                if model.isLoadingApps && model.apps.isEmpty {
                    ProgressView("Loading apps…")
                } else if apps.isEmpty && !model.query.isEmpty {
                    ContentUnavailableView.search(text: model.query)
                }
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let size: Int64?

    var body: some View {
        HStack(spacing: 10) {
            FileIcon(path: app.path, size: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(app.name).lineLimit(1)
                Text(app.version.map { "Version \($0)" } ?? app.bundleID ?? " ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(size.map(Bytes.format) ?? "—")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .contextMenu { FileMenuItems(path: app.path) }
    }
}

// MARK: - Detail

private struct AppDetailPane: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        if let app = model.inspected {
            AppInspector(app: app)
        } else {
            VStack(spacing: 16) {
                HeroIcon(symbol: "xmark.app")
                Text("Remove an app completely").font(.title2.weight(.semibold))
                Text("Pick an app from the list, or drop one here. Clearspace finds its preferences, caches, containers, launch agents and other leftovers so nothing is left behind.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("Choose App…") { model.chooseApp() }
                    .controlSize(.large)
            }
            .padding(40)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct AppInspector: View {
    let app: InstalledApp
    @Environment(UninstallerModel.self) private var model
    @State private var confirmTrash = false
    @State private var confirmPermanent = false
    @State private var permanentConfirmed = false

    var body: some View {
        VStack(spacing: 0) {
            AppHeader(app: app)
            if model.isAppRunning { RunningBanner(app: app) }
            Divider()
            if model.isSearching {
                ProgressView("Looking for related files…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                LeftoverList()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { actionBar }
        .alert("Uninstall \(app.name)?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) { model.uninstall(.trash) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(plural(model.checked.count, "item")) (\(Bytes.format(model.checkedSize))) will be moved to the Trash. You can put them back from the Trash if you change your mind."
                 + (model.isAppRunning ? "\n\n\(app.name) is still running. Quit it first for a clean removal." : ""))
        }
        .sheet(isPresented: $confirmPermanent, onDismiss: {
            guard permanentConfirmed else { return }
            permanentConfirmed = false
            model.uninstall(.permanent)
        }) {
            PermanentDeleteSheet(appName: app.name, count: model.checked.count, size: model.checkedSize) {
                permanentConfirmed = true
            }
        }
    }

    private var actionBar: some View {
        let count = model.checked.count
        let total = model.leftovers.count
        let disabled = count == 0 || model.isSearching
        return ActionBar {
            Toggle(isOn: Binding(get: { total > 0 && count == total }, set: { model.checkAll($0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(total == 0)
                .help(count == total ? "Deselect all" : "Select all")
            VStack(alignment: .leading, spacing: 1) {
                Text(model.isSearching ? "Searching…" : "\(count) of \(total) selected")
                    .font(.callout.weight(.medium))
                Text(Bytes.format(model.checkedSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .lineLimit(1)
            Spacer(minLength: 8)
            Button("Delete Permanently…", role: .destructive) { confirmPermanent = true }
                .fixedSize()
                .disabled(disabled)
            Button("Move to Trash") { confirmTrash = true }
                .buttonStyle(.borderedProminent)
                .fixedSize()
                .disabled(disabled)
        }
    }
}

private struct AppHeader: View {
    let app: InstalledApp
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            FileIcon(path: app.path, size: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.name).font(.title2.weight(.semibold))
                HStack(spacing: 6) {
                    if let version = app.version { Text("Version \(version)") }
                    if app.version != nil && app.bundleID != nil { Text("·") }
                    if let bundleID = app.bundleID { Text(bundleID).textSelection(.enabled) }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
                } label: {
                    Label(FS.abbreviate(app.path), systemImage: "folder")
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            Spacer()
            if !model.isSearching {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Bytes.format(model.totalSize))
                        .font(.title2.weight(.semibold))
                        .monospacedDigit()
                    Text("\(plural(model.leftovers.count, "item")) found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(20)
    }
}

private struct RunningBanner: View {
    let app: InstalledApp
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(app.name) is running. Quit it before uninstalling so it can't recreate its files.")
                .font(.callout)
            Spacer()
            Button("Quit \(app.name)") { model.quitInspectedApp() }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .background(Color.orange.opacity(0.12))
    }
}

private struct LeftoverList: View {
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        List {
            if model.hasNameMatches {
                Label("Items marked “Name match” only share the app's name, so they start unticked. Check them before removing.",
                      systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.groups) { group in
                Section {
                    ForEach(group.items) { LeftoverRow(item: $0) }
                } header: {
                    HStack {
                        Label(group.kind.title, systemImage: group.kind.symbol)
                        Spacer()
                        Text(Bytes.format(group.items.reduce(0) { $0 + (model.leftoverSizes[$1.path] ?? 0) }))
                            .monospacedDigit()
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

private struct LeftoverRow: View {
    let item: Leftover
    @Environment(UninstallerModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { model.isChecked(item.path) }, set: { model.setChecked(item.path, $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
            FileIcon(path: item.path, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).lineLimit(1).truncationMode(.middle)
                    if item.confidence == .nameOnly {
                        Pill(text: "Name match", color: .orange)
                            .help("Matched by name only, not by the app's identifier")
                    }
                }
                Text(FS.abbreviate((item.path as NSString).deletingLastPathComponent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(model.leftoverSizes[item.path].map(Bytes.format) ?? "…")
                .font(.callout)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
        .contextMenu { FileMenuItems(path: item.path) }
    }
}

private struct PermanentDeleteSheet: View {
    let appName: String
    let count: Int
    let size: Int64
    let onConfirm: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                Text("Delete \(appName) permanently?").font(.title3.weight(.semibold))
            }
            Text("\(plural(count, "item")) (\(Bytes.format(size))) will be erased right away, without going through the Trash. This can't be undone.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Type **\(appName)** to confirm:")
            TextField(appName, text: $typed)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive, action: confirm)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(typed != appName)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 440)
    }

    private func confirm() {
        guard typed == appName else { return }
        onConfirm()
        dismiss()
    }
}
