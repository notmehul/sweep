import Foundation
import Testing
@testable import SweepCore

private struct GateFacts: SystemFacts {
    var homeDirectory: String
    var now = Date(timeIntervalSince1970: 1_000)
    var running: Set<String> = []
    var runningNames: Set<String> = []
    var git: GitState?

    func isInstalled(bundleID: String) -> Bool { true }
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func isRunning(appNamed: String) -> Bool { runningNames.contains(appNamed) }
    func lastOpened(path: String) -> Date? { nil }
    var spotlightWorks: Bool { true }
    func gitState(repoContaining path: String) -> GitState? { git }
    var hasDeveloperTools: Bool { true }
}

private func gateItem(
    path: String,
    directory: Bool = false,
    size: Int64 = 100,
    fileID: UInt64 = 7,
    modified: Date = Date(timeIntervalSince1970: 100)
) -> ScannedItem {
    ScannedItem(
        path: path,
        isDirectory: directory,
        logicalSize: size,
        allocatedSize: size,
        reclaimableSize: size,
        fileCount: 1,
        fileID: fileID,
        device: 1,
        modified: modified
    )
}

private func gateFinding(
    item: ScannedItem,
    bucket: Bucket = .rebuilds,
    action: Action = .delete,
    evidence: [Evidence] = [],
    developer: Bool = false
) -> Finding {
    Finding(
        id: "fixture",
        ruleID: "fixture.rule",
        title: "Fixture",
        group: "Tests",
        bucket: bucket,
        items: [item],
        evidence: evidence,
        lastUsed: nil,
        action: action,
        explanation: Explanation(whatItIs: "", ifRemoved: "", whyStale: ""),
        isDeveloper: developer
    )
}

private func skipReason(_ result: GateResult) -> String? {
    guard case .skip(let reason) = result else { return nil }
    return reason
}

@Test func safetyGateAcceptsAnUnchangedItem() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Library/Caches/app")
    let result = SafetyGate.check(gateFinding(item: scanned), current: [scanned], facts: GateFacts(homeDirectory: home))
    #expect(result == .ok)
}

@Test func safetyGateRejectsChangedFileSize() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Library/Caches/app")
    let current = gateItem(path: scanned.path, size: 101)
    let reason = skipReason(SafetyGate.check(
        gateFinding(item: scanned),
        current: [current],
        facts: GateFacts(homeDirectory: home)
    ))
    #expect(reason?.contains("changed size") == true)
}

@Test func safetyGateAllowsOnePercentDirectoryDriftButNotMore() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Library/Caches/app", directory: true, size: 10_000)
    let within = gateItem(path: scanned.path, directory: true, size: 10_100)
    let beyond = gateItem(path: scanned.path, directory: true, size: 10_101)
    let finding = gateFinding(item: scanned)
    let facts = GateFacts(homeDirectory: home)

    #expect(SafetyGate.check(finding, current: [within], facts: facts) == .ok)
    #expect(skipReason(SafetyGate.check(finding, current: [beyond], facts: facts)) != nil)
}

@Test func safetyGateRejectsNewerModificationDate() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Library/Caches/app")
    let current = gateItem(path: scanned.path, modified: scanned.modified.addingTimeInterval(1))
    let reason = skipReason(SafetyGate.check(
        gateFinding(item: scanned),
        current: [current],
        facts: GateFacts(homeDirectory: home)
    ))
    #expect(reason?.contains("changed after") == true)
}

@Test func safetyGateRejectsRunningOwningApp() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Library/Containers/com.example.app/Data/Library/Caches")
    let finding = gateFinding(item: scanned, evidence: [.appRunning("com.example.app")])
    let facts = GateFacts(homeDirectory: home, running: ["com.example.app"])

    #expect(skipReason(SafetyGate.check(finding, current: [scanned], facts: facts))?.contains("Quit") == true)
    #expect(SafetyGate.bundleIdentifier(for: finding) == "com.example.app")
}

@Test func safetyGateRejectsRunningAppNamedInPath() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Library/Application Support/Slack/Cache")
    let facts = GateFacts(homeDirectory: home, runningNames: ["Slack"])

    let reason = skipReason(SafetyGate.check(
        gateFinding(item: scanned),
        current: [scanned],
        facts: facts
    ))
    #expect(reason?.contains("Quit Slack") == true)
}

@Test func safetyGateAllowsOwnedTopLevelHomeApplicationBundle() throws {
    let homeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("SweepGate-\(UUID().uuidString)", isDirectory: true)
    let app = homeURL.appendingPathComponent("Applications/Old.app", isDirectory: true)
    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: homeURL) }
    let scanned = gateItem(path: app.path, directory: true)
    let facts = GateFacts(homeDirectory: homeURL.path)

    #expect(SafetyGate.check(
        gateFinding(item: scanned, bucket: .review, action: .trash),
        current: [scanned],
        facts: facts
    ) == .ok)
}

@Test func safetyGateRejectsOutsideHomeAndProtectedRoots() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let facts = GateFacts(homeDirectory: home)
    for path in ["/private/tmp/outside", home, home + "/Documents", home + "/Desktop", home + "/Downloads", home + "/Library"] {
        let scanned = gateItem(path: path, directory: true)
        #expect(skipReason(SafetyGate.check(gateFinding(item: scanned), current: [scanned], facts: facts)) != nil)
    }
}

@Test func safetyGateRefusesDeleteForReviewBucket() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Downloads/old.dmg")
    let finding = gateFinding(item: scanned, bucket: .review, action: .delete)
    let reason = skipReason(SafetyGate.check(finding, current: [scanned], facts: GateFacts(homeDirectory: home)))
    #expect(reason?.contains("rebuild") == true)
}

@Test func safetyGateRejectsDirtyDeveloperRepo() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Code/project/node_modules", directory: true)
    let finding = gateFinding(item: scanned, developer: true)
    let facts = GateFacts(
        homeDirectory: home,
        git: GitState(root: home + "/Code/project", isDirty: true, hasRemote: true, lastCommit: nil)
    )
    #expect(skipReason(SafetyGate.check(finding, current: [scanned], facts: facts))?.contains("uncommitted") == true)
}

@Test func safetyGateRejectsDeveloperRepoWithoutRemote() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    let scanned = gateItem(path: home + "/Code/project/node_modules", directory: true)
    let finding = gateFinding(item: scanned, developer: true)
    let facts = GateFacts(
        homeDirectory: home,
        git: GitState(root: home + "/Code/project", isDirty: false, hasRemote: false, lastCommit: nil)
    )
    #expect(skipReason(SafetyGate.check(finding, current: [scanned], facts: facts))?.contains("no remote") == true)
}
