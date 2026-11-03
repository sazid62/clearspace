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

@MainActor @Observable
final class AppModel {
    var tool: Tool = .cleaner
    private(set) var storage = StorageInfo.current()
    private(set) var hasFullDiskAccess = Permissions.hasFullDiskAccess()
    let cleaner = DiskCleanerModel()
    let uninstaller = UninstallerModel()

    init() {
        cleaner.onFilesRemoved = { [weak self] in self?.refresh() }
        uninstaller.onFilesRemoved = { [weak self] in self?.refresh() }
    }

    func refresh() {
        storage = .current()
        hasFullDiskAccess = Permissions.hasFullDiskAccess()
    }
}
