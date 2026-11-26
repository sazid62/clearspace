import Foundation

/// Refuses deletes that would damage the system or the account: whole top-level folders,
/// anything inside Keychains or ~/.ssh, anything in /tmp owned by someone else, and anything outside the scanned roots.
struct CleanerGuard {
    private let roots: [String]
    private let protected: Set<String>
    private let neverInside: [String]
    private let sharedTemp: String
    private let owner: uid_t

    init(roots: [String] = ScanRoot.defaults.map(\.path), home: String = FS.home,
         tempRoot: String = FS.userTempRoot, sharedTemp: String = FS.sharedTemp,
         appBundle: String = Bundle.main.bundlePath, owner: uid_t = getuid()) {
        let homeFolders = ["Library", "Library/Application Support", "Library/Caches", "Library/Preferences",
                           "Library/Keychains", "Library/Containers", "Library/Group Containers", "Library/Mail",
                           "Library/Mobile Documents", "Library/CloudStorage",
                           "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music", ".ssh"]
        let paths = [home, "/Applications", tempRoot, sharedTemp, appBundle]
            + homeFolders.map { home + "/" + $0 }
            + ["T", "C", "X", "0"].map { tempRoot + "/" + $0 }
        protected = Set(paths.map(FS.realPath))
        neverInside = [home + "/Library/Keychains", home + "/.ssh"].map(FS.realPath)
        self.roots = roots.map(FS.realPath)
        self.sharedTemp = FS.realPath(sharedTemp)
        self.owner = owner
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
        if real.hasPrefix(sharedTemp + "/") {
            // /tmp is shared by every account: only touch what this user created there.
            let top = sharedTemp + "/" + real.dropFirst(sharedTemp.count + 1).prefix { $0 != "/" }
            if FS.info(top)?.st_uid != owner { return "It belongs to another user." }
        }
        if !roots.contains(where: { real.hasPrefix($0 + "/") }) {
            return "It's outside the scanned folders."
        }
        return nil
    }
}
