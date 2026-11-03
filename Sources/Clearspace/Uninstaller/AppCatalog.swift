import CoreServices
import Foundation

struct InstalledApp: Identifiable, Hashable {
    let path: String
    /// The bundle's file name without ".app": what Finder shows and what leftovers are named after.
    let name: String
    let bundleID: String?
    let version: String?

    var id: String { path }
}

enum AppCatalog {
    static func installedApps(in roots: [String] = ["/Applications", FS.home + "/Applications"]) -> [InstalledApp] {
        var bundles: [String] = []
        for root in roots { collectBundles(in: root, depth: 1, into: &bundles) }
        let ownBundle = FS.realPath(Bundle.main.bundlePath)
        var seen = Set<String>()
        return bundles.compactMap { candidate -> InstalledApp? in
            let path = FS.realPath(candidate)
            guard !isSystemApp(path), path != ownBundle, seen.insert(path).inserted else { return nil }
            return app(at: path)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Apps on the sealed system volume (Safari's /Applications link included) can't be removed.
    static func isSystemApp(_ path: String) -> Bool {
        FS.realPath(path).hasPrefix("/System/")
    }

    static func app(at path: String) -> InstalledApp? {
        guard path.lowercased().hasSuffix(".app"), FS.isDirectory(FS.realPath(path)) else { return nil }
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        // iPhone/iPad apps on Apple silicon keep their Info.plist inside a wrapper.
        let info = ["Contents/Info.plist", "WrappedBundle/Info.plist"].lazy
            .compactMap { NSDictionary(contentsOfFile: path + "/" + $0) }
            .first
        let bundleID = (info?["CFBundleIdentifier"] as? String) ?? spotlightBundleID(path)
        return InstalledApp(path: path, name: name,
                            bundleID: nonEmpty(bundleID),
                            version: nonEmpty(info?["CFBundleShortVersionString"] as? String))
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
        return trimmed
    }

    private static func spotlightBundleID(_ path: String) -> String? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemCFBundleIdentifier) as? String
    }

    private static func collectBundles(in dir: String, depth: Int, into bundles: inout [String]) {
        for name in FS.listNames(dir) where !name.hasPrefix(".") {
            let path = dir + "/" + name
            if name.lowercased().hasSuffix(".app") {
                bundles.append(path)
            } else if depth < 2, FS.isDirectory(path) {
                collectBundles(in: path, depth: depth + 1, into: &bundles)
            }
        }
    }
}
