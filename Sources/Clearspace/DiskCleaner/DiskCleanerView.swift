import SwiftUI

struct DiskCleanerView: View {
    @Environment(DiskCleanerModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .idle: CleanerWelcomeView()
            case .scanning: ScanProgressView()
            case .ready: CleanerResultsView()
            }
        }
        .navigationTitle("Disk Cleaner")
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.startScan() } label: {
                    Label("Scan Again", systemImage: "arrow.clockwise")
                }
                .help("Scan your disk again")
                .disabled(model.phase != .ready || model.removal != nil)
            }
        }
        .modifier(RemovalOverlay(host: model))
    }

    private var subtitle: String {
        switch model.phase {
        case .idle:
            return "Find what's using your disk"
        case .scanning:
            return "Scanning…"
        case .ready:
            guard let summary = model.summary else { return "" }
            let took = Duration.seconds(summary.duration).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
            return "\(Bytes.format(summary.total)) in \(plural(summary.files, "file")) · scanned in \(took)"
        }
    }
}

// MARK: - Welcome

private struct CleanerWelcomeView: View {
    @Environment(DiskCleanerModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        HeroIcon(symbol: "sparkles")
                        Text("See what's filling your disk")
                            .font(.title.weight(.semibold))
                        Text("Clearspace measures your Home folder, Applications and temporary files, then lists everything biggest first. Nothing is removed until you pick it.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 470)
                    }
                    StorageCard(storage: app.storage)
                        .frame(maxWidth: 520)
                    HStack(spacing: 10) {
                        ScopeChip(symbol: "house", title: "Home folder")
                        ScopeChip(symbol: "square.grid.2x2", title: "Applications")
                        ScopeChip(symbol: "clock.arrow.circlepath", title: "Temporary files")
                    }
                    Button { model.startScan() } label: {
                        Label("Start Scan", systemImage: "magnifyingglass")
                            .frame(minWidth: 150)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    if !app.hasFullDiskAccess {
                        FullDiskAccessCallout().frame(maxWidth: 520)
                    }
                }
                .padding(40)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
        }
    }
}

private struct ScopeChip: View {
    let symbol: String
    let title: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.05), in: Capsule())
    }
}

// MARK: - Scanning

private struct ScanProgressView: View {
    @Environment(DiskCleanerModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            ProgressView().controlSize(.large)
            VStack(spacing: 6) {
                Text("Scanning your disk…").font(.title3.weight(.semibold))
                Text("\(model.scannedFiles.formatted()) files checked")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Text(FS.abbreviate(model.scanningPath))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 460, minHeight: 16)
            Button("Cancel") { model.cancelScan() }
                .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Results

private struct CleanerResultsView: View {
    @Environment(DiskCleanerModel.self) private var model
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Picker("View", selection: $model.tab) {
                    ForEach(CleanerTab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
                CompactStorage(storage: app.storage)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            Divider()
            Group {
                switch model.tab {
                case .suggestions: SuggestionsList()
                case .folders: FoldersList()
                case .files: LargeFilesList()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { CleanerActionBar() }
        .searchable(text: $model.query, placement: .toolbar, prompt: "Filter by name or path")
    }
}

private struct CompactStorage: View {
    let storage: StorageInfo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("\(Bytes.format(storage.available)) available of \(Bytes.format(storage.total))")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                UsageBar(fraction: storage.usedFraction).frame(width: 180, height: 5)
            }
        }
    }
}

private struct SuggestionsList: View {
    @Environment(DiskCleanerModel.self) private var model

    var body: some View {
        let items = model.visibleSuggestions
        let largest = Double(max(items.first?.size ?? 1, 1))
        VStack(spacing: 0) {
            ListHint(text: "Known caches and leftovers. Items marked Safe come back on their own when needed. Quit Chrome or Brave before removing theirs.") {
                if model.safeSuggestionsSize > 0 {
                    Button("Select All Safe (\(Bytes.format(model.safeSuggestionsSize)))") { model.selectSafeSuggestions() }
                }
            }
            Divider()
            List(items) { suggestion in
                CleanerRow(item: CleanerItem(path: suggestion.path, size: suggestion.size, title: suggestion.title,
                                             subtitle: FS.abbreviate(suggestion.path), note: suggestion.note,
                                             safety: suggestion.safety, fraction: Double(suggestion.size) / largest))
            }
            .listStyle(.inset)
            .overlay {
                if items.isEmpty {
                    if model.query.isEmpty {
                        ContentUnavailableView("Nothing to suggest", systemImage: "checkmark.seal",
                                               description: Text("No known caches or leftovers over 20 MB were found. Try the Folders and Large Files views."))
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
        }
    }
}

private struct FoldersList: View {
    @Environment(DiskCleanerModel.self) private var model

    var body: some View {
        let searching = !model.query.isEmpty
        let matches = searching ? model.folderMatches : []
        let largest = Double(max(matches.first?.size ?? 1, 1))
        VStack(spacing: 0) {
            ListHint(text: searching
                     ? "Folders and files over 20 MB whose name matches."
                     : "Everything is sorted biggest first. Open a folder to look inside; items under 20 MB are grouped as small items.")
            Divider()
            List {
                if searching {
                    ForEach(matches) { node in
                        CleanerRow(item: CleanerItem(node: node, fraction: Double(node.size) / largest,
                                                     subtitle: FS.abbreviate((node.path as NSString).deletingLastPathComponent)))
                    }
                } else {
                    ForEach(model.treeRows) { TreeRowView(row: $0) }
                }
            }
            .listStyle(.inset)
            .overlay {
                if searching && matches.isEmpty { ContentUnavailableView.search(text: model.query) }
            }
        }
    }
}

private struct TreeRowView: View {
    @Environment(DiskCleanerModel.self) private var model
    let row: TreeRow

    var body: some View {
        switch row.kind {
        case .item(let node):
            CleanerRow(item: CleanerItem(node: node, fraction: row.fraction,
                                         subtitle: row.depth == 0 ? FS.abbreviate(node.path) : nil),
                       depth: row.depth, disclosure: disclosure(for: node))
        case .smallItems(let size):
            SmallItemsRow(size: size, depth: row.depth, fraction: row.fraction)
        }
    }

    private func disclosure(for node: FSNode) -> Disclosure {
        guard node.isDirectory, !node.children.isEmpty || node.smallItems > 0 else { return .leaf }
        return model.isExpanded(node.path) ? .expanded : .collapsed
    }
}

private struct LargeFilesList: View {
    @Environment(DiskCleanerModel.self) private var model

    var body: some View {
        let files = model.visibleFiles
        let largest = Double(max(files.first?.size ?? 1, 1))
        VStack(spacing: 0) {
            ListHint(text: "Single files over 20 MB, biggest first.")
            Divider()
            List(files) { file in
                CleanerRow(item: CleanerItem(path: file.path, size: file.size, title: file.name,
                                             subtitle: "\(FS.abbreviate((file.path as NSString).deletingLastPathComponent)) · modified \(file.modified.formatted(.relative(presentation: .named)))",
                                             fraction: Double(file.size) / largest))
            }
            .listStyle(.inset)
            .overlay {
                if files.isEmpty {
                    if model.query.isEmpty {
                        ContentUnavailableView("No large files", systemImage: "doc", description: Text("No single file over 20 MB was found."))
                    } else {
                        ContentUnavailableView.search(text: model.query)
                    }
                }
            }
        }
    }
}

// MARK: - Actions

private struct CleanerActionBar: View {
    @Environment(DiskCleanerModel.self) private var model
    @State private var pendingMode: RemovalMode?

    var body: some View {
        let summary = model.selectionSummary
        ActionBar {
            Image(systemName: summary.count == 0 ? "circle.dashed" : "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(summary.count == 0 ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text(summary.count == 0 ? "Nothing selected" : "\(plural(summary.count, "item")) selected")
                    .font(.callout.weight(.medium))
                Text(summary.count == 0 ? "Tick items to remove them" : Bytes.format(summary.size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            if summary.count > 0 {
                Button("Clear") { model.clearSelection() }
                    .buttonStyle(.borderless)
            }
            Button { pendingMode = .trash } label: {
                Label("Move to Trash", systemImage: "trash")
            }
            .help("Moves to the Trash. Space is freed once you empty it.")
            .disabled(summary.count == 0)
            Button(role: .destructive) { pendingMode = .permanent } label: {
                Label("Delete Permanently", systemImage: "xmark.bin.fill")
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .disabled(summary.count == 0)
        }
        .alert(alertTitle(summary), isPresented: Binding(get: { pendingMode != nil }, set: { if !$0 { pendingMode = nil } }),
               presenting: pendingMode) { mode in
            Button(mode == .trash ? "Move to Trash" : "Delete Permanently", role: .destructive) { model.remove(mode) }
            Button("Cancel", role: .cancel) {}
        } message: { mode in
            Text(alertMessage(summary, mode: mode))
        }
    }

    private func alertTitle(_ summary: SelectionSummary) -> String {
        let what = "\(plural(summary.count, "item")) (\(Bytes.format(summary.size)))"
        return pendingMode == .permanent ? "Permanently delete \(what)?" : "Move \(what) to the Trash?"
    }

    private func alertMessage(_ summary: SelectionSummary, mode: RemovalMode) -> String {
        var lines = summary.paths.prefix(8).map(FS.abbreviate)
        if summary.count > 8 { lines.append("…and \(summary.count - 8) more") }
        var notes: [String] = []
        if summary.paths.contains(FS.trash) { notes.append("The Trash will be emptied permanently.") }
        notes.append(mode == .trash ? "Space is freed once you empty the Trash." : "This can't be undone.")
        return lines.joined(separator: "\n") + "\n\n" + notes.joined(separator: " ")
    }
}
