import SwiftUI

/// A model that runs removal jobs and exposes their progress to the shared panel.
@MainActor
protocol RemovalHost: AnyObject {
    var removal: RemovalProgress? { get }
    func retryFailuresAsAdmin()
    func finishRemoval()
}

/// Covers the tool with a modal progress/summary panel while a removal job exists.
/// An in-window overlay rather than a sheet, so it can follow alerts and sheets without clashing.
struct RemovalOverlay<Host: RemovalHost>: ViewModifier {
    let host: Host

    func body(content: Content) -> some View {
        let isActive = host.removal != nil
        content
            .overlay {
                if let progress = host.removal {
                    ZStack {
                        Color.black.opacity(0.18)
                            .contentShape(Rectangle())
                            .onTapGesture {}
                        RemovalPanel(progress: progress, host: host)
                            .padding(24)
                            .frame(width: 480)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                            .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
                    }
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isActive)
    }
}

private struct RemovalPanel<Host: RemovalHost>: View {
    let progress: RemovalProgress
    let host: Host

    var body: some View {
        if progress.isRunning {
            running
        } else {
            summary
        }
    }

    private var running: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(progress.mode == .trash ? "Moving to Trash…" : "Deleting…")
                .font(.title3.weight(.semibold))
            ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
            HStack {
                Text(FS.abbreviate(progress.current)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(min(progress.completed + 1, progress.total)) of \(progress.total)").monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            if progress.mode == .permanent && progress.removedSize > 0 {
                Text("\(Bytes.format(progress.removedSize)) freed so far").font(.callout).foregroundStyle(.green)
            }
            Text("Large folders can take a few minutes.").font(.caption).foregroundStyle(.tertiary)
        }
    }

    private var summary: some View {
        let failures = progress.failures
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(failures.isEmpty ? .green : .orange)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.title3.weight(.semibold))
                    Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }

            if !failures.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(plural(failures.count, "item")) couldn't be removed").font(.headline)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(failures) { failure in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(FS.abbreviate(failure.path)).lineLimit(1).truncationMode(.middle)
                                    Text(failure.error ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: 170)
                    .cardStyle(cornerRadius: 10)
                    if failures.contains(where: { $0.path.hasSuffix(".app") }) {
                        HStack(spacing: 4) {
                            Text("Removing apps can need App Management permission.")
                            Button("Open Settings") { Permissions.openAppManagementSettings() }.buttonStyle(.link)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            }

            if let adminError = progress.adminError {
                Label(adminError, systemImage: "xmark.octagon").font(.caption).foregroundStyle(.red)
            }

            HStack {
                if progress.isElevating {
                    ProgressView().controlSize(.small)
                    Text("Waiting for administrator approval…").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if progress.canRetryAsAdmin {
                    Button("Retry as Administrator…") { host.retryFailuresAsAdmin() }
                        .disabled(progress.isElevating)
                }
                Button("Done") { host.finishRemoval() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(progress.isElevating)
            }
            .controlSize(.large)
        }
    }

    private var title: String {
        let count = progress.removed.count
        if count == 0 { return "Nothing was removed" }
        return progress.mode == .trash ? "Moved \(plural(count, "item")) to the Trash" : "Deleted \(plural(count, "item"))"
    }

    private var detail: String {
        let size = Bytes.format(progress.removedSize)
        if progress.removed.isEmpty { return "The items below were left as they were." }
        return progress.mode == .trash
            ? "\(size) is now in the Trash. Empty the Trash to get the space back."
            : "\(size) of disk space freed."
    }
}
