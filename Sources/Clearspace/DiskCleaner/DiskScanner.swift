import Foundation

final class FSNode: Identifiable {
    let path: String
    let name: String
    let isDirectory: Bool
    var size: Int64
    /// Total of the children below the minimum size; they're folded into one "small items" row.
    var smallItems: Int64 = 0
    var children: [FSNode] = []
    weak var parent: FSNode?

    var id: String { path }

    init(path: String, name: String, isDirectory: Bool, size: Int64 = 0) {
        self.path = path
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

struct LargeFile: Identifiable {
    let path: String
    let size: Int64
    let modified: Date

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
}

struct ScanRoot {
    let path: String
    let title: String

    static var defaults: [ScanRoot] {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["CLEARSPACE_SCAN_ROOTS"] {
            return override.split(separator: ":").map { ScanRoot(path: String($0), title: ($0 as NSString).lastPathComponent) }
        }
        #endif
        return [ScanRoot(path: FS.home, title: "Home Folder"),
         ScanRoot(path: "/Applications", title: "Applications"),
         ScanRoot(path: FS.userTempRoot, title: "Temporary Files"),
         ScanRoot(path: FS.sharedTemp, title: "Shared Temporary Files")]
    }
}

final class ScanResult {
    let root: FSNode
    private(set) var index: [String: FSNode]
    private(set) var largeFiles: [LargeFile]
    /// Folder -> marker entries it directly contains (see DiskScanner.markerNames).
    let markers: [String: Set<String>]
    let fileCount: Int
    let duration: TimeInterval

    init(root: FSNode, index: [String: FSNode], largeFiles: [LargeFile], markers: [String: Set<String>] = [:],
         fileCount: Int, duration: TimeInterval) {
        self.root = root
        self.index = index
        self.largeFiles = largeFiles
        self.markers = markers
        self.fileCount = fileCount
        self.duration = duration
    }

    /// Takes a deleted path out of the tree and subtracts its size from every ancestor.
    func drop(_ path: String) {
        largeFiles.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        guard let node = index[path] else { return }
        let freed = node.size
        if path == FS.trash {
            // The Trash is emptied, not removed.
            node.children.forEach(unindex)
            node.children = []
            node.smallItems = 0
            node.size = 0
        } else {
            node.parent?.children.removeAll { $0 === node }
            unindex(node)
        }
        var ancestor = node.parent
        while let current = ancestor {
            current.size = max(0, current.size - freed)
            current.children.sort { $0.size > $1.size }
            ancestor = current.parent
        }
    }

    private func unindex(_ node: FSNode) {
        index[node.path] = nil
        node.children.forEach(unindex)
    }
}

/// Measures every file under the roots and keeps a size tree of the items worth showing.
/// Unchecked Sendable: all state is touched only by the scanning thread, except the lock-guarded cancel flag.
final class DiskScanner: @unchecked Sendable {
    static let defaultMinimumItemSize: Int64 = 20 * 1024 * 1024
    /// Entries that tell what a folder is (a project, a git worktree, a Python venv...).
    /// A `.git` that is a file, not a folder, is recorded as `gitFileMarker`.
    static let markerNames: Set<String> = ["package.json", "Cargo.toml", "Podfile", "pyvenv.cfg",
                                           "build.gradle", "build.gradle.kts", "pubspec.yaml"]
    static let gitFileMarker = ".git (file)"

    let roots: [ScanRoot]
    let minimumItemSize: Int64
    /// Called on the scanning thread with (files checked, current folder), at most ~12 times a second.
    var onProgress: ((Int, String) -> Void)?

    private var index: [String: FSNode] = [:]
    private var largeFiles: [LargeFile] = []
    private var markers: [String: Set<String>] = [:]
    private var seen = Set<FileID>()
    private var fileCount = 0
    private var lastReport: CFAbsoluteTime = 0
    private let cancelLock = NSLock()
    private var cancelled = false

    init(roots: [ScanRoot] = ScanRoot.defaults, minimumItemSize: Int64 = DiskScanner.defaultMinimumItemSize) {
        self.roots = roots
        self.minimumItemSize = minimumItemSize
    }

    func cancel() { cancelLock.withLock { cancelled = true } }
    private var isCancelled: Bool { cancelLock.withLock { cancelled } }

    /// Walks every root and returns nil if cancelled. Recursive: run it on a thread with a large stack.
    func run() -> ScanResult? {
        let started = Date()
        let root = FSNode(path: "/", name: "Scanned folders", isDirectory: true)
        for scanRoot in roots {
            var st = stat()
            guard stat(scanRoot.path, &st) == 0 else { continue }
            let node = scan(scanRoot.path, name: scanRoot.title, device: st.st_dev)
            if isCancelled { return nil }
            node.parent = root
            root.children.append(node)
            root.size += node.size
            index[node.path] = node
        }
        root.children.sort { $0.size > $1.size }
        largeFiles.sort { $0.size > $1.size }
        if largeFiles.count > 3000 { largeFiles.removeSubrange(3000...) }
        return ScanResult(root: root, index: index, largeFiles: largeFiles, markers: markers, fileCount: fileCount,
                          duration: Date().timeIntervalSince(started))
    }

    private func scan(_ path: String, name: String, device: dev_t) -> FSNode {
        let node = FSNode(path: path, name: name, isDirectory: true)
        guard !isCancelled, let handle = opendir(path) else { return node }
        let fd = dirfd(handle)
        var folders: [(path: String, name: String)] = []
        while let entry = readdir(handle) {
            let entryName = FS.entryName(entry)
            if entryName == "." || entryName == ".." { continue }
            var st = stat()
            guard fstatat(fd, entryName, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let childPath = path + "/" + entryName
            if st.st_mode & S_IFMT == S_IFDIR {
                // Other volumes mounted inside the tree (e.g. ~/OrbStack) are not this disk.
                if st.st_dev == device { folders.append((childPath, entryName)) }
                continue
            }
            if entryName == ".git" {
                if st.st_mode & S_IFMT == S_IFREG { markers[path, default: []].insert(Self.gitFileMarker) }
            } else if Self.markerNames.contains(entryName) {
                markers[path, default: []].insert(entryName)
            }
            fileCount += 1
            if fileCount & 1023 == 0 { report(path) }
            if st.st_nlink > 1 && !seen.insert(FileID(st)).inserted { continue }  // hard link already counted
            let size = Int64(st.st_blocks) * 512
            node.size += size
            if size >= minimumItemSize {
                attach(FSNode(path: childPath, name: entryName, isDirectory: false, size: size), to: node)
                if st.st_mode & S_IFMT == S_IFREG {
                    let modified = Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec))
                    largeFiles.append(LargeFile(path: childPath, size: size, modified: modified))
                }
            } else {
                node.smallItems += size
            }
        }
        closedir(handle)
        for folder in folders {
            let child = scan(folder.path, name: folder.name, device: device)
            node.size += child.size
            if child.size >= minimumItemSize {
                attach(child, to: node)
            } else {
                node.smallItems += child.size
            }
        }
        node.children.sort { $0.size > $1.size }
        return node
    }

    private func attach(_ child: FSNode, to parent: FSNode) {
        child.parent = parent
        parent.children.append(child)
        index[child.path] = child
    }

    private func report(_ folder: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastReport >= 0.08 else { return }
        lastReport = now
        onProgress?(fileCount, folder)
    }
}
