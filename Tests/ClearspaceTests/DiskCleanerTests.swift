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
