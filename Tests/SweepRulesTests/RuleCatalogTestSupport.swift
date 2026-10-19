import Foundation
import SweepCore
import Testing

final class CatalogFakeFacts: SystemFacts, @unchecked Sendable {
    let homeDirectory: String
    let now: Date
    let spotlightWorks: Bool
    let hasDeveloperTools = true
    private let installed: Set<String>
    private let running: Set<String>
    private let opened: [String: Date]
    private let repositories: [GitState]

    init(
        home: String,
        now: Date,
        spotlightWorks: Bool = true,
        installed: Set<String> = [],
        running: Set<String> = [],
        opened: [String: Date] = [:],
        repositories: [GitState] = []
    ) {
        self.homeDirectory = home
        self.now = now
        self.spotlightWorks = spotlightWorks
        self.installed = installed
        self.running = running
        self.opened = opened
        self.repositories = repositories
    }

    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func lastOpened(path: String) -> Date? { opened[path] }
    func gitState(repoContaining path: String) -> GitState? {
        repositories
            .filter { path == $0.root || path.hasPrefix($0.root + "/") }
            .max { $0.root.count < $1.root.count }
    }
}

struct CatalogFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func path(_ relative: String) -> String {
        root.appendingPathComponent(relative).path
    }

    func item(
        _ relative: String,
        now: Date,
        daysOld: Int = 120,
        directory: Bool = true,
        size: Int64 = 8_192,
        flags: ItemFlags = []
    ) -> ScannedItem {
        ScannedItem(
            path: path(relative),
            isDirectory: directory,
            logicalSize: size,
            allocatedSize: size,
            reclaimableSize: size,
            fileCount: 1,
            fileID: UInt64(bitPattern: Int64(relative.hashValue)),
            device: 1,
            modified: now.addingTimeInterval(-Double(daysOld) * 86_400),
            flags: flags
        )
    }
}

struct RuleFixtureCase: Sendable, CustomTestStringConvertible {
    let ruleID: String
    let relativePath: String
    let bucket: Bucket
    var directory = true
    var size: Int64 = 8_192
    var companions: [String] = []

    var testDescription: String { ruleID }
}

let catalogFixtureCases: [RuleFixtureCase] = [
    .init(ruleID: "generic.library-caches", relativePath: "Library/Caches/com.example.Widget", bucket: .rebuilds),
    .init(ruleID: "generic.application-support-caches", relativePath: "Library/Application Support/com.example.Unknown/Code Cache", bucket: .rebuilds),
    .init(ruleID: "generic.container-caches", relativePath: "Library/Containers/com.example.Widget/Data/Library/Caches", bucket: .rebuilds),
    .init(ruleID: "generic.orphan-application-support", relativePath: "Library/Application Support/com.example.Removed", bucket: .rebuilds),
    .init(ruleID: "generic.orphan-container", relativePath: "Library/Containers/com.example.Removed", bucket: .rebuilds),
    .init(ruleID: "generic.orphan-group-container", relativePath: "Library/Group Containers/group.com.tinyspeck.slackmacgap", bucket: .rebuilds),
    .init(ruleID: "generic.orphan-saved-state", relativePath: "Library/Saved Application State/com.example.Removed.savedState", bucket: .rebuilds),
    .init(ruleID: "generic.orphan-preference", relativePath: "Library/Preferences/com.example.Removed.plist", bucket: .rebuilds, directory: false),
    .init(ruleID: "generic.logs", relativePath: "Library/Logs/OldApp", bucket: .review),
    .init(ruleID: "generic.trash", relativePath: ".Trash/old-download.dmg", bucket: .review),
    .init(ruleID: "generic.compressed-copy", relativePath: "Downloads/model.bin.zst", bucket: .rebuilds, directory: false, companions: ["Downloads/model.bin"]),
    .init(ruleID: "yours.large-old-files", relativePath: "Movies/old-recording.mov", bucket: .yours, directory: false, size: 1_073_741_824),
    .init(ruleID: "yours.screenshots-recordings", relativePath: "Desktop/Screenshot 2025-01-02.png", bucket: .yours, directory: false),
    .init(ruleID: "yours.secret-looking-names", relativePath: "Documents/id_rsa", bucket: .yours, directory: false),
    .init(ruleID: "apps.cursor-snapshots", relativePath: "Library/Application Support/Cursor/User/workspaceStorage/abc/snapshots/codebases", bucket: .review),
    .init(ruleID: "apps.cursor-extension-downloads", relativePath: "Library/Application Support/Cursor/CachedExtensionVSIXs", bucket: .rebuilds),
    .init(ruleID: "apps.cursor-state-backup", relativePath: "Library/Application Support/Cursor/User/globalStorage/state.vscdb.backup", bucket: .rebuilds, directory: false),
    .init(ruleID: "apps.communication-caches", relativePath: "Library/Application Support/Slack/Code Cache", bucket: .rebuilds),
    .init(ruleID: "apps.spotify-cache", relativePath: "Library/Application Support/Spotify/PersistentCache", bucket: .rebuilds),
    .init(ruleID: "apps.browser-caches", relativePath: "Library/Application Support/Google/Chrome/Profile 2/Cache", bucket: .rebuilds),
    .init(ruleID: "apps.adobe-media-cache", relativePath: "Library/Application Support/Adobe/Common/Media Cache Files", bucket: .rebuilds),
    .init(ruleID: "apps.claude-vm-compressed", relativePath: "Library/Application Support/Claude/vm_bundles/current.bin.zst", bucket: .rebuilds, directory: false, companions: ["Library/Application Support/Claude/vm_bundles/current.bin"]),
    .init(ruleID: "apps.ios-backups", relativePath: "Library/Application Support/MobileSync/Backup/device-id", bucket: .review),
    .init(ruleID: "apps.old-chat-history", relativePath: "Library/Application Support/Slack/Archived Sessions", bucket: .review),
    .init(ruleID: "apps.ipsw-files", relativePath: "Downloads/iPhone.ipsw", bucket: .review, directory: false),
    .init(ruleID: "dev.npm-cache", relativePath: ".npm/_cacache", bucket: .rebuilds),
    .init(ruleID: "dev.bun-cache", relativePath: ".bun/install/cache", bucket: .rebuilds),
    .init(ruleID: "dev.uv-cache", relativePath: ".cache/uv", bucket: .rebuilds),
    .init(ruleID: "dev.homebrew-cache", relativePath: "Library/Caches/Homebrew", bucket: .rebuilds),
    .init(ruleID: "dev.pip-cache", relativePath: ".cache/pip", bucket: .rebuilds),
    .init(ruleID: "dev.xcode-derived-data", relativePath: "Library/Developer/Xcode/DerivedData/Widget-abc", bucket: .rebuilds),
    .init(ruleID: "dev.xcode-archives", relativePath: "Library/Developer/Xcode/Archives/2025-01-02", bucket: .review),
    .init(ruleID: "dev.ios-device-support", relativePath: "Library/Developer/Xcode/iOS DeviceSupport/18.0", bucket: .review),
    .init(ruleID: "dev.simulator-runtimes", relativePath: "Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 18.simruntime", bucket: .review),
    .init(ruleID: "dev.gradle-cache", relativePath: ".gradle/caches", bucket: .rebuilds),
    .init(ruleID: "dev.cocoapods-cache", relativePath: "Library/Caches/CocoaPods", bucket: .rebuilds),
    .init(ruleID: "dev.playwright-cache", relativePath: "Library/Caches/ms-playwright", bucket: .rebuilds),
    .init(ruleID: "dev.known-dot-caches", relativePath: ".cache/go-build", bucket: .rebuilds),
    .init(ruleID: "dev.local-models", relativePath: ".ollama/models", bucket: .review),
    .init(ruleID: "dev.project-junk", relativePath: "Projects/old-app/node_modules", bucket: .rebuilds, companions: ["Projects/old-app/Sources/App.swift", "Projects/old-app/package.json"]),
]
