import AppKit
import SwiftUI

enum Brand {
    static let blue = Color(red: 0.23, green: 0.42, blue: 1.0)
    static let gradient = LinearGradient(colors: [Color(red: 0.37, green: 0.83, blue: 1.0), blue, Color(red: 0.17, green: 0.18, blue: 0.85)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The rounded gradient tile used at the top of empty and welcome states.
struct HeroIcon: View {
    let symbol: String
    var size: CGFloat = 84

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Brand.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: Brand.blue.opacity(0.35), radius: 14, y: 6)
    }
}

struct UsageBar: View {
    var fraction: Double
    /// Defaults to accent → orange → red as the bar fills, like a disk meter.
    var tint: Color? = nil

    var body: some View {
        GeometryReader { geo in
            let clamped = min(max(fraction, 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                if clamped > 0 {
                    Capsule()
                        .fill((tint ?? levelColor(clamped)).gradient)
                        .frame(width: max(geo.size.height, geo.size.width * clamped))
                }
            }
        }
    }

    private func levelColor(_ fraction: Double) -> Color {
        fraction > 0.9 ? .red : fraction > 0.75 ? .orange : .accentColor
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule())
    }
}

struct SizeColumn: View {
    let size: Int64
    let fraction: Double
    var muted = false
    /// Fixed so list rows need no GeometryReader, which is costly across thousands of rows.
    private let barWidth: CGFloat = 96

    var body: some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(Bytes.format(size))
                .font(.callout.weight(muted ? .regular : .semibold))
                .monospacedDigit()
                .foregroundStyle(muted ? .secondary : .primary)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(muted ? Color.gray : Color.accentColor)
                    .frame(width: max(4, barWidth * min(max(fraction, 0), 1)))
            }
            .frame(width: barWidth, height: 4)
        }
        .frame(width: 110, alignment: .trailing)
    }
}

@MainActor
enum IconCache {
    private static let cache = NSCache<NSString, NSImage>()

    static func icon(for path: String) -> NSImage {
        if let cached = cache.object(forKey: path as NSString) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: path)
        cache.setObject(icon, forKey: path as NSString)
        return icon
    }
}

struct FileIcon: View {
    let path: String
    var size: CGFloat = 24

    var body: some View {
        Image(nsImage: IconCache.icon(for: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

struct FileMenuItems: View {
    let path: String

    var body: some View {
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(path, forType: .string)
        }
    }
}

/// The bar pinned to the bottom of a tool, holding the selection summary and actions.
struct ActionBar<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
    }
}

struct ListHint<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "info.circle").foregroundStyle(.secondary)
            // No vertical fixedSize: measured at the window's minimum width it would demand a huge height.
            Text(text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

extension ListHint where Accessory == EmptyView {
    init(text: String) {
        self.init(text: text) { EmptyView() }
    }
}

struct StorageCard: View {
    let storage: StorageInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(storage.volumeName, systemImage: "internaldrive.fill").font(.headline)
                Spacer()
                Text("\(Bytes.format(storage.available)) available")
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
            }
            UsageBar(fraction: storage.usedFraction).frame(height: 10)
            HStack {
                Text("\(Bytes.format(storage.used)) used")
                Spacer()
                Text("\(Bytes.format(storage.total)) total")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .padding(16)
        .cardStyle()
    }
}

struct FullDiskAccessCallout: View {
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Give Clearspace Full Disk Access").font(.headline)
                Text("macOS hides some folders, like Mail, Safari, other apps' data and the Trash, until you allow it. Without access those folders are skipped and macOS may ask for permission several times. Turn on Clearspace in the list (or add it with +), then reopen the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Privacy Settings") { Permissions.openFullDiskAccessSettings() }
                    .padding(.top, 4)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.orange.opacity(0.25)))
    }
}

extension View {
    func cardStyle(cornerRadius: CGFloat = 12) -> some View {
        background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}
