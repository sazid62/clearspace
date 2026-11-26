import Foundation

/// Thin, fast wrappers over POSIX file APIs. Paths stay plain strings so they round-trip
/// exactly (Foundation's URL helpers strip the /private prefix, which breaks prefix checks).
enum FS {
    static let home = NSHomeDirectory()
    static let trash = home + "/.Trash"
    /// The machine-wide temp folder (/tmp). Tools like Claude Code, git worktrees and test runs leave folders here.
    static let sharedTemp = realPath("/tmp")

    /// The per-user temp root (parent of DARWIN_USER_TEMP_DIR), which holds T/, C/ and X/.
    static let userTempRoot: String = {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        var temp = length > 0 ? buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) } : NSTemporaryDirectory()
        while temp.count > 1 && temp.hasSuffix("/") { temp.removeLast() }
        return realPath((temp as NSString).deletingLastPathComponent)
    }()

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// lstat: describes a symlink itself rather than what it points to.
    static func info(_ path: String) -> stat? {
        var st = stat()
        return lstat(path, &st) == 0 ? st : nil
    }

    static func exists(_ path: String) -> Bool { info(path) != nil }

    static func isDirectory(_ path: String) -> Bool {
        guard let st = info(path) else { return false }
        return st.st_mode & S_IFMT == S_IFDIR
    }

    static func entryName(_ entry: UnsafeMutablePointer<dirent>) -> String {
        let length = Int(entry.pointee.d_namlen)
        return withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix(length), as: UTF8.self) }
    }

    /// A directory on a different device from its parent: something is mounted on it right now.
    static func isMountPoint(_ path: String) -> Bool {
        guard let st = info(path), st.st_mode & S_IFMT == S_IFDIR,
              let parent = info((path as NSString).deletingLastPathComponent) else { return false }
        return st.st_dev != parent.st_dev
    }

    static func listNames(_ dir: String) -> [String] {
        guard let handle = opendir(dir) else { return [] }
        defer { closedir(handle) }
        var names: [String] = []
        while let entry = readdir(handle) {
            let name = entryName(entry)
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }

    /// Bytes actually used on disk (like `du`): hard links count once and other volumes are skipped.
    static func allocatedSize(_ path: String) -> Int64 {
        guard let top = info(path) else { return 0 }
        guard top.st_mode & S_IFMT == S_IFDIR else { return Int64(top.st_blocks) * 512 }
        var total: Int64 = 0
        var seen = Set<FileID>()
        var pending = [path]
        while let dir = pending.popLast() {
            guard let handle = opendir(dir) else { continue }
            let fd = dirfd(handle)
            while let entry = readdir(handle) {
                let name = entryName(entry)
                if name == "." || name == ".." { continue }
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    if st.st_dev == top.st_dev { pending.append(dir + "/" + name) }
                } else if st.st_nlink < 2 || seen.insert(FileID(st)).inserted {
                    total += Int64(st.st_blocks) * 512
                }
            }
            closedir(handle)
        }
        return total
    }

    static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

struct FileID: Hashable {
    let device: Int32
    let inode: UInt64

    init(_ st: stat) {
        device = st.st_dev
        inode = st.st_ino
    }
}
