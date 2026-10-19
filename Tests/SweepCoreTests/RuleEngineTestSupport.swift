import Foundation
@testable import SweepCore

final class FakeFacts: SystemFacts, @unchecked Sendable {
    let homeDirectory: String
    let now: Date
    let spotlightWorks: Bool
    let hasDeveloperTools: Bool
    private let installed: Set<String>
    private let running: Set<String>
    private let opened: [String: Date]
    private let repositories: [GitState]

    init(
        home: String,
        now: Date = Date(timeIntervalSince1970: 2_000_000_000),
        spotlightWorks: Bool = true,
        hasDeveloperTools: Bool = true,
        installed: Set<String> = [],
        running: Set<String> = [],
        opened: [String: Date] = [:],
        repositories: [GitState] = []
    ) {
        self.homeDirectory = home
        self.now = now
        self.spotlightWorks = spotlightWorks
        self.hasDeveloperTools = hasDeveloperTools
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

struct TemporaryFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepRuleTests-\(UUID().uuidString)", isDirectory: true)
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
        directory: Bool = true,
        modified: Date,
        size: Int64 = 4_096,
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
            modified: modified,
            flags: flags
        )
    }
}

func testRule(
    id: String = "test.rule",
    match: RuleMatch,
    conditions: RuleConditions = RuleConditions(),
    bucket: Bucket = .rebuilds,
    priority: Int = 0,
    unit: Bool = true
) -> Rule {
    Rule(
        id: id,
        match: match,
        conditions: conditions,
        bucket: bucket,
        action: bucket == .rebuilds ? .delete : .showOnly,
        group: "{app}",
        title: "{app} {size}",
        explain: RuleExplanation(
            whatItIs: "{app} data",
            ifRemoved: "It can be removed.",
            whyStale: "It is {age} old."
        ),
        unit: unit,
        priority: priority
    )
}
