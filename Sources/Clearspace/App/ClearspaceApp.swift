import SwiftUI

@main
struct ClearspaceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        Window("Clearspace", id: "main") {
            ContentView()
                .environment(model)
                .environment(model.cleaner)
                .environment(model.uninstaller)
                .environment(model.terminal)
        }
        .defaultSize(width: 1240, height: 780)
        .commands { AppCommands(model: model) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct AppCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") {
                model.go(to: .terminal)
                model.terminal.activate()
                model.terminal.newTab()
            }
            .keyboardShortcut("t")
            Button("New Group…") {
                model.go(to: .terminal)
                model.terminal.activate()
                model.terminal.editing = .newGroup(movingTab: nil)
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(before: .windowArrangement) {
            ForEach(Space.allCases) { space in
                Button(space.title) { model.go(to: space) }
                    .keyboardShortcut(space.shortcut, modifiers: .control)
            }
            Button("Next Space") { model.showSpace(offset: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.control, .command])
            Button("Previous Space") { model.showSpace(offset: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.control, .command])
            Divider()
        }
        CommandMenu("Terminal") {
            Button("Next Tab") { model.terminal.selectAdjacent(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(model.space != .terminal)
            Button("Previous Tab") { model.terminal.selectAdjacent(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(model.space != .terminal)
            Divider()
            Button("Rename Tab…") {
                if let id = model.terminal.selectedTabID { model.terminal.editing = .renameTab(id) }
            }
            .disabled(model.space != .terminal || model.terminal.selectedTab == nil)
            Button("Startup Command…") {
                if let id = model.terminal.selectedTabID { model.terminal.editing = .startupCommand(id) }
            }
            .disabled(model.space != .terminal || model.terminal.selectedTab == nil)
            Button(model.terminal.selectedTab?.isPinned == true ? "Unpin Tab" : "Pin Tab") {
                if let id = model.terminal.selectedTabID { model.terminal.togglePin(id) }
            }
            .disabled(model.space != .terminal || model.terminal.selectedTab == nil)
            Divider()
            Button("Close Tab") { model.terminal.closeSelected() }
                .keyboardShortcut("w", modifiers: [.command, .shift])
                .disabled(model.space != .terminal || model.terminal.selectedTab == nil)
        }
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                Button(tool.title) { model.show(tool) }
                    .keyboardShortcut(tool.shortcut, modifiers: .command)
            }
            Divider()
            Button("Scan Disk") {
                model.show(.cleaner)
                model.cleaner.startScan()
            }
            .keyboardShortcut("r")
            Button("Choose App to Uninstall…") {
                model.show(.uninstaller)
                model.uninstaller.chooseApp()
            }
            .keyboardShortcut("o")
        }
        CommandGroup(replacing: .help) {
            Link("Clearspace on GitHub", destination: URL(string: "https://github.com/sazid62/clearspace")!)
        }
    }
}
