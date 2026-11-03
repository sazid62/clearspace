import Foundation
import Testing
@testable import Clearspace

struct WordMatchTests {
    @Test func matchesWholeWordsOnly() {
        #expect(LeftoverFinder.containsWord("Paste", "Paste"))
        #expect(LeftoverFinder.containsWord("Paste Helper", "paste"))
        #expect(LeftoverFinder.containsWord("com.wiheads.paste", "Paste"))
        #expect(LeftoverFinder.containsWord("paste-2024-01-01.ips", "Paste"))
        #expect(!LeftoverFinder.containsWord("PasteBar", "Paste"))
        #expect(!LeftoverFinder.containsWord("Copypaste", "Paste"))
        #expect(!LeftoverFinder.containsWord("anything", ""))
    }

    @Test func bundleIDsNeedABoundary() {
        #expect(LeftoverFinder.containsWord("com.example.paste.savedState", "com.example.paste"))
        #expect(LeftoverFinder.containsWord("ABCDE12345.com.example.paste", "com.example.paste"))
        #expect(!LeftoverFinder.containsWord("com.example.pastebar", "com.example.paste"))
    }
}

struct LeftoverFinderTests {
    @Test func findsTheAppsFilesAndNothingElse() throws {
        let tree = try TempTree()
        let lib = try tree.dir("home/Library")
        let system = try tree.dir("Library")
        let receipts = try tree.dir("receipts")
        let appPath = try tree.dir("Applications/Paste.app")
        let expectedExact = [
            appPath,
            try tree.dir("home/Library/Application Support/Paste"),
            try tree.dir("home/Library/Caches/com.example.paste"),
            try tree.file("home/Library/Preferences/com.example.paste.plist"),
            try tree.file("home/Library/Preferences/ByHost/com.example.paste.1234-ABCD.plist"),
            try tree.dir("home/Library/Containers/com.example.paste"),
            try tree.dir("home/Library/Containers/com.example.paste.ShareExtension"),
            try tree.dir("home/Library/Group Containers/ABCDE12345.com.example.paste"),
            try tree.file("home/Library/LaunchAgents/com.example.paste.helper.plist"),
            try tree.dir("home/Library/Saved Application State/com.example.paste.savedState"),
            try tree.dir("home/Library/HTTPStorages/com.example.paste"),
            try tree.dir("Library/Application Support/com.example.paste"),
            try tree.file("receipts/com.example.paste.bom"),
        ]
        let expectedNameOnly = [
            try tree.file("home/Library/LaunchAgents/com.vendor.paste-sync.plist"),
            try tree.file("home/Library/Logs/DiagnosticReports/Paste-2026-01-01.ips"),
        ]
        // Must never be picked up:
        try tree.dir("home/Library/Application Support/PasteBar")              // longer name
        try tree.file("home/Library/Preferences/com.example.pastebar.plist")   // longer bundle id
        try tree.dir("home/Library/Containers/com.other.app/Data/Library/Paste") // inside another app's sandbox
        try tree.dir("home/Library/Mobile Documents/com~apple~CloudDocs/Paste")  // the user's iCloud Drive
        try tree.dir("home/Library/Paste")                                      // top-level Library folder
        try tree.file("receipts/com.example.pastebar.bom")
        // Inside an item that's already listed: removed with its parent, not listed twice.
        try tree.file("home/Library/Application Support/Paste/com.example.paste/state.json")

        let app = InstalledApp(path: appPath, name: "Paste", bundleID: "com.example.paste", version: "1.0")
        let found = LeftoverFinder(app: app, userLibrary: lib, systemLibrary: system, receipts: receipts).find()
        let exact = Set(found.filter { $0.confidence == .exact }.map(\.path))
        let nameOnly = Set(found.filter { $0.confidence == .nameOnly }.map(\.path))

        #expect(exact == Set(expectedExact))
        #expect(nameOnly == Set(expectedNameOnly))
        #expect(found.first { $0.path == appPath }?.kind == .application)
        #expect(found.first { $0.path.hasSuffix(".bom") }?.kind == .receipts)
    }

    @Test func noBundleIDDoesNotMatchEverything() throws {
        let tree = try TempTree()
        let lib = try tree.dir("home/Library")
        try tree.file("home/Library/LaunchAgents/com.unrelated.agent.plist")
        try tree.dir("home/Library/WebKit/com.unrelated.app")
        let appPath = try tree.dir("Applications/Tool.app")

        let app = InstalledApp(path: appPath, name: "Tool", bundleID: nil, version: nil)
        let found = LeftoverFinder(app: app, userLibrary: lib, systemLibrary: try tree.dir("Library"),
                                   receipts: try tree.dir("receipts")).find()
        #expect(found.map(\.path) == [appPath])
    }
}
