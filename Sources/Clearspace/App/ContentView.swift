import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            switch model.tool {
            case .cleaner: DiskCleanerView()
            case .uninstaller: UninstallerView()
            }
        }
        .frame(minWidth: 1000, minHeight: 620)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            model.refresh()
        }
        #if DEBUG
        .task { SnapshotDriver.runIfRequested(model) }
        #endif
    }
}

private struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List(selection: selection) {
            Section("Tools") {
                ForEach(Tool.allCases) { tool in
                    Label(tool.title, systemImage: tool.symbol)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { SidebarFooter() }
    }

    private var selection: Binding<Tool?> {
        Binding(get: { model.tool }, set: { if let tool = $0 { model.tool = tool } })
    }
}

private struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "internaldrive.fill").foregroundStyle(.secondary)
                    Text(model.storage.volumeName).font(.callout.weight(.medium)).lineLimit(1)
                }
                UsageBar(fraction: model.storage.usedFraction).frame(height: 6)
                Text("\(Bytes.format(model.storage.available)) available of \(Bytes.format(model.storage.total))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if model.hasFullDiskAccess {
                Label("Full Disk Access on", systemImage: "checkmark.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Button { Permissions.openFullDiskAccessSettings() } label: {
                    Label("Grant Full Disk Access", systemImage: "exclamationmark.shield.fill")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .help("Lets Clearspace see every folder without repeated permission prompts")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
