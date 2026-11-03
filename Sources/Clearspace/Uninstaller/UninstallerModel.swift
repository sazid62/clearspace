import AppKit
import Observation
import UniformTypeIdentifiers

enum AppSortOrder: String, CaseIterable, Identifiable {
    case name = "Name"
    case size = "Size"

    var id: Self { self }
}

struct LeftoverGroup: Identifiable {
    let kind: LeftoverKind
    let items: [Leftover]

    var id: LeftoverKind { kind }
}

@MainActor @Observable
final class UninstallerModel: RemovalHost {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoadingApps = false
    private(set) var appSizes: [String: Int64] = [:]
    var query = ""
    var sortOrder: AppSortOrder = .name

    private(set) var selectedAppID: String?
    private(set) var inspected: InstalledApp?
    private(set) var leftovers: [Leftover] = []
    private(set) var leftoverSizes: [String: Int64] = [:]
    private(set) var isSearching = false
    private(set) var checked: Set<String> = []
    private(set) var isAppRunning = false
    private(set) var removal: RemovalProgress?

    @ObservationIgnored var onFilesRemoved: (() -> Void)?
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var inspection = UUID()

    // MARK: App list

    var visibleApps: [InstalledApp] {
        let matches = query.isEmpty ? apps : apps.filter {
            $0.name.localizedCaseInsensitiveContains(query) || ($0.bundleID?.localizedCaseInsensitiveContains(query) ?? false)
        }
        guard sortOrder == .size else { return matches }
        return matches.sorted { (appSizes[$0.path] ?? -1) > (appSizes[$1.path] ?? -1) }
    }

    func loadAppsIfNeeded() {
        if !hasLoaded { reloadApps() }
    }

    func reloadApps() {
        guard !isLoadingApps else { return }
        hasLoaded = true
        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            let found = AppCatalog.installedApps()
            await self.didLoad(found)
            var batch: [String: Int64] = [:]
            for (offset, app) in found.enumerated() {
                batch[app.path] = FS.allocatedSize(app.path)
                if batch.count == 8 || offset == found.count - 1 {
                    let sizes = batch
                    batch = [:]
                    await self.didMeasureApps(sizes)
                }
            }
        }
    }

    private func didLoad(_ found: [InstalledApp]) {
        var merged = found
        // Keep an app picked from elsewhere (Downloads, an external disk) in the list.
        if let inspected, !merged.contains(inspected), FS.exists(inspected.path) { merged.append(inspected) }
        apps = merged.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        isLoadingApps = false
        if let selectedAppID, !apps.contains(where: { $0.id == selectedAppID }) { select(nil) }
    }

    private func didMeasureApps(_ sizes: [String: Int64]) {
        appSizes.merge(sizes) { $1 }
    }

    func select(_ id: String?) {
        guard id != selectedAppID else { return }
        selectedAppID = id
        if let id, let app = apps.first(where: { $0.id == id }) {
            inspect(app)
        } else {
            clearInspection()
        }
    }

    func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = "Inspect"
        panel.message = "Choose an app to uninstall"
        if panel.runModal() == .OK, let url = panel.url { open(url) }
    }

    func open(_ url: URL) {
        let path = FS.realPath(url.path)
        if AppCatalog.isSystemApp(path) {
            let alert = NSAlert()
            alert.messageText = "\(url.deletingPathExtension().lastPathComponent) is part of macOS"
            alert.informativeText = "Apps that ship with macOS live on the protected system volume and can't be removed."
            alert.runModal()
            return
        }
        guard let app = AppCatalog.app(at: path) else {
            NSSound.beep()
            return
        }
        if !apps.contains(app) {
            apps.append(app)
            apps.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            Task.detached(priority: .utility) {
                let size = FS.allocatedSize(app.path)
                await self.didMeasureApps([app.path: size])
            }
        }
        selectedAppID = app.id
        inspect(app)
    }

    // MARK: Inspection

    var groups: [LeftoverGroup] {
        Dictionary(grouping: leftovers, by: \.kind)
            .map { LeftoverGroup(kind: $0.key, items: $0.value) }
            .sorted { $0.kind < $1.kind }
    }

    var totalSize: Int64 { leftovers.reduce(0) { $0 + (leftoverSizes[$1.path] ?? 0) } }
    var checkedSize: Int64 { checked.reduce(0) { $0 + (leftoverSizes[$1] ?? 0) } }
    var hasNameMatches: Bool { leftovers.contains { $0.confidence == .nameOnly } }

    private func inspect(_ app: InstalledApp) {
        let token = UUID()
        inspection = token
        inspected = app
        leftovers = []
        leftoverSizes = [:]
        checked = []
        isSearching = true
        refreshRunningState()
        Task.detached(priority: .userInitiated) {
            let found = LeftoverFinder(app: app).find()
            await self.didFind(found, token: token)
            for item in found {
                let size = FS.allocatedSize(item.path)
                await self.didMeasure(item.path, size: size, token: token)
            }
        }
    }

    private func didFind(_ found: [Leftover], token: UUID) {
        guard token == inspection else { return }
        leftovers = found
        // Name-only matches might belong to something else, so they start unticked.
        checked = Set(found.filter { $0.confidence == .exact }.map(\.path))
        isSearching = false
    }

    private func didMeasure(_ path: String, size: Int64, token: UUID) {
        guard token == inspection else { return }
        leftoverSizes[path] = size
    }

    private func clearInspection() {
        inspection = UUID()
        inspected = nil
        leftovers = []
        leftoverSizes = [:]
        checked = []
        isSearching = false
        isAppRunning = false
    }

    func isChecked(_ path: String) -> Bool { checked.contains(path) }

    func setChecked(_ path: String, _ isOn: Bool) {
        if isOn { checked.insert(path) } else { checked.remove(path) }
    }

    func checkAll(_ isOn: Bool) {
        checked = isOn ? Set(leftovers.map(\.path)) : []
    }

    // MARK: Running app

    private func runningInstances() -> [NSRunningApplication] {
        guard let app = inspected else { return [] }
        return NSWorkspace.shared.runningApplications.filter { running in
            (app.bundleID != nil && running.bundleIdentifier == app.bundleID) || running.bundleURL?.path == app.path
        }
    }

    func refreshRunningState() {
        isAppRunning = !runningInstances().isEmpty
    }

    func quitInspectedApp() {
        for running in runningInstances() { running.terminate() }
    }

    // MARK: Removal

    func uninstall(_ mode: RemovalMode) {
        guard removal == nil else { return }
        let items = leftovers
            .filter { checked.contains($0.path) }
            .map { RemovalItem(path: $0.path, size: leftoverSizes[$0.path] ?? 0) }
        guard !items.isEmpty else { return }
        removal = RemovalProgress(mode: mode, total: items.count)
        RemovalRunner.run(items, mode: mode,
                          onStart: { self.removal?.current = $0 },
                          onOutcome: { self.removal?.outcomes.append($0) },
                          onFinish: {
                              self.removal?.isRunning = false
                              self.onFilesRemoved?()
                          })
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
                _ = self.removal?.reconcile(after: outcome)
                self.onFilesRemoved?()
            }
        }
    }

    func finishRemoval() {
        guard let progress = removal, !progress.isRunning, !progress.isElevating else { return }
        removal = nil
        guard let app = inspected else { return }
        if FS.exists(app.path) {
            inspect(app)
        } else {
            apps.removeAll { $0.id == app.id }
            appSizes[app.path] = nil
            selectedAppID = nil
            clearInspection()
        }
    }
}
