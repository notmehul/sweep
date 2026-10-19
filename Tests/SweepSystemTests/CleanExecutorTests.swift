import Foundation
import SweepStore
import SweepSystem
import Testing
@testable import SweepCore

private struct ExecutorFacts: SystemFacts {
    var homeDirectory: String
    var now = Date()
    func isInstalled(bundleID: String) -> Bool { true }
    func isRunning(bundleID: String) -> Bool { false }
    func lastOpened(path: String) -> Date? { nil }
    var spotlightWorks: Bool { true }
    func gitState(repoContaining path: String) -> GitState? { nil }
    var hasDeveloperTools: Bool { true }
}

private struct ExecutorFixture {
    var root: URL
    var home: URL
    var store: Store

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        home = root.appendingPathComponent("home", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = try Store(path: root.appendingPathComponent("store/sweep.sqlite"))
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func writeFixture(_ data: Data, named name: String, in home: URL) throws -> URL {
    let url = home.appendingPathComponent(name)
    try data.write(to: url)
    return url
}

private func scannedItem(at url: URL) throws -> ScannedItem {
    let placeholder = ScannedItem(
        path: url.path,
        isDirectory: false,
        logicalSize: 0,
        allocatedSize: 0,
        reclaimableSize: 0,
        fileCount: 1,
        fileID: 0,
        device: 0,
        modified: .distantPast
    )
    return try #require(FileItemRefresher().refresh(placeholder))
}

private func executorFinding(
    item: ScannedItem,
    bucket: Bucket,
    action: Action,
    id: String = UUID().uuidString
) -> Finding {
    Finding(
        id: id,
        ruleID: "fixture.cleanup",
        title: "Fixture cleanup",
        group: "Tests",
        bucket: bucket,
        items: [item],
        evidence: [],
        lastUsed: nil,
        action: action,
        explanation: Explanation(whatItIs: "", ifRemoved: "", whyStale: ""),
        isDeveloper: false
    )
}

@Test func executorDeletesOnlyApprovedFixture() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.remove() }
    let file = try writeFixture(Data(repeating: 0x41, count: 8_192), named: "cache.bin", in: fixture.home)
    let item = try scannedItem(at: file)
    let executor = CleanupExecutor(
        store: fixture.store,
        facts: ExecutorFacts(homeDirectory: fixture.home.path),
        toolCommands: ToolCommands(availableExecutables: [:])
    )

    let report = await executor.clean([executorFinding(item: item, bucket: .rebuilds, action: .delete)])

    #expect(FileManager.default.fileExists(atPath: file.path) == false)
    #expect(report.deletedCount == 1)
    #expect(report.reclaimableBytes == item.reclaimableSize)
    #expect(report.skipped.isEmpty)
    #expect(try fixture.store.lastCleanup()?.entries.first?.action == "delete")
}

@Test func executorTrashAndUndoRestoresIdenticalContent() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.remove() }
    let content = Data("Sweep fixture contents".utf8)
    let file = try writeFixture(content, named: "old-download.txt", in: fixture.home)
    let item = try scannedItem(at: file)
    let executor = CleanupExecutor(
        store: fixture.store,
        facts: ExecutorFacts(homeDirectory: fixture.home.path),
        toolCommands: ToolCommands(availableExecutables: [:])
    )

    let report = await executor.clean([executorFinding(item: item, bucket: .review, action: .trash)])
    let storedRecord = try fixture.store.lastCleanup()
    let record = try #require(storedRecord)
    let trashURL = try #require(record.entries.first?.trashURL)
    defer { try? FileManager.default.removeItem(at: trashURL) }

    #expect(report.trashedCount == 1)
    #expect(report.canUndo)
    #expect(FileManager.default.fileExists(atPath: file.path) == false)
    #expect(FileManager.default.fileExists(atPath: trashURL.path))

    #expect(await executor.undoLast())
    #expect(try Data(contentsOf: file) == content)
    #expect(FileManager.default.fileExists(atPath: trashURL.path) == false)
    #expect(try fixture.store.lastCleanup()?.entries.first?.undone == true)
}

@Test func executorUndoesRequestedCleanupInsteadOfNewest() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.remove() }
    let first = try writeFixture(Data("first".utf8), named: "first.txt", in: fixture.home)
    let second = try writeFixture(Data("second".utf8), named: "second.txt", in: fixture.home)
    let executor = CleanupExecutor(
        store: fixture.store,
        facts: ExecutorFacts(homeDirectory: fixture.home.path),
        toolCommands: ToolCommands(availableExecutables: [:])
    )

    let firstReport = await executor.clean([
        executorFinding(item: try scannedItem(at: first), bucket: .review, action: .trash),
    ])
    let secondReport = await executor.clean([
        executorFinding(item: try scannedItem(at: second), bucket: .review, action: .trash),
    ])
    let firstID = try #require(firstReport.cleanupID)
    let secondID = try #require(secondReport.cleanupID)
    let secondTrash = try #require(
        fixture.store.cleanups(limit: 2).first(where: { $0.id == secondID })?.entries.first?.trashURL
    )
    defer { try? FileManager.default.removeItem(at: secondTrash) }

    #expect(await executor.undo(cleanupID: firstID))
    #expect(try String(contentsOf: first, encoding: .utf8) == "first")
    #expect(FileManager.default.fileExists(atPath: second.path) == false)
    #expect(try fixture.store.cleanups(limit: 2)
        .first(where: { $0.id == firstID })?.entries.first?.undone == true)
}

@Test func executorReportsSafetyGateSkipReason() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.remove() }
    let file = try writeFixture(Data("before".utf8), named: "changing.bin", in: fixture.home)
    let item = try scannedItem(at: file)
    try Data("after and larger".utf8).write(to: file)
    let executor = CleanupExecutor(
        store: fixture.store,
        facts: ExecutorFacts(homeDirectory: fixture.home.path),
        toolCommands: ToolCommands(availableExecutables: [:])
    )

    let report = await executor.clean([executorFinding(item: item, bucket: .rebuilds, action: .delete)])

    #expect(FileManager.default.fileExists(atPath: file.path))
    #expect(report.deletedCount == 0)
    #expect(report.skipped.first?.reason.isEmpty == false)
}

@Test func undoReportsAnExistingOriginalPathPerItem() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.remove() }
    let file = try writeFixture(Data("trashed".utf8), named: "collision.txt", in: fixture.home)
    let item = try scannedItem(at: file)
    let executor = CleanupExecutor(
        store: fixture.store,
        facts: ExecutorFacts(homeDirectory: fixture.home.path),
        toolCommands: ToolCommands(availableExecutables: [:])
    )
    _ = await executor.clean([executorFinding(item: item, bucket: .review, action: .trash)])
    let storedRecord = try fixture.store.lastCleanup()
    let record = try #require(storedRecord)
    let trashURL = try #require(record.entries.first?.trashURL)
    defer { try? FileManager.default.removeItem(at: trashURL) }
    try Data("replacement".utf8).write(to: file)

    let undo = await executor.undoLastDetailed()

    #expect(undo.restoredCount == 0)
    #expect(undo.failures.first?.originalPath == file.path)
    #expect(undo.failures.first?.reason.contains("already exists") == true)
    #expect(try Data(contentsOf: file) == Data("replacement".utf8))
}

@Test func executorSkipsUnavailableToolWithPlainReason() async throws {
    let fixture = try ExecutorFixture()
    defer { fixture.remove() }
    let file = try writeFixture(Data("cache".utf8), named: "npm-cache", in: fixture.home)
    let item = try scannedItem(at: file)
    let executor = CleanupExecutor(
        store: fixture.store,
        facts: ExecutorFacts(homeDirectory: fixture.home.path),
        toolCommands: ToolCommands(availableExecutables: [:])
    )

    let report = await executor.clean([
        executorFinding(item: item, bucket: .rebuilds, action: .toolCommand(.npmCacheClean)),
    ])

    #expect(report.toolCommandCount == 0)
    #expect(report.skipped.first?.reason.contains("isn't installed") == true)
    #expect(FileManager.default.fileExists(atPath: file.path))
}
