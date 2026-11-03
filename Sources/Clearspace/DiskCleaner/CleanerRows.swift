import SwiftUI

struct CleanerItem {
    var path: String
    var size: Int64
    var title: String
    var subtitle: String? = nil
    var note: String? = nil
    var safety: Safety? = nil
    var fraction: Double
}

extension CleanerItem {
    init(node: FSNode, fraction: Double, subtitle: String? = nil) {
        self.init(path: node.path, size: node.size, title: node.name, subtitle: subtitle, fraction: fraction)
    }
}

enum Disclosure {
    case leaf, collapsed, expanded
}

struct CleanerRow: View {
    @Environment(DiskCleanerModel.self) private var model
    let item: CleanerItem
    var depth = 0
    /// nil hides the disclosure column entirely (flat lists).
    var disclosure: Disclosure? = nil

    var body: some View {
        let covered = model.isCovered(item.path)
        HStack(spacing: 10) {
            Toggle(isOn: Binding(get: { covered || model.isSelected(item.path) },
                                 set: { model.setSelected(item.path, size: item.size, $0) })) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(covered)
                .help(covered ? "Included because its folder is selected" : "Select to remove")
            if let disclosure {
                DisclosureButton(state: disclosure) {
                    withAnimation(.easeInOut(duration: 0.15)) { model.toggleExpanded(item.path) }
                }
                .padding(.leading, CGFloat(depth) * 18)
            }
            FileIcon(path: item.path, size: 24)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.title).lineLimit(1).truncationMode(.middle)
                    if let safety = item.safety {
                        Pill(text: safety == .safe ? "Safe" : "Review", color: safety == .safe ? .green : .orange)
                    }
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 16)
            SizeColumn(size: item.size, fraction: item.fraction)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu { FileMenuItems(path: item.path) }
    }
}

struct SmallItemsRow: View {
    let size: Int64
    let depth: Int
    let fraction: Double

    var body: some View {
        HStack(spacing: 10) {
            // Blank space where real rows have a checkbox and chevron, keeping the columns aligned.
            Color.clear.frame(width: 14, height: 14)
            Color.clear
                .frame(width: 16, height: 16)
                .padding(.leading, CGFloat(depth) * 18)
            Image(systemName: "square.stack.3d.down.right")
                .foregroundStyle(.tertiary)
                .frame(width: 24, height: 24)
            Text("Small items (under 20 MB each)")
                .italic()
                .foregroundStyle(.secondary)
            Spacer(minLength: 16)
            SizeColumn(size: size, fraction: fraction, muted: true)
        }
        .padding(.vertical, 4)
    }
}

struct DisclosureButton: View {
    let state: Disclosure
    let action: () -> Void

    var body: some View {
        if state == .leaf {
            Color.clear.frame(width: 16, height: 16)
        } else {
            Button(action: action) {
                Image(systemName: state == .expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}
