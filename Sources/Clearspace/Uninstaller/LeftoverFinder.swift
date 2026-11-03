import Foundation

enum LeftoverKind: Int, CaseIterable, Comparable {
    case application, support, caches, preferences, containers, groupContainers
    case savedState, webData, logs, launchItems, receipts, other

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .application: "Application"
        case .support: "Support Files & Scripts"
        case .caches: "Caches"
        case .preferences: "Preferences"
        case .containers: "Containers"
        case .groupContainers: "Group Containers"
        case .savedState: "Saved Window State"
        case .webData: "Web Data & Cookies"
        case .logs: "Logs"
        case .launchItems: "Launch Agents & Daemons"
        case .receipts: "Installer Receipts"
        case .other: "Other"
        }
    }

    var symbol: String {
        switch self {
        case .application: "app"
        case .support: "folder"
        case .caches: "archivebox"
        case .preferences: "gearshape"
        case .containers: "shippingbox"
        case .groupContainers: "square.stack.3d.up"
        case .savedState: "macwindow"
        case .webData: "globe"
        case .logs: "doc.text"
        case .launchItems: "bolt"
        case .receipts: "doc.badge.gearshape"
        case .other: "questionmark.folder"
        }
    }
}

enum MatchConfidence {
    /// Named exactly after the app, or carrying its bundle identifier.
    case exact
    /// Only shares the app's name as a word; could belong to something else.
    case nameOnly
}

struct Leftover: Identifiable, Hashable {
    let path: String
    let kind: LeftoverKind
    let confidence: MatchConfidence

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

/// Finds everything that belongs to an app: its bundle, preferences, caches, containers, logs,
/// saved state, launch agents/daemons, package receipts and anything else in ~/Library named after it.
final class LeftoverFinder {
    let app: InstalledApp
    private let userLibrary: String
    private let systemLibrary: String
    private let receipts: String
    private var hits: [String: MatchConfidence] = [:]
    private var listings: [String: [String]] = [:]

    init(app: InstalledApp, userLibrary: String = FS.home + "/Library",
         systemLibrary: String = "/Library", receipts: String = "/private/var/db/receipts") {
        self.app = app
        self.userLibrary = userLibrary
        self.systemLibrary = systemLibrary
        self.receipts = receipts
    }

    func find() -> [Leftover] {
        hits = [:]
        add(app.path)
        for base in [userLibrary, systemLibrary] {
            addChild(of: base + "/Application Support", named: app.name)
            addChild(of: base + "/Caches", named: app.name)
            addChild(of: base + "/Logs", named: app.name)
            addChild(of: base + "/PreferencePanes", named: app.name + ".prefPane")
            if let id = app.bundleID {
                let prefix = id.lowercased() + "."
                addChild(of: base + "/Application Support", named: id)
                addChild(of: base + "/Caches", named: id)
                addChild(of: base + "/Preferences", named: id + ".plist")
                addChild(of: base + "/Containers", named: id)
                addChild(of: base + "/Application Scripts", named: id)
                addEntries(of: base + "/Preferences/ByHost") { $0.lowercased().hasPrefix(prefix) && $0.hasSuffix(".plist") }
                addEntries(of: base + "/WebKit") { Self.containsWord($0, id) }
                addEntries(of: base + "/HTTPStorages") { Self.containsWord($0, id) }
                addEntries(of: base + "/Saved Application State") { Self.containsWord($0, id) && $0.hasSuffix(".savedState") }
            }
            addMatches(in: base + "/LaunchAgents") { $0.hasSuffix(".plist") }
            addMatches(in: base + "/LaunchDaemons") { $0.hasSuffix(".plist") }
            addMatches(in: base + "/Group Containers")
        }
        if let id = app.bundleID {
            let prefix = id.lowercased() + "."
            addEntries(of: receipts) { $0.lowercased().hasPrefix(prefix) }
        }
        sweepUserLibrary()
        return results()
    }

    /// True when `word` appears in `text` with no letter or digit directly before or after it
    /// (ignoring case), so "Paste" matches "Paste Helper" and "com.x.paste" but not "PasteBar".
    static func containsWord(_ text: String, _ word: String) -> Bool {
        let hay = Array(text.lowercased().utf8)
        let needle = Array(word.lowercased().utf8)
        guard !needle.isEmpty, hay.count >= needle.count else { return false }
        func isWordByte(_ byte: UInt8) -> Bool { (0x61...0x7A).contains(byte) || (0x30...0x39).contains(byte) }
        for start in 0...(hay.count - needle.count) where hay[start..<start + needle.count].elementsEqual(needle) {
            let end = start + needle.count
            if (start == 0 || !isWordByte(hay[start - 1])) && (end == hay.count || !isWordByte(hay[end])) { return true }
        }
        return false
    }

    // MARK: Collecting

    private func add(_ path: String, _ confidence: MatchConfidence = .exact) {
        guard FS.exists(path) else { return }
        if hits[path] != .exact { hits[path] = confidence }
    }

    /// Adds `dir/name`, matching the name case-insensitively like the file system does.
    private func addChild(of dir: String, named name: String) {
        guard !name.isEmpty,
              let actual = listing(dir).first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        add(dir + "/" + actual)
    }

    private func addEntries(of dir: String, where include: (String) -> Bool) {
        for entry in listing(dir) where include(entry) { add(dir + "/" + entry) }
    }

    private func addMatches(in dir: String, where include: (String) -> Bool = { _ in true }) {
        for entry in listing(dir) where include(entry) {
            if let confidence = match(entry) { add(dir + "/" + entry, confidence) }
        }
    }

    private func match(_ entry: String) -> MatchConfidence? {
        if let id = app.bundleID, Self.containsWord(entry, id) { return .exact }
        if Self.containsWord(entry, app.name) { return .nameOnly }
        return nil
    }

    private func listing(_ dir: String) -> [String] {
        if let cached = listings[dir] { return cached }
        let names = FS.listNames(dir)
        listings[dir] = names
        return names
    }

    /// Catches leftovers in nonstandard places: anything in ~/Library (four levels deep) named after the app.
    private func sweepUserLibrary(maxDepth: Int = 4) {
        // Personal data that is never an app's leftover, however it's named.
        let skipped = Set(["Mail", "Messages", "Mobile Documents", "CloudStorage", "Keychains", "Calendars",
                           "Safari", "Photos", "Accounts", "Biome", "Daemon Containers"].map { userLibrary + "/" + $0 })
        // Other apps' sandboxes: test their folder names, but never look inside them.
        let shallow: Set<String> = [userLibrary + "/Containers", userLibrary + "/Group Containers"]
        var pending: [(path: String, depth: Int)] = [(userLibrary, 0)]
        while let next = pending.popLast() {
            for entry in FS.listNames(next.path) {
                let path = next.path + "/" + entry
                if let confidence = match(entry) {
                    add(path, confidence)
                    continue
                }
                if next.depth + 1 < maxDepth, !shallow.contains(next.path), !skipped.contains(path), FS.isDirectory(path) {
                    pending.append((path, next.depth + 1))
                }
            }
        }
    }

    private func results() -> [Leftover] {
        var kept: [String] = []
        for path in hits.keys.sorted() {
            let parent = (path as NSString).deletingLastPathComponent
            // A top-level Library folder (~/Library/Caches itself) is never one app's to remove.
            guard path != userLibrary, path != systemLibrary, parent != userLibrary, parent != systemLibrary,
                  !path.hasPrefix("/System/") else { continue }
            // Anything inside an item already on the list goes with it.
            guard !kept.contains(where: { path.hasPrefix($0 + "/") }) else { continue }
            kept.append(path)
        }
        return kept.map { Leftover(path: $0, kind: kind(of: $0), confidence: hits[$0] ?? .nameOnly) }
    }

    private func kind(of path: String) -> LeftoverKind {
        if path == app.path { return .application }
        if path.hasPrefix(receipts + "/") { return .receipts }
        for base in [userLibrary, systemLibrary] where path.hasPrefix(base + "/") {
            let top = path.dropFirst(base.count + 1).split(separator: "/").first.map(String.init) ?? ""
            switch top {
            case "Application Support", "Application Scripts", "PreferencePanes": return .support
            case "Caches": return .caches
            case "Preferences": return .preferences
            case "Containers": return .containers
            case "Group Containers": return .groupContainers
            case "Saved Application State": return .savedState
            case "WebKit", "HTTPStorages", "Cookies": return .webData
            case "Logs": return .logs
            case "LaunchAgents", "LaunchDaemons": return .launchItems
            default: return .other
            }
        }
        return .other
    }
}
