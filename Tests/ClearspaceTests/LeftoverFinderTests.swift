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
        let found = LeftoverFinder(app: app, userLibrary: lib, systemLibrary: system, receipts: receipts,
                                   home: tree.root + "/home", binDirs: []).find()
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
                                   receipts: try tree.dir("receipts"), home: tree.root + "/home", binDirs: []).find()
        #expect(found.map(\.path) == [appPath])
    }

    /// A VM-style app: its data sits in an app-group container named for a different identifier, plus a
    /// privileged helper, CLI links, a ~/.name folder, a Docker context and lines in shell profiles.
    @Test func findsDataOutsideTheBundleIDsFolders() throws {
        let tree = try TempTree()
        let home = try tree.dir("home")
        let lib = try tree.dir("home/Library")
        let system = try tree.dir("Library")
        let bin = try tree.dir("usr/local/bin")
        let appPath = try tree.dir("Applications/Vault.app")
        try tree.file("Applications/Vault.app/Contents/MacOS/vaultctl")
        let helperPath = try tree.file("Library/PrivilegedHelperTools/io.vault.helper")
        let daemon = system + "/LaunchDaemons/io.vault.helper.plist"
        try tree.dir("Library/LaunchDaemons")
        try (["Label": "io.vault.helper", "Program": helperPath, "AssociatedBundleIdentifiers": ["com.example.vaultapp"]]
             as NSDictionary).write(toFile: daemon, atomically: true)
        let unrelatedDaemon = system + "/LaunchDaemons/com.other.daemon.plist"
        try (["Label": "com.other.daemon", "Program": "/usr/libexec/other"] as NSDictionary).write(toFile: unrelatedDaemon, atomically: true)
        let link = bin + "/vaultctl"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: appPath + "/Contents/MacOS/vaultctl")
        try FileManager.default.createSymbolicLink(atPath: bin + "/other", withDestinationPath: "/usr/bin/true")
        let context = try tree.dir("home/.docker/contexts/meta/abc123")
        try Data(#"{"Name":"vault"}"#.utf8).write(to: URL(fileURLWithPath: context + "/meta.json"))
        try Data(#"{"currentContext":"vault"}"#.utf8).write(to: URL(fileURLWithPath: home + "/.docker/config.json"))
        try Data("source ~/.vault/shell/init.zsh\n".utf8).write(to: URL(fileURLWithPath: home + "/.zprofile"))
        try Data("export PATH=$HOME/bin:$PATH\n".utf8).write(to: URL(fileURLWithPath: home + "/.zshrc"))

        let expectedExact = [
            appPath, daemon, helperPath, link, context,
            try tree.dir("home/Library/Group Containers/TEAM123.io.vault"),
            try tree.dir("home/Library/Application Scripts/TEAM123.io.vault"),
            try tree.dir("home/Library/Caches/SentryCrash/Vault"),
            try tree.dir("home/.vault"),
            try tree.dir("home/.config/vault"),
        ]
        let shared = try tree.dir("home/Library/Group Containers/group.io.family")
        try tree.dir("home/Documents/Vault")                                       // the user's own folder

        var app = InstalledApp(path: appPath, name: "Vault", bundleID: "com.example.vaultapp", version: "1.0")
        app.appGroups = ["TEAM123.io.vault", "group.io.family"]
        app.helperLabels = ["io.vault.helper"]
        var sibling = InstalledApp(path: try tree.dir("Applications/Sibling.app"), name: "Sibling", bundleID: "io.sibling", version: nil)
        sibling.appGroups = ["group.io.family"]

        let finder = LeftoverFinder(app: app, userLibrary: lib, systemLibrary: system, receipts: try tree.dir("receipts"),
                                    home: home, binDirs: [bin], otherApps: [app, sibling])
        let found = finder.find()
        let exact = Set(found.filter { $0.confidence == .exact }.map(\.path))

        #expect(exact == Set(expectedExact))
        // Another installed app uses this group too: listed, but left unticked.
        #expect(found.first { $0.path == shared }?.confidence == .nameOnly)
        #expect(found.first { $0.path == link }?.kind == .commandLineTools)
        #expect(found.first { $0.path == helperPath }?.kind == .launchItems)
        #expect(found.first { $0.path == home + "/.vault" }?.kind == .homeData)
        // Shell profiles and the Docker config hold the user's own lines: reported, never removed.
        #expect(finder.mentions == [home + "/.docker/config.json", home + "/.zprofile"])
        #expect(!found.contains { $0.path.hasSuffix(".zprofile") || $0.path.hasSuffix("config.json") })
    }

    @Test func mountPointsAreDetected() {
        #expect(FS.isMountPoint("/dev"))
        #expect(!FS.isMountPoint(FS.home))
    }
}
