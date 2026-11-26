import Foundation
import Testing
@testable import Clearspace

struct DiskScannerTests {
    private let megabyte = 1024 * 1024

    @Test func buildsASizeTreeAndFoldsSmallItems() throws {
        let tree = try TempTree()
        let a = try tree.file("data/big/a.bin", bytes: 3 * megabyte)
        try tree.file("data/big/b.bin", bytes: 3 * megabyte)
        try tree.file("data/small/c.bin", bytes: 100 * 1024)
        // A hard link to a.bin must not be counted twice.
        try tree.dir("data/links")
        try FileManager.default.linkItem(atPath: a, toPath: tree.root + "/data/links/a-link.bin")

        let rootPath = tree.root + "/data"
        let scanner = DiskScanner(roots: [ScanRoot(path: rootPath, title: "Data")], minimumItemSize: Int64(megabyte))
        let result = try #require(scanner.run())
        let data = try #require(result.index[rootPath])

        #expect(data.name == "Data")
        #expect(result.fileCount == 4)
        #expect(result.largeFiles.count == 2)
        #expect(data.size >= Int64(6 * megabyte) && data.size < Int64(7 * megabyte))
        // big/ is shown; small/ (100 KB) is folded into the "small items" total.
        #expect(data.children.contains { $0.path == rootPath + "/big" })
        #expect(result.index[rootPath + "/small"] == nil)
        #expect(data.smallItems > 0)
        #expect(data.children.map(\.size) == data.children.map(\.size).sorted(by: >))
    }

    @Test func droppingAnItemShrinksItsAncestors() throws {
        let tree = try TempTree()
        let a = try tree.file("data/big/a.bin", bytes: 3 * megabyte)
        try tree.file("data/big/b.bin", bytes: 3 * megabyte)
        let rootPath = tree.root + "/data"
        let result = try #require(DiskScanner(roots: [ScanRoot(path: rootPath, title: "Data")],
                                              minimumItemSize: Int64(megabyte)).run())
        let before = try #require(result.index[rootPath]).size
        let fileSize = try #require(result.index[a]).size

        result.drop(a)

        #expect(result.index[a] == nil)
        #expect(result.largeFiles.allSatisfy { $0.path != a })
        #expect(try #require(result.index[rootPath]).size == before - fileSize)
        #expect(result.root.size == before - fileSize)
    }
}

struct CleanerGuardTests {
    @Test func protectsTopLevelAndSensitiveFolders() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let temp = try tree.dir("tmp")
        try tree.dir("home/Library/Caches/go-build")
        try tree.file("home/Library/Keychains/login.keychain-db")
        try tree.file("home/.ssh/id_ed25519")
        try tree.dir("home/Documents")
        let outside = try tree.dir("elsewhere/thing")
        let guardrail = CleanerGuard(roots: [home, temp], home: home, tempRoot: temp, appBundle: tree.root + "/Clearspace.app")

        #expect(guardrail.refusal(for: home + "/Library/Caches/go-build") == nil)
        #expect(guardrail.refusal(for: home) != nil)
        #expect(guardrail.refusal(for: home + "/Documents") != nil)
        #expect(guardrail.refusal(for: home + "/Library/Caches") != nil)
        #expect(guardrail.refusal(for: home + "/Library/Keychains/login.keychain-db") != nil)
        #expect(guardrail.refusal(for: home + "/.ssh/id_ed25519") != nil)
        #expect(guardrail.refusal(for: outside) != nil)
        #expect(guardrail.refusal(for: home + "/missing") == "It no longer exists.")
    }
}

struct FileRemoverTests {
    @Test func deletesReadOnlyFolders() throws {
        let tree = try TempTree()
        let folder = try tree.dir("cache")
        try tree.file("cache/pkg/mod/file.go")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder + "/pkg/mod")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: folder + "/pkg")

        try FileRemover.remove(folder, mode: .permanent)

        #expect(!FS.exists(folder))
    }

    @Test func quotesPathsForTheAdminShell() {
        #expect(FileRemover.shellQuoted("/tmp/it's here") == "'/tmp/it'\\''s here'")
        #expect(FileRemover.appleScriptEscaped(#"a"b\c"#) == #"a\"b\\c"#)
    }

    @Test func reportsPermissionErrors() {
        let posix = NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
        let wrapped = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError, userInfo: [NSUnderlyingErrorKey: posix])
        #expect(FileRemover.isPermissionError(wrapped))
        #expect(!FileRemover.isPermissionError(NSError(domain: NSCocoaErrorDomain, code: NSFileNoSuchFileError)))
    }
}

struct SuggestionDetectorTests {
    private let megabyte = 1024 * 1024

    /// Scans a fake home and /tmp at a 1 MB minimum and returns suggestions keyed by path.
    private func suggest(_ tree: TempTree, owner: uid_t = getuid()) throws -> [String: Suggestion] {
        let home = tree.root + "/home", temp = tree.root + "/tmp"
        let scanner = DiskScanner(roots: [ScanRoot(path: home, title: "Home"), ScanRoot(path: temp, title: "Tmp")],
                                  minimumItemSize: Int64(megabyte))
        let result = try #require(scanner.run())
        let list = SuggestionCatalog.suggestions(in: result, home: home, sharedTemp: temp, owner: owner,
                                                 minimum: Int64(megabyte))
        return Dictionary(uniqueKeysWithValues: list.map { ($0.path, $0) })
    }

    @Test func findsProjectBuildFolders() throws {
        let tree = try TempTree()
        let app = tree.root + "/home/Documents/app"
        try tree.file("home/Documents/app/package.json")
        try tree.file("home/Documents/app/node_modules/react/index.js", bytes: 2 * megabyte)
        try tree.file("home/Documents/app/node_modules/x/node_modules/y/big.js", bytes: 2 * megabyte)
        try tree.file("home/Documents/app/.next/cache/a.bin", bytes: 2 * megabyte)
        try tree.file("home/Documents/app/.next/standalone/node_modules/n.js", bytes: 2 * megabyte)
        try tree.file("home/Documents/app/dist/main.js", bytes: 2 * megabyte)
        try tree.file("home/Documents/rust/Cargo.toml")
        try tree.file("home/Documents/rust/target/debug/bin", bytes: 2 * megabyte)
        try tree.file("home/Documents/py/.venv/pyvenv.cfg")
        try tree.file("home/Documents/py/.venv/lib/site.bin", bytes: 2 * megabyte)
        // Not projects: no package.json, inside Library, inside a hidden tool folder.
        try tree.file("home/Documents/loose/node_modules/a.js", bytes: 2 * megabyte)
        try tree.file("home/Documents/loose/.next/a.bin", bytes: 2 * megabyte)
        try tree.file("home/Library/Application Support/Code/package.json")
        try tree.file("home/Library/Application Support/Code/node_modules/a.js", bytes: 2 * megabyte)
        try tree.file("home/.vscode/extensions/ext/package.json")
        try tree.file("home/.vscode/extensions/ext/node_modules/a.js", bytes: 2 * megabyte)

        let found = try suggest(tree)

        #expect(found[app + "/node_modules"]?.safety == .review)
        #expect(found[app + "/.next"]?.safety == .safe)
        #expect(found[app + "/dist"]?.safety == .review)
        #expect(found[tree.root + "/home/Documents/rust/target"] != nil)
        #expect(found[tree.root + "/home/Documents/py/.venv"] != nil)
        #expect(found[app + "/node_modules/x/node_modules"] == nil)
        #expect(found[app + "/.next/standalone/node_modules"] == nil)
        #expect(found[tree.root + "/home/Documents/loose/node_modules"] == nil)
        #expect(found[tree.root + "/home/Documents/loose/.next"] == nil)
        #expect(found[tree.root + "/home/Library/Application Support/Code/node_modules"] == nil)
        #expect(found[tree.root + "/home/.vscode/extensions/ext/node_modules"] == nil)
    }

    @Test func findsGitWorktreesButNotSubmodules() throws {
        let tree = try TempTree()
        let gitdir = try tree.dir("home/Documents/repo/.git/worktrees/wt")
        try "ref: refs/heads/feat/x\n".write(toFile: gitdir + "/HEAD", atomically: true, encoding: .utf8)
        let worktree = try tree.dir("tmp/wt")
        try "gitdir: \(gitdir)\n".write(toFile: worktree + "/.git", atomically: true, encoding: .utf8)
        try tree.file("tmp/wt/src/big.bin", bytes: 2 * megabyte)
        let orphan = try tree.dir("home/Documents/orphan")
        try "gitdir: /nowhere/repo/.git/worktrees/orphan\n".write(toFile: orphan + "/.git", atomically: true, encoding: .utf8)
        try tree.file("home/Documents/orphan/big.bin", bytes: 2 * megabyte)
        let submodule = try tree.dir("home/Documents/repo/vendor/lib")
        try "gitdir: ../../.git/modules/lib\n".write(toFile: submodule + "/.git", atomically: true, encoding: .utf8)
        try tree.file("home/Documents/repo/vendor/lib/big.bin", bytes: 2 * megabyte)

        let found = try suggest(tree)

        let wt = try #require(found[worktree])
        #expect(wt.title.contains("feat/x"))
        #expect(wt.note.contains("repo"))
        #expect(wt.safety == .review)
        #expect(found[orphan]?.note.contains("gone") == true)
        #expect(found[submodule] == nil)
    }

    @Test func findsTempLeftoversPerClaudeSession() throws {
        let tree = try TempTree()
        try tree.file("tmp/claude-501/-Users-me-proj/session-a/scratchpad/big.bin", bytes: 2 * megabyte)
        try tree.file("tmp/claude-501/-Users-me-proj/session-b/scratchpad/big.bin", bytes: 2 * megabyte)
        try tree.file("tmp/some-tool-run/big.bin", bytes: 2 * megabyte)

        let found = try suggest(tree)
        let sessions = tree.root + "/tmp/claude-501/-Users-me-proj"

        #expect(found[sessions + "/session-a"]?.title.contains("-Users-me-proj") == true)
        #expect(found[sessions + "/session-b"] != nil)
        #expect(found[sessions] == nil)
        #expect(found[tree.root + "/tmp/some-tool-run"] != nil)
        // Another account's /tmp items are never offered.
        #expect(try suggest(tree, owner: getuid() + 1)[tree.root + "/tmp/some-tool-run"] == nil)
    }

    @Test func findsVideosAndDownloads() throws {
        let tree = try TempTree()
        let movie = try tree.file("home/Downloads/Movie.2024.mkv", bytes: 6 * megabyte)
        let dmg = try tree.file("home/Downloads/Dia.dmg", bytes: 2 * megabyte)
        let other = try tree.file("home/Downloads/dataset.csv", bytes: 2 * megabyte)
        let clip = try tree.file("home/Movies/clip.mov", bytes: 6 * megabyte)
        let shortClip = try tree.file("home/Movies/short.mov", bytes: 2 * megabyte)
        let inLibrary = try tree.file("home/Library/Caches/x.mp4", bytes: 6 * megabyte)
        let inBundle = try tree.file("home/Pictures/P.photoslibrary/originals/a.mov", bytes: 6 * megabyte)

        let found = try suggest(tree)

        #expect(found[movie]?.title.hasPrefix("Video") == true)
        #expect(found[dmg]?.title.hasPrefix("Installer") == true)
        #expect(found[other]?.title.hasPrefix("Download") == true)
        #expect(found[clip] != nil)
        #expect(found[shortClip] == nil)
        #expect(found[inLibrary] == nil)
        #expect(found[inBundle] == nil)
        #expect(found.values.allSatisfy { $0.safety == .review || $0.path.hasSuffix(".next") })
    }
}

struct SharedTempGuardTests {
    @Test func protectsTmpAndOtherUsersItems() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let shared = try tree.dir("tmp")
        let mine = try tree.dir("tmp/claude-501/session")
        func guardrail(_ owner: uid_t) -> CleanerGuard {
            CleanerGuard(roots: [home, shared], home: home, tempRoot: tree.root + "/vt", sharedTemp: shared,
                         appBundle: tree.root + "/Clearspace.app", owner: owner)
        }

        #expect(guardrail(getuid()).refusal(for: mine) == nil)
        #expect(guardrail(getuid()).refusal(for: shared) != nil)
        #expect(guardrail(getuid() + 1).refusal(for: mine) == "It belongs to another user.")
    }
}
