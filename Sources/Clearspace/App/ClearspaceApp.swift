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
        CommandGroup(replacing: .newItem) {}
        CommandMenu("Tools") {
            ForEach(Tool.allCases) { tool in
                Button(tool.title) { model.tool = tool }
                    .keyboardShortcut(tool.shortcut, modifiers: .command)
            }
            Divider()
            Button("Scan Disk") {
                model.tool = .cleaner
                model.cleaner.startScan()
            }
            .keyboardShortcut("r")
            Button("Choose App to Uninstall…") {
                model.tool = .uninstaller
                model.uninstaller.chooseApp()
            }
            .keyboardShortcut("o")
        }
        CommandGroup(replacing: .help) {
            Link("Clearspace on GitHub", destination: URL(string: "https://github.com/sazid62/clearspace")!)
        }
    }
}
