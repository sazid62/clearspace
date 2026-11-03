import AppKit

enum RemovalMode {
    case trash, permanent
}

struct RemovalItem {
    let path: String
    let size: Int64
    /// Set when a safety check refused the item before anything was touched.
    var refusal: String? = nil
}

struct RemovalOutcome: Identifiable {
    let path: String
    let size: Int64
    var error: String?
    var needsAdmin = false

    var id: String { path }
    var succeeded: Bool { error == nil }
}

enum AdminResult: Equatable {
    case completed, cancelled, failed(String)
}

enum FileRemover {
    /// Moves `path` to the Trash or deletes it. "~/.Trash" itself is emptied, never moved.
    static func remove(_ path: String, mode: RemovalMode) throws {
        if path == FS.trash {
            for name in FS.listNames(path) { try deletePermanently(path + "/" + name) }
            return
        }
        switch mode {
        case .trash: try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
        case .permanent: try deletePermanently(path)
        }
    }

    static func attempt(_ item: RemovalItem, mode: RemovalMode) -> RemovalOutcome {
        var outcome = RemovalOutcome(path: item.path, size: item.size)
        if let refusal = item.refusal {
            outcome.error = refusal
            return outcome
        }
        do {
            try remove(item.path, mode: mode)
        } catch {
            outcome.error = (error as NSError).localizedDescription
            outcome.needsAdmin = isPermissionError(error)
        }
        return outcome
    }

    private static func deletePermanently(_ path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch let error where isPermissionError(error) && FS.isDirectory(path) {
            // Read-only folders (Go's module cache, for one) can't be emptied until they're writable.
            makeWritable(path)
            try FileManager.default.removeItem(atPath: path)
        }
    }

    private static func makeWritable(_ path: String) {
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["-R", "u+w", path]
        do {
            try chmod.run()
            chmod.waitUntilExit()
        } catch {}
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    /// Runs the removal as root behind the standard macOS administrator prompt.
    /// Callers re-check which paths are gone afterwards; a failing command doesn't stop the rest.
    @MainActor
    static func removeAsAdministrator(_ paths: [String], mode: RemovalMode) -> AdminResult {
        var reserved = Set<String>()
        let commands = paths.map { path -> String in
            switch mode {
            case .permanent:
                return "/bin/rm -rf \(shellQuoted(path))"
            case .trash:
                return "/bin/mv -n \(shellQuoted(path)) \(shellQuoted(trashDestination(for: path, reserved: &reserved)))"
            }
        }
        let source = "do shell script \"\(appleScriptEscaped(commands.joined(separator: "; ")))\" with administrator privileges"
        var errorInfo: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .completed }
        if (errorInfo[NSAppleScript.errorNumber] as? Int) == -128 { return .cancelled }
        return .failed(errorInfo[NSAppleScript.errorMessage] as? String ?? "The administrator command failed.")
    }

    private static func trashDestination(for path: String, reserved: inout Set<String>) -> String {
        let name = (path as NSString).lastPathComponent
        var candidate = FS.trash + "/" + name
        var copy = 2
        while FS.exists(candidate) || reserved.contains(candidate) {
            candidate = FS.trash + "/" + name + " \(copy)"
            copy += 1
        }
        reserved.insert(candidate)
        return candidate
    }

    static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Live state of a removal job; drives the progress and summary panel.
struct RemovalProgress {
    let mode: RemovalMode
    let total: Int
    var current = ""
    var outcomes: [RemovalOutcome] = []
    var isRunning = true
    var isElevating = false
    var adminError: String?

    var completed: Int { outcomes.count }
    var removed: [RemovalOutcome] { outcomes.filter(\.succeeded) }
    var removedSize: Int64 { removed.reduce(0) { $0 + $1.size } }
    var failures: [RemovalOutcome] { outcomes.filter { !$0.succeeded } }
    var canRetryAsAdmin: Bool { !isRunning && failures.contains(where: \.needsAdmin) }

    /// Re-checks the items handed to the administrator prompt; returns the paths that are gone now.
    mutating func reconcile(after result: AdminResult) -> [String] {
        var gone: [String] = []
        for i in outcomes.indices where outcomes[i].needsAdmin {
            if !FS.exists(outcomes[i].path) {
                outcomes[i].error = nil
                outcomes[i].needsAdmin = false
                gone.append(outcomes[i].path)
            } else if result != .cancelled {
                outcomes[i].error = "Still there after the administrator retry. macOS may be protecting it."
                outcomes[i].needsAdmin = false
            }
        }
        if case .failed(let message) = result, gone.isEmpty { adminError = message }
        return gone
    }
}

enum RemovalRunner {
    /// Removes items one at a time off the main thread, reporting each step on the main actor.
    static func run(_ items: [RemovalItem], mode: RemovalMode,
                    onStart: @escaping @MainActor (String) -> Void,
                    onOutcome: @escaping @MainActor (RemovalOutcome) -> Void,
                    onFinish: @escaping @MainActor () -> Void) {
        Task.detached(priority: .userInitiated) {
            for item in items {
                await onStart(item.path)
                let outcome = FileRemover.attempt(item, mode: mode)
                await onOutcome(outcome)
            }
            await onFinish()
        }
    }
}
