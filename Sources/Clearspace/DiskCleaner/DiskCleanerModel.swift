import Foundation
import Observation

enum CleanerTab: String, CaseIterable, Identifiable {
    case suggestions = "Suggestions"
    case folders = "Folders"
    case files = "Large Files"

    var id: Self { self }
}

struct TreeRow: Identifiable {
    enum Kind {
        case item(FSNode)
        case smallItems(Int64)
    }

    let id: String
    let kind: Kind
    let depth: Int
    /// Share of the parent folder, for the size bar.
    let fraction: Double
}

struct ScanSummary {
    let files: Int
    let duration: TimeInterval
    let total: Int64
}

struct SelectionSummary {
    let paths: [String]
    let size: Int64

    var count: Int { paths.count }
}

@MainActor @Observable
final class DiskCleanerModel: RemovalHost {
    enum Phase {
        case idle, scanning, ready
    }

    private(set) var phase: Phase = .idle
    var tab: CleanerTab = .suggestions
    var query = ""

    private(set) var scannedFiles = 0
    private(set) var scanningPath = ""
    private(set) var summary: ScanSummary?

    private(set) var suggestions: [Suggestion] = []
    private(set) var treeRows: [TreeRow] = []
    private(set) var largeFiles: [LargeFile] = []
    private(set) var expanded: Set<String> = []
    /// Selected path -> size. A selected folder covers everything inside it.
    private(set) var selection: [String: Int64] = [:]
    private(set) var removal: RemovalProgress?
    /// Bumped whenever the scan result changes, so views reading derived lists refresh.
    private var revision = 0

    @ObservationIgnored var onFilesRemoved: (() -> Void)?
    @ObservationIgnored private var result: ScanResult?
    @ObservationIgnored private var scanner: DiskScanner?

    var isBusy: Bool { phase == .scanning || removal != nil }

    // MARK: Scanning

    func startScan() {
        guard phase != .scanning, removal == nil else { return }
        let scanner = DiskScanner()
        self.scanner = scanner
        phase = .scanning
        scannedFiles = 0
        scanningPath = ""
        scanner.onProgress = { count, path in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.scanner === scanner else { return }
                    self.scannedFiles = count
                    self.scanningPath = path
                }
            }
        }
        let thread = Thread {
            let result = scanner.run()
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.finishScan(result, from: scanner) }
            }
        }
        thread.stackSize = 64 << 20  // the scan recurses once per folder level
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    func cancelScan() { scanner?.cancel() }

    private func finishScan(_ result: ScanResult?, from scanner: DiskScanner) {
        guard self.scanner === scanner else { return }
        self.scanner = nil
        if let result {
            self.result = result
            selection = [:]
            expanded = []
            rebuild()
        }
        phase = self.result == nil ? .idle : .ready
    }

    private func rebuild() {
        guard let result else { return }
        suggestions = SuggestionCatalog.suggestions(in: result)
        largeFiles = result.largeFiles
        summary = ScanSummary(files: result.fileCount, duration: result.duration, total: result.root.size)
        rebuildTree()
        revision += 1
    }

    private func rebuildTree() {
        guard let root = result?.root else {
            treeRows = []
            return
        }
        var rows: [TreeRow] = []
        func walk(_ node: FSNode, depth: Int) {
            for child in node.children {
                rows.append(TreeRow(id: child.path, kind: .item(child), depth: depth, fraction: share(child.size, of: node.size)))
                if child.isDirectory && expanded.contains(child.path) { walk(child, depth: depth + 1) }
            }
            if depth > 0 && node.smallItems > 0 {
                rows.append(TreeRow(id: node.path + "#small-items", kind: .smallItems(node.smallItems), depth: depth,
                                    fraction: share(node.smallItems, of: node.size)))
            }
        }
        walk(root, depth: 0)
        treeRows = rows
    }

    private func share(_ size: Int64, of total: Int64) -> Double {
        total > 0 ? Double(size) / Double(total) : 0
    }

    func toggleExpanded(_ path: String) {
        if expanded.contains(path) { expanded.remove(path) } else { expanded.insert(path) }
        rebuildTree()
    }

    func isExpanded(_ path: String) -> Bool { expanded.contains(path) }

    // MARK: Filtering

    var visibleSuggestions: [Suggestion] {
        guard !query.isEmpty else { return suggestions }
        return suggestions.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
    }

    var visibleFiles: [LargeFile] {
        guard !query.isEmpty else { return largeFiles }
        return largeFiles.filter { $0.path.localizedCaseInsensitiveContains(query) }
    }

    /// Folder-tab search: every item over the minimum size whose name matches, biggest first.
    var folderMatches: [FSNode] {
        _ = revision
        guard let result, !query.isEmpty else { return [] }
        return Array(result.index.values
            .filter { $0.name.localizedCaseInsensitiveContains(query) }
            .sorted { $0.size > $1.size }
            .prefix(500))
    }

    // MARK: Selection

    func isSelected(_ path: String) -> Bool { selection[path] != nil }

    func isCovered(_ path: String) -> Bool {
        selection.keys.contains { path.hasPrefix($0 + "/") }
    }

    func setSelected(_ path: String, size: Int64, _ selected: Bool) {
        if selected {
            selection = selection.filter { !$0.key.hasPrefix(path + "/") }
            selection[path] = size
        } else {
            selection[path] = nil
        }
    }

    func clearSelection() { selection = [:] }

    var safeSuggestionsSize: Int64 {
        suggestions.filter { $0.safety == .safe }.reduce(0) { $0 + $1.size }
    }

    func selectSafeSuggestions() {
        for suggestion in suggestions where suggestion.safety == .safe && !isCovered(suggestion.path) {
            setSelected(suggestion.path, size: suggestion.size, true)
        }
    }

    var selectionSummary: SelectionSummary {
        var kept: [String] = []
        for path in selection.keys.sorted(by: { $0.count < $1.count }) where !kept.contains(where: { path.hasPrefix($0 + "/") }) {
            kept.append(path)
        }
        kept.sort { (selection[$0] ?? 0) > (selection[$1] ?? 0) }
        return SelectionSummary(paths: kept, size: kept.reduce(0) { $0 + (selection[$1] ?? 0) })
    }

    // MARK: Removal

    func remove(_ mode: RemovalMode) {
        guard removal == nil else { return }
        let guardrail = CleanerGuard()
        let items = selectionSummary.paths.map { path in
            RemovalItem(path: path, size: result?.index[path]?.size ?? selection[path] ?? 0, refusal: guardrail.refusal(for: path))
        }
        guard !items.isEmpty else { return }
        removal = RemovalProgress(mode: mode, total: items.count)
        RemovalRunner.run(items, mode: mode,
                          onStart: { self.removal?.current = $0 },
                          onOutcome: { self.record($0) },
                          onFinish: {
                              self.removal?.isRunning = false
                              self.onFilesRemoved?()
                          })
    }

    private func record(_ outcome: RemovalOutcome) {
        removal?.outcomes.append(outcome)
        if outcome.succeeded { dropRemoved(outcome.path) }
    }

    private func dropRemoved(_ path: String) {
        result?.drop(path)
        selection = selection.filter { $0.key != path && !$0.key.hasPrefix(path + "/") }
        rebuild()
    }

    func retryFailuresAsAdmin() {
        guard let progress = removal, progress.canRetryAsAdmin else { return }
        let paths = progress.failures.filter(\.needsAdmin).map(\.path)
        removal?.isElevating = true
        removal?.adminError = nil
        // Let the panel show its waiting state before the password prompt blocks the main thread.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let outcome = FileRemover.removeAsAdministrator(paths, mode: progress.mode)
                self.removal?.isElevating = false
                for path in self.removal?.reconcile(after: outcome) ?? [] { self.dropRemoved(path) }
                self.onFilesRemoved?()
            }
        }
    }

    func finishRemoval() {
        guard let progress = removal, !progress.isRunning, !progress.isElevating else { return }
        removal = nil
    }
}
