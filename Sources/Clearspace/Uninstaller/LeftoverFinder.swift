import Foundation

enum LeftoverKind: Int, CaseIterable, Comparable {
    case application, support, caches, preferences, containers, groupContainers
    case savedState, webData, logs, launchItems, commandLineTools, homeData, receipts, other

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
        case .launchItems: "Launch Agents, Daemons & Helpers"
        case .commandLineTools: "Command-Line Tools"
        case .homeData: "Data in Your Home Folder"
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
        case .commandLineTools: "terminal"
        case .homeData: "house"
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
    private let home: String
    private let binDirs: [String]
    /// App groups other installed apps also claim; those containers hold the other apps' data too.
    private let sharedGroups: Set<String>
    private var hits: [String: MatchConfidence] = [:]
    private var listings: [String: [String]] = [:]
    /// Settings files of the user's that mention the app (shell profiles, ssh config…). Filled by `find()`.
    /// They hold the user's own lines too, so they are reported for editing by hand, never removed.
    private(set) var mentions: [String] = []

    /// Hidden config files where installers add lines (PATH, `source`, `Include`).
    static let settingsFiles = [".zprofile", ".zshrc", ".zshenv", ".zlogin", ".bash_profile", ".bashrc", ".profile",
                                ".config/fish/config.fish", ".ssh/config", ".gitconfig"]
    /// Home-folder names that are the user's own, never one app's, whatever the app is called.
    private static let personalHomeFolders: Set<String> = ["library", "applications", "desktop", "documents", "downloads",
                                                           "movies", "music", "pictures", "public", "sites", ".trash",
                                                           ".ssh", ".config", ".local", ".cache", ".docker"]

    init(app: InstalledApp, userLibrary: String = FS.home + "/Library",
         systemLibrary: String = "/Library", receipts: String = "/private/var/db/receipts",
         home: String = FS.home, binDirs: [String]? = nil, otherApps: [InstalledApp] = []) {
        self.app = app
        self.userLibrary = userLibrary
        self.systemLibrary = systemLibrary
        self.receipts = receipts
        self.home = home
        sharedGroups = Set(otherApps.filter { $0.path != app.path }.flatMap(\.appGroups))
        self.binDirs = binDirs ?? ["/usr/local/bin", "/opt/homebrew/bin", home + "/.local/bin", home + "/bin",
                                   home + "/.docker/cli-plugins"]
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
                for group in app.appGroups {
                    let confidence: MatchConfidence = sharedGroups.contains(group) ? .nameOnly : .exact
                    addChild(of: base + "/Group Containers", named: group, confidence)
                    addChild(of: base + "/Application Scripts", named: group, confidence)
                }
                addEntries(of: base + "/Preferences/ByHost") { $0.lowercased().hasPrefix(prefix) && $0.hasSuffix(".plist") }
                addEntries(of: base + "/WebKit") { Self.containsWord($0, id) }
                addEntries(of: base + "/HTTPStorages") { Self.containsWord($0, id) }
                addEntries(of: base + "/Saved Application State") { Self.containsWord($0, id) && $0.hasSuffix(".savedState") }
            }
            addMatches(in: base + "/LaunchAgents") { $0.hasSuffix(".plist") }
            addMatches(in: base + "/LaunchDaemons") { $0.hasSuffix(".plist") }
            addMatches(in: base + "/Group Containers")
            addLaunchJobs(in: base + "/LaunchAgents")
            addLaunchJobs(in: base + "/LaunchDaemons")
            for label in app.helperLabels { addChild(of: base + "/PrivilegedHelperTools", named: label) }
        }
        if let id = app.bundleID {
            let prefix = id.lowercased() + "."
            addEntries(of: receipts) { $0.lowercased().hasPrefix(prefix) }
        }
        sweepUserLibrary()
        addHomeFolders()
        addSymlinksIntoApp()
        addDockerContexts()
        findMentions()
        return results()
    }

    // MARK: Outside ~/Library

    /// launchd jobs that name the app: by AssociatedBundleIdentifiers, by a helper label the app
    /// declares, or by running a program inside the bundle. The helper binary they run goes too.
    private func addLaunchJobs(in dir: String) {
        let appPrefix = app.path + "/"
        for entry in listing(dir) where entry.hasSuffix(".plist") {
            let path = dir + "/" + entry
            guard let job = NSDictionary(contentsOfFile: path) as? [String: Any] else { continue }
            let label = job["Label"] as? String ?? ""
            let program = job["Program"] as? String ?? (job["ProgramArguments"] as? [String])?.first ?? ""
            let associated = job["AssociatedBundleIdentifiers"] as? [String] ?? []
            let owned = (app.bundleID.map { associated.contains($0) } ?? false)
                || app.helperLabels.contains(label)
                || program.hasPrefix(appPrefix)
            guard owned else { continue }
            add(path)
            // The helper it runs, when that lives outside the bundle (e.g. /Library/PrivilegedHelperTools).
            if program.hasPrefix("/"), !program.hasPrefix(appPrefix), !program.hasPrefix("/System/"),
               !program.hasPrefix("/usr/bin/"), !program.hasPrefix("/bin/"), !program.hasPrefix("/usr/sbin/") {
                add(program)
            }
        }
    }

    /// ~/.<name>, ~/<Name> and the XDG folders (~/.config/<name>, ~/.cache/<name>, ~/.local/share/<name>, …).
    private func addHomeFolders() {
        let name = app.name
        guard !name.isEmpty, !Self.personalHomeFolders.contains(name.lowercased()),
              !Self.personalHomeFolders.contains("." + name.lowercased()) else { return }
        for candidate in [name, "." + name] { addChild(of: home, named: candidate) }
        for xdg in [".config", ".cache", ".local/share", ".local/state"] { addChild(of: home + "/" + xdg, named: name) }
    }

    /// Command-line links an app installs (docker, kubectl, code…) that point into its bundle.
    /// They are left dangling once the bundle is gone.
    private func addSymlinksIntoApp() {
        let appPrefix = app.path + "/"
        for dir in binDirs {
            for entry in listing(dir) {
                let path = dir + "/" + entry
                guard let st = FS.info(path), st.st_mode & S_IFMT == S_IFLNK,
                      let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else { continue }
                // realpath follows the whole chain; the raw target covers links whose file is already gone.
                let resolved = FS.realPath(path)
                if resolved == app.path || resolved.hasPrefix(appPrefix) || target.hasPrefix(appPrefix) { add(path) }
            }
        }
    }

    /// Docker CLI contexts an app registers (~/.docker/contexts/meta/<hash>/meta.json "Name").
    private func addDockerContexts() {
        let contexts = home + "/.docker/contexts"
        for hash in listing(contexts + "/meta") {
            guard let data = FileManager.default.contents(atPath: contexts + "/meta/" + hash + "/meta.json"),
                  let meta = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let contextName = meta["Name"] as? String,
                  contextName.caseInsensitiveCompare(app.name) == .orderedSame else { continue }
            add(contexts + "/meta/" + hash)
            add(contexts + "/tls/" + hash)
            // The Docker CLI fails on every command while its current context is missing.
            if let config = FileManager.default.contents(atPath: home + "/.docker/config.json"),
               let json = try? JSONSerialization.jsonObject(with: config) as? [String: Any],
               (json["currentContext"] as? String) == contextName {
                mentions.append(home + "/.docker/config.json")
            }
        }
    }

    /// Settings files that reference the app by bundle path, bundle ID, its ~/.<name> folder or its exact name.
    private func findMentions() {
        var needles = [app.path, "/." + app.name.lowercased() + "/"]
        if let id = app.bundleID { needles.append(id) }
        for file in Self.settingsFiles {
            let path = home + "/" + file
            guard let data = FileManager.default.contents(atPath: path), data.count < 4_000_000,
                  let text = String(data: data, encoding: .utf8) else { continue }
            // Case-sensitive on the name: "Home" shouldn't match every $HOME.
            if needles.contains(where: { text.contains($0) }) || Self.containsCaseSensitiveWord(text, app.name) {
                mentions.append(path)
            }
        }
        mentions = Array(Set(mentions)).sorted()
    }

    static func containsCaseSensitiveWord(_ text: String, _ word: String) -> Bool {
        guard !word.isEmpty else { return false }
        var searchRange = text.startIndex..<text.endIndex
        while let found = text.range(of: word, range: searchRange) {
            let before = found.lowerBound == text.startIndex ? nil : text[text.index(before: found.lowerBound)]
            let after = found.upperBound == text.endIndex ? nil : text[found.upperBound]
            if !(before?.isLetter ?? false || before?.isNumber ?? false),
               !(after?.isLetter ?? false || after?.isNumber ?? false) { return true }
            searchRange = found.upperBound..<text.endIndex
        }
        return false
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
    private func addChild(of dir: String, named name: String, _ confidence: MatchConfidence = .exact) {
        guard !name.isEmpty,
              let actual = listing(dir).first(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        add(dir + "/" + actual, confidence)
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
                if var confidence = match(entry) {
                    // A folder named exactly after the app inside a cache or log store (Caches/SentryCrash/OrbStack)
                    // is that app's, and regenerable even if not.
                    if confidence == .nameOnly, entry.caseInsensitiveCompare(app.name) == .orderedSame,
                       [userLibrary + "/Caches/", userLibrary + "/Logs/"].contains(where: { path.hasPrefix($0) }) {
                        confidence = .exact
                    }
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
            case "LaunchAgents", "LaunchDaemons", "PrivilegedHelperTools": return .launchItems
            default: return .other
            }
        }
        if binDirs.contains(where: { path.hasPrefix($0 + "/") }) { return .commandLineTools }
        if path.hasPrefix(home + "/") { return .homeData }
        return .other
    }
}
