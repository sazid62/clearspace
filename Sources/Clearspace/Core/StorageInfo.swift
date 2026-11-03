import AppKit

struct StorageInfo {
    var volumeName = "Macintosh HD"
    var total: Int64 = 0
    var available: Int64 = 0

    var used: Int64 { max(0, total - available) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func current() -> StorageInfo {
        let keys: Set<URLResourceKey> = [.volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys) else { return StorageInfo() }
        var info = StorageInfo()
        info.volumeName = values.volumeLocalizedName ?? info.volumeName
        info.total = Int64(values.volumeTotalCapacity ?? 0)
        // "Important usage" includes purgeable space, matching what Finder reports as available.
        info.available = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return info
    }
}

enum Permissions {
    /// These files open only with Full Disk Access; EPERM means it hasn't been granted.
    static func hasFullDiskAccess() -> Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            FS.home + "/Library/Application Support/com.apple.TCC/TCC.db",
            FS.home + "/Library/Safari/Bookmarks.plist",
        ]
        for path in probes {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }

    static func openFullDiskAccessSettings() { openPrivacyPane("Privacy_AllFiles") }
    static func openAppManagementSettings() { openPrivacyPane("Privacy_AppBundles") }

    private static func openPrivacyPane(_ anchor: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }
}
