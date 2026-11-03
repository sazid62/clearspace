import Foundation

/// Refuses deletes that would damage the system or the account: whole top-level folders,
/// anything inside Keychains or ~/.ssh, and anything outside the scanned roots.
struct CleanerGuard {
    private let roots: [String]
    private let protected: Set<String>
    private let neverInside: [String]

    init(roots: [String] = ScanRoot.defaults.map(\.path), home: String = FS.home,
         tempRoot: String = FS.userTempRoot, appBundle: String = Bundle.main.bundlePath) {
        let homeFolders = ["Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
                           "Library/Keychains", "Library/Containers", "Library/Group Containers", "Library/Mail",
                           "Library/Mobile Documents", "Library/CloudStorage",
                           "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", ".ssh"]
        let paths = [home, "/Applications", tempRoot, appBundle]
            + homeFolders.map { home + "/" + $0 }
            + ["T", "C", "X", "0"].map { tempRoot + "/" + $0 }
        protected = Set(paths.map(FS.realPath))
        neverInside = [home + "/Library/Keychains", home + "/.ssh"].map(FS.realPath)
        self.roots = roots.map(FS.realPath)
    }

    func refusal(for path: String) -> String? {
        guard FS.exists(path) else { return "It no longer exists." }
        let real = FS.realPath(path)
        if protected.contains(real) || (real as NSString).deletingLastPathComponent == "/" {
            return "This folder is protected."
        }
        if neverInside.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) {
            return "This folder is protected."
        }
        if !roots.contains(where: { real.hasPrefix($0 + "/") }) {
            return "It's outside the scanned folders."
        }
        return nil
    }
}
