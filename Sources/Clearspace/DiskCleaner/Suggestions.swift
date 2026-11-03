import Foundation

enum Safety {
    /// Rebuilt or re-downloaded automatically when needed.
    case safe
    /// Your own data or slow to get back; decide for yourself.
    case review
}

struct Suggestion: Identifiable {
    let path: String
    let title: String
    let note: String
    let safety: Safety
    let size: Int64

    var id: String { path }
}

/// Known caches and leftovers that are usually safe to clear.
enum SuggestionCatalog {
    private struct Entry {
        let path: String
        let title: String
        let safety: Safety
        let note: String
    }

    private static var entries: [Entry] {
        let tmp = FS.userTempRoot
        func home(_ relative: String) -> String { FS.home + "/" + relative }
        return [
            Entry(path: tmp + "/X/com.google.Chrome.code_sign_clone", title: "Chrome leftover copies", safety: .safe,
                  note: "A Chrome bug leaves old copies of the app here. Quit Chrome first."),
            Entry(path: tmp + "/X/com.brave.Browser.code_sign_clone", title: "Brave leftover copies", safety: .safe,
                  note: "Same bug as Chrome. Quit Brave first."),
            Entry(path: home("Library/Caches/go-build"), title: "Go build cache", safety: .safe,
                  note: "Rebuilt on the next go build."),
            Entry(path: home("Library/Caches/pnpm"), title: "pnpm metadata cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/BraveSoftware"), title: "Brave browser cache", safety: .safe,
                  note: "Quit Brave first."),
            Entry(path: home("Library/Caches/com.brave.Browser"), title: "Brave browser cache (2)", safety: .safe,
                  note: "Quit Brave first."),
            Entry(path: home("Library/Caches/Google"), title: "Chrome browser cache", safety: .safe,
                  note: "Quit Chrome first."),
            Entry(path: home("Library/Caches/com.microsoft.VSCode.ShipIt"), title: "VS Code old update files", safety: .safe,
                  note: "Leftovers from past updates."),
            Entry(path: home("Library/Caches/Homebrew"), title: "Homebrew downloads", safety: .safe,
                  note: "Old installer downloads."),
            Entry(path: home("Library/Application Support/Google/GoogleUpdater/crx_cache"), title: "Google updater cache", safety: .safe,
                  note: "Old update packages."),
            Entry(path: home(".gradle/caches"), title: "Gradle cache", safety: .safe,
                  note: "Re-downloaded on the next Android/Gradle build."),
            Entry(path: home(".npm/_cacache"), title: "npm cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/Yarn"), title: "Yarn cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home(".bun/install/cache"), title: "Bun cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/pip"), title: "pip cache", safety: .safe,
                  note: "Re-downloaded when needed."),
            Entry(path: home("Library/Caches/CocoaPods"), title: "CocoaPods cache", safety: .safe,
                  note: "Re-downloaded on the next pod install."),
            Entry(path: home("go/pkg/mod"), title: "Go module downloads", safety: .safe,
                  note: "Re-downloaded on the next go build."),
            Entry(path: home("Library/Developer/Xcode/DerivedData"), title: "Xcode build products", safety: .safe,
                  note: "Rebuilt the next time you build in Xcode."),
            Entry(path: home("Library/Developer/CoreSimulator/Caches"), title: "Simulator caches", safety: .safe,
                  note: "Recreated by the iOS Simulator."),
            Entry(path: FS.trash, title: "Trash contents", safety: .safe,
                  note: "Things you already deleted. (Empties the Trash.)"),
            Entry(path: home("Library/pnpm/store"), title: "pnpm package store", safety: .review,
                  note: "Projects re-download packages on the next pnpm install. Files still used by node_modules stay on disk until those projects are reinstalled."),
            Entry(path: home("Library/Application Support/com.apple.wallpaper/aerials/videos"), title: "Aerial wallpaper videos", safety: .review,
                  note: "Downloaded screen-saver videos; macOS re-downloads the one you use."),
            Entry(path: home("Library/Developer/Xcode/iOS DeviceSupport"), title: "iOS device support files", safety: .review,
                  note: "Copied again from your device the next time you connect it to Xcode."),
            Entry(path: home("Library/Caches/ms-playwright"), title: "Playwright browsers", safety: .review,
                  note: "Re-download with npx playwright install."),
            Entry(path: home(".ollama/models"), title: "Ollama AI models", safety: .review,
                  note: "Your downloaded models. Delete only if you no longer use them."),
            Entry(path: home(".cache/huggingface"), title: "Hugging Face models", safety: .review,
                  note: "Downloaded models and datasets. Delete only if you no longer use them."),
            Entry(path: home(".android/avd"), title: "Android emulator phones", safety: .review,
                  note: "Your emulators. Delete only if you don't use them."),
            Entry(path: home("Library/Android/sdk/system-images"), title: "Android system images", safety: .review,
                  note: "Needed to create and run emulators."),
            Entry(path: home(".codeium"), title: "Codeium / Windsurf index", safety: .review,
                  note: "Rebuilt when you reopen the editor."),
        ]
    }

    static func suggestions(in result: ScanResult) -> [Suggestion] {
        entries.compactMap { entry in
            guard let node = result.index[entry.path], node.size >= DiskScanner.defaultMinimumItemSize else { return nil }
            return Suggestion(path: entry.path, title: entry.title, note: entry.note, safety: entry.safety, size: node.size)
        }
        .sorted { $0.size > $1.size }
    }
}
