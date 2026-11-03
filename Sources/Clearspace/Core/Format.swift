import Foundation

enum Bytes {
    private static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    static func format(_ bytes: Int64) -> String { formatter.string(fromByteCount: bytes) }
}

func plural(_ count: Int, _ noun: String) -> String {
    "\(count.formatted()) \(noun)\(count == 1 ? "" : "s")"
}
