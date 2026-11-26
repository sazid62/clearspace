import Foundation

enum Safety {
    /// Rebuilt or re-downloaded automatically when needed.
    case safe
    /// Your own data or slow to get back; decide for yourself.
    case review
}

struct Suggestion: Identifiable {
    let path: String
    let title: String
    let note: String
    let safety: Safety
    let size: Int64

    var id: String { path }
}

/// Known caches and leftovers, plus items found by what they are (see Detector).
enum SuggestionCatalog {
    private struct Entry {
        let path: String
        let title: String
        let safety: Safety
        let note: String
    }

    private static var entries: [Entry] {
        let tmp = FS.userTempRoot
        func home(_ relative: String) -> String { FS.home + "/" + relative }
        return [
            Entry(path: tmp + "/X/com.google.Chrome.code_sign_clone", title: "Chrome leftover copies", safety: .safe,
                  note: "A Chrome bug leaves old copies of the app here. Quit Chrome first."),
            Entry(path: tmp + "/X/com.brave.Browser.code_sign_clone", title: "Brave leftover copies", safety: .safe,
                  note: "Same bug as Chrome. Quit Brave first."),
            Entry(path: home("Library/Caches/go-build"), title: "Go build cache", safety: .safe,
                  note: "Rebuilt on the next go build."),
            Entry(path: home("Library/Caches/pnpm"), title: "pnpm metadata cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/BraveSoftware"), title: "Brave browser cache", safety: .safe,
                  note: "Quit Brave first."),
            Entry(path: home("Library/Caches/com.brave.Browser"), title: "Brave browser cache (2)", safety: .safe,
                  note: "Quit Brave first."),
            Entry(path: home("Library/Caches/Google"), title: "Chrome browser cache", safety: .safe,
                  note: "Quit Chrome first."),
            Entry(path: home("Library/Caches/com.microsoft.VSCode.ShipIt"), title: "VS Code old update files", safety: .safe,
                  note: "Leftovers from past updates."),
            Entry(path: home("Library/Caches/Homebrew"), title: "Homebrew downloads", safety: .safe,
                  note: "Old installer downloads."),
            Entry(path: home("Library/Application Support/Google/GoogleUpdater/crx_cache"), title: "Google updater cache", safety: .safe,
                  note: "Old update packages."),
            Entry(path: home(".gradle/caches"), title: "Gradle cache", safety: .safe,
                  note: "Re-downloaded on the next Android/Gradle build."),
            Entry(path: home(".npm/_cacache"), title: "npm cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/Yarn"), title: "Yarn cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home(".bun/install/cache"), title: "Bun cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/pip"), title: "pip cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/CocoaPods"), title: "CocoaPods cache", safety: .safe,
                  note: "Re-downloaded on the next pod install."),
            Entry(path: home("go/pkg/mod"), title: "Go module downloads", safety: .safe,
                  note: "Re-downloaded on the next go build."),
            Entry(path: home("Library/Developer/Xcode/DerivedData"), title: "Xcode build products", safety: .safe,
                  note: "Rebuilt the next time you build in Xcode."),
            Entry(path: home("Library/Developer/CoreSimulator/Caches"), title: "Simulator caches", safety: .safe,
                  note: "Recreated by the iOS Simulator."),
            Entry(path: FS.trash, title: "Trash contents", safety: .safe,
                  note: "Things you already deleted. (Empties the Trash.)"),
            Entry(path: home("Library/pnpm/store"), title: "pnpm package store", safety: .review,
                  note: "Projects re-download packages on the next pnpm install. Files still used by node_modules stay on disk until those projects are reinstalled."),
            Entry(path: home("Library/Application Support/com.apple.wallpaper/aerials/videos"), title: "Aerial wallpaper videos", safety: .review,
                  note: "Downloaded screen-saver videos; macOS re-downloads the one you use."),
            Entry(path: home("Library/Developer/Xcode/iOS DeviceSupport"), title: "iOS device support files", safety: .review,
                  note: "Copied again from your device the next time you connect it to Xcode."),
            Entry(path: home("Library/Caches/ms-playwright"), title: "Playwright browsers", safety: .review,
                  note: "Re-download with npx playwright install."),
            Entry(path: home(".ollama/models"), title: "Ollama AI models", safety: .review,
                  note: "Your downloaded models. Delete only if you no longer use them."),
            Entry(path: home(".cache/huggingface"), title: "Hugging Face models", safety: .review,
                  note: "Downloaded models and datasets. Delete only if you no longer use them."),
            Entry(path: home(".android/avd"), title: "Android emulator phones", safety: .review,
                  note: "Your emulators. Delete only if you don't use them."),
            Entry(path: home("Library/Android/sdk/system-images"), title: "Android system images", safety: .review,
                  note: "Needed to create and run emulators."),
            Entry(path: home(".codeium"), title: "Codeium / Windsurf index", safety: .review,
                  note: "Rebuilt when you reopen the editor."),
        ]
    }

    /// Known caches plus what the scan itself turned up: project build folders, git worktrees,
    /// leftovers in /tmp, videos, and big downloads.
    static func suggestions(in result: ScanResult, home: String = FS.home, sharedTemp: String = FS.sharedTemp,
                            owner: uid_t = getuid(), now: Date = Date(),
                            minimum: Int64 = DiskScanner.defaultMinimumItemSize) -> [Suggestion] {
        var found: [String: Suggestion] = [:]
        func add(_ suggestion: Suggestion) {
            if found[suggestion.path] == nil { found[suggestion.path] = suggestion }
        }
        for entry in entries {
            guard let node = result.index[entry.path], node.size >= minimum else { continue }
            add(Suggestion(path: entry.path, title: entry.title, note: entry.note, safety: entry.safety, size: node.size))
        }
        let detector = Detector(result: result, home: home, sharedTemp: sharedTemp, owner: owner, now: now, minimum: minimum)
        detector.folders().forEach(add)
        detector.files().forEach(add)
        return found.values.sorted { $0.size > $1.size }
    }
}

/// Finds cleanable items by what they are rather than where they are.
private struct Detector {
    let result: ScanResult
    let home: String
    let sharedTemp: String
    let owner: uid_t
    let now: Date
    let minimum: Int64

    /// Videos are only worth flagging when big: 100 MB at the default 20 MB minimum.
    private var videoMinimum: Int64 { minimum * 5 }

    /// Folders a project tool recreates; anything inside one of these is never suggested separately.
    private static let generatedNames: Set<String> = ["node_modules", ".next", ".turbo", ".nuxt", ".svelte-kit",
                                                      ".parcel-cache", ".angular", ".output", ".dart_tool",
                                                      "dist", "build", "target", "Pods", ".venv", "venv"]
    /// Document bundles (Photos, Final Cut, ...) look like folders but must stay whole.
    private static let bundleExtensions: Set<String> = ["app", "photoslibrary", "fcpbundle", "imovielibrary", "tvlibrary",
                                                        "musiclibrary", "screenstudio", "logicx", "band", "photolibrary",
                                                        "xcarchive", "bundle", "framework", "pkg"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "wmv", "flv", "webm", "mpg",
                                                       "mpeg", "ts", "m2ts", "vob", "3gp"]
    private static let installerExtensions: Set<String> = ["dmg", "pkg", "mpkg", "iso", "xip", "zip", "rar", "7z", "tar",
                                                           "gz", "tgz", "bz2", "xz", "apk", "aab", "ipa", "exe", "msi"]

    // MARK: Folders

    func folders() -> [Suggestion] {
        var out: [Suggestion] = []
        for node in result.index.values where node.isDirectory && node.size >= minimum && isUserArea(node.path) {
            if let suggestion = generatedFolder(node) ?? worktree(node) ?? tempLeftover(node) {
                out.append(suggestion)
            }
        }
        return out
    }

    private func generatedFolder(_ node: FSNode) -> Suggestion? {
        let parent = (node.path as NSString).deletingLastPathComponent
        let siblings = result.markers[parent] ?? []
        let inside = result.markers[node.path] ?? []
        let project = (parent as NSString).lastPathComponent
        func make(_ title: String, _ safety: Safety, _ note: String) -> Suggestion {
            Suggestion(path: node.path, title: "\(title) · \(project)", note: note, safety: safety, size: node.size)
        }
        let name = node.name
        let js = siblings.contains("package.json")
        let gradleOrFlutter = siblings.contains("build.gradle") || siblings.contains("build.gradle.kts") || siblings.contains("pubspec.yaml")
        if name == "node_modules" && js {
            return make("node_modules", .review, "Installed packages. Come back with npm/pnpm/yarn install; remove for projects you're not working on.")
        }
        if [".next", ".turbo", ".nuxt", ".svelte-kit", ".parcel-cache", ".angular", ".output"].contains(name) && js {
            return make("\(name) build cache", .safe, "Rebuilt on the next build or dev run. Stop the project's dev server first.")
        }
        if (name == "dist" || name == "build") && js {
            return make("\(name) output", .review, "Build output. Rebuilt by the project's build command.")
        }
        if name == "build" && gradleOrFlutter {
            return make("build output", .review, "Rebuilt on the next Gradle/Flutter build.")
        }
        if name == ".dart_tool" && siblings.contains("pubspec.yaml") {
            return make(".dart_tool", .safe, "Recreated by flutter pub get.")
        }
        if name == "target" && siblings.contains("Cargo.toml") {
            return make("Rust target", .review, "Rust build output. Rebuilt by cargo build (can take a while).")
        }
        if name == "Pods" && siblings.contains("Podfile") {
            return make("CocoaPods", .review, "Reinstalled by pod install.")
        }
        if [".venv", "venv", "env"].contains(name) && inside.contains("pyvenv.cfg") {
            return make("Python venv", .review, "Recreate it and reinstall the project's packages.")
        }
        return nil
    }

    /// A linked git worktree: a checkout whose `.git` is a file pointing into another repo's .git/worktrees.
    private func worktree(_ node: FSNode) -> Suggestion? {
        guard result.markers[node.path]?.contains(DiskScanner.gitFileMarker) == true,
              let link = try? String(contentsOfFile: node.path + "/.git", encoding: .utf8),
              link.hasPrefix("gitdir:") else { return nil }
        let gitdir = link.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard gitdir.contains("/worktrees/") else { return nil }  // submodules use .git/modules
        let repo = gitdir.components(separatedBy: "/.git/worktrees/").first.map { ($0 as NSString).lastPathComponent } ?? "repo"
        var title = "Git worktree · \(node.name)"
        var note: String
        if let head = try? String(contentsOfFile: gitdir + "/HEAD", encoding: .utf8) {
            let ref = head.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = ref.hasPrefix("ref: refs/heads/") ? String(ref.dropFirst("ref: refs/heads/".count)) : "detached"
            title += " (\(branch))"
            note = "Extra checkout of \(repo). Anything not committed and pushed in it is lost. Then run git worktree prune in \(repo)."
        } else {
            note = "Extra checkout of \(repo), whose repository is gone. Anything not committed and pushed in it is lost."
        }
        note += " Last changed \(age(of: node.path))."
        return Suggestion(path: node.path, title: title, note: note, safety: .review, size: node.size)
    }

    /// Items this user left in /tmp. Claude Code keeps one folder per session; each is offered separately.
    private func tempLeftover(_ node: FSNode) -> Suggestion? {
        guard node.path.hasPrefix(sharedTemp + "/") else { return nil }
        let parts = node.path.dropFirst(sharedTemp.count + 1).split(separator: "/")
        guard let top = parts.first, FS.info(sharedTemp + "/" + top)?.st_uid == owner else { return nil }
        if top.hasPrefix("claude-") {
            guard parts.count == 3 else { return nil }  // claude-<uid>/<project>/<session>
            // Claude Code names the project folder after its path with / turned into -.
            let homePrefix = home.replacingOccurrences(of: "/", with: "-") + "-"
            let project = parts[1].hasPrefix(homePrefix) ? parts[1].dropFirst(homePrefix.count) : parts[1]
            return Suggestion(path: node.path, title: "Claude Code session · \(project) · \(parts[2].prefix(8))",
                              note: "Scratch files and worktrees from a past Claude Code session, last changed \(age(of: node.path)). Skip the session you're running now.",
                              safety: .review, size: node.size)
        }
        guard parts.count == 1 else { return nil }
        return Suggestion(path: node.path, title: "Temporary files · \(node.name)",
                          note: "Left in /tmp by a tool or test run, last changed \(age(of: node.path)). macOS clears /tmp only on restart.",
                          safety: .review, size: node.size)
    }

    // MARK: Files

    func files() -> [Suggestion] {
        let downloads = [home + "/Downloads/", home + "/Desktop/"]
        var out: [Suggestion] = []
        for file in result.largeFiles where isUserArea(file.path) {
            let ext = (file.path as NSString).pathExtension.lowercased()
            let inDownloads = downloads.contains { file.path.hasPrefix($0) }
            let when = relative(file.modified)
            if Self.videoExtensions.contains(ext) && (file.size >= videoMinimum || inDownloads) {
                out.append(Suggestion(path: file.path, title: "Video · \(file.name)",
                                      note: "Saved \(when). Delete if you've watched it or keep a copy elsewhere.",
                                      safety: .review, size: file.size))
            } else if inDownloads && Self.installerExtensions.contains(ext) {
                out.append(Suggestion(path: file.path, title: "Installer or archive · \(file.name)",
                                      note: "Downloaded \(when). Not needed once the app is installed or the archive is unpacked.",
                                      safety: .review, size: file.size))
            } else if inDownloads {
                out.append(Suggestion(path: file.path, title: "Download · \(file.name)",
                                      note: "Downloaded \(when). Delete if you no longer need it.",
                                      safety: .review, size: file.size))
            }
        }
        return out
    }

    // MARK: Helpers

    /// Your own files: home (minus Library and hidden tool folders) and /tmp. Never app internals,
    /// document bundles, or things nested inside a generated folder.
    private func isUserArea(_ path: String) -> Bool {
        let base: String
        if path.hasPrefix(home + "/") { base = home } else if path.hasPrefix(sharedTemp + "/") { base = sharedTemp } else { return false }
        if path.hasPrefix(home + "/Library/") || path == home + "/Library" { return false }
        let parts = path.dropFirst(base.count + 1).split(separator: "/")
        for part in parts.dropLast() {
            if part.hasPrefix(".") || Self.generatedNames.contains(String(part)) { return false }
            if Self.bundleExtensions.contains((part as NSString).pathExtension.lowercased()) { return false }
        }
        return true
    }

    private func age(of path: String) -> String {
        guard let st = FS.info(path) else { return "a while ago" }
        return relative(Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
    }

    private func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}
