import Foundation
@testable import Clearspace

/// A throwaway folder tree under the temp directory, deleted when the value goes away.
final class TempTree {
    let root: String

    init() throws {
        root = FS.realPath(NSTemporaryDirectory()) + "/clearspace-tests-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+w", root]
        try? chmod.run()
        chmod.waitUntilExit()
        try? FileManager.default.removeItem(atPath: root)
    }

    @discardableResult
    func dir(_ relative: String) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    /// Writes real (non-sparse) bytes so the file occupies blocks on disk.
    @discardableResult
    func file(_ relative: String, bytes: Int = 16) throws -> String {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            for i in buffer.indices { buffer[i] = UInt8(truncatingIfNeeded: i &* 31 &+ 7) }
        }
        try data.write(to: URL(fileURLWithPath: path))
        return path
    }
}
