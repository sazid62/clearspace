import AppKit
import Darwin
import SwiftTerm

/// One tab's shell: a SwiftTerm view plus the child process behind it. Lives as long as the tab,
/// across tab and space switches, so running commands keep going while you look elsewhere.
@MainActor
final class TerminalSession: NSObject {
    let id: UUID
    let view: LocalProcessTerminalView
    private(set) var isRunning = false

    var onExit: ((Int32?) -> Void)?

    init(id: UUID) {
        self.id = id
        var options = TerminalOptions.default
        options.scrollback = 10_000
        view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500), font: Self.font, options: options)
        super.init()
        view.processDelegate = self
        view.optionAsMetaKey = false  // keep Option for typing characters such as # and €, like Terminal.app
        applyAppearance(dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
    }

    static let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    func applyAppearance(dark: Bool) {
        view.nativeBackgroundColor = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 1, alpha: 1)
        view.nativeForegroundColor = dark ? NSColor(white: 0.9, alpha: 1) : NSColor(white: 0.1, alpha: 1)
    }

    /// Shows the previous session's output dimmed, then a divider, before the new shell prints anything.
    func showRestored(_ text: String, savedAt: Date?) {
        let body = text.replacingOccurrences(of: "\n", with: "\r\n")
        let when = savedAt.map { " · " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
        view.feed(text: "\u{1b}[2m" + body + "\u{1b}[0m\r\n")
        view.feed(text: "\u{1b}[2m──── restored\(when) ────\u{1b}[0m\r\n")
    }

    func start(directory: String, startupCommand: String?) {
        let shell = Self.loginShell
        var isDir: ObjCBool = false
        let cwd = FileManager.default.fileExists(atPath: directory, isDirectory: &isDir) && isDir.boolValue
            ? directory : NSHomeDirectory()
        // Login shell ("-zsh") so the user's profile sets PATH, as Terminal.app does.
        view.startProcess(
            executable: shell,
            args: [],
            environment: Self.environment,
            execName: "-" + (shell as NSString).lastPathComponent,
            currentDirectory: cwd
        )
        isRunning = true
        if let command = startupCommand?.trimmingCharacters(in: .whitespacesAndNewlines), !command.isEmpty {
            // The pty buffers this until the shell reads its first line.
            view.send(txt: command + "\r")
        }
    }

    func terminate() {
        guard isRunning else { return }
        isRunning = false
        view.terminate()
    }

    /// The shell's working directory, read from the kernel, so it works without any shell setup.
    var currentDirectory: String? {
        guard isRunning, let pid = view.process?.shellPid else { return nil }
        return Self.workingDirectory(of: pid)
    }

    /// The normal-screen buffer as text (full-screen apps such as vim use the other buffer and are skipped).
    var scrollbackText: String {
        String(decoding: view.getTerminal().getBufferAsData(kind: .normal), as: UTF8.self)
    }

    // MARK: - Process helpers

    static var loginShell: String {
        if let entry = getpwuid(getuid()), let raw = entry.pointee.pw_shell {
            let shell = String(cString: raw)
            if FileManager.default.isExecutableFile(atPath: shell) { return shell }
        }
        return "/bin/zsh"
    }

    static var environment: [String] {
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Clearspace"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        for key in env.keys where key.hasPrefix("CLEARSPACE_") { env[key] = nil }
        return env.map { "\($0.key)=\($0.value)" }
    }

    nonisolated static func workingDirectory(of pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { raw in
            String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }
}

extension TerminalSession: LocalProcessTerminalViewDelegate {
    nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}

    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.isRunning = false
                self.onExit?(exitCode)
            }
        }
    }
}
