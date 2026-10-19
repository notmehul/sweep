import Foundation
import SweepCore
import SweepStore
import Testing

private func withTemporaryStore(
    _ body: (Store, URL) throws -> Void
) throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("sweep.sqlite")
    try body(Store(path: databaseURL), databaseURL)
}

private func tree(_ sizes: [(String, Int64)]) -> SizeNode {
    SizeNode(
        name: "Home",
        path: "/fixture/home",
        allocatedSize: sizes.reduce(0) { $0 + $1.1 },
        children: sizes.map {
            SizeNode(name: $0.0, path: "/fixture/home/\($0.0)", allocatedSize: $0.1)
        }
    )
}

private func item(path: String = "/fixture/home/cache", fileID: UInt64 = 42) -> ScannedItem {
    ScannedItem(
        path: path,
        isDirectory: true,
        logicalSize: 100,
        allocatedSize: 100,
        reclaimableSize: 100,
        fileCount: 1,
        fileID: fileID,
        device: 1,
        modified: Date(timeIntervalSince1970: 100)
    )
}

@Test func scanRoundTripsAndMigrationIsIdempotent() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let databaseURL = root.appendingPathComponent("sweep.sqlite")
    let scan = StoredScan(
        id: "scan-1",
        date: Date(timeIntervalSince1970: 1_000),
        totalBytes: 900,
        freeBytes: 100,
        coverage: 0.75,
        tree: tree([("Library", 600), ("Downloads", 200)]),
        findings: [
            StoredScanFinding(
                id: "finding-1",
                ruleID: "generic.cache",
                bucket: .rebuilds,
                reclaimableBytes: 50,
                paths: ["/fixture/home/Library/Caches/app"]
            ),
        ]
    )

    do {
        let store = try Store(path: databaseURL)
        try store.saveScan(scan)
        #expect(try store.latestScan() == scan)
        #expect(try store.previousScan() == nil)
    }

    let reopened = try Store(path: databaseURL)
    #expect(try reopened.latestScan() == scan)
}

@Test func diffReportsFoldersAndRules() throws {
    try withTemporaryStore { store, _ in
        let old = StoredScan(
            id: "old",
            date: Date(timeIntervalSince1970: 1),
            totalBytes: 1_000,
            freeBytes: 100,
            coverage: 1,
            tree: tree([("Library", 100), ("Downloads", 80), ("Movies", 30)]),
            findings: [
                StoredScanFinding(id: "a", ruleID: "cache", bucket: .rebuilds, reclaimableBytes: 20, paths: ["a"]),
                StoredScanFinding(id: "b", ruleID: "old-app", bucket: .review, reclaimableBytes: 10, paths: ["b"]),
            ]
        )
        let latest = StoredScan(
            id: "latest",
            date: Date(timeIntervalSince1970: 2),
            totalBytes: 1_000,
            freeBytes: 50,
            coverage: 1,
            tree: tree([("Library", 140), ("Downloads", 60), ("Pictures", 15)]),
            findings: [
                StoredScanFinding(id: "a", ruleID: "cache", bucket: .rebuilds, reclaimableBytes: 35, paths: ["a"]),
                StoredScanFinding(id: "c", ruleID: "new-rule", bucket: .review, reclaimableBytes: 5, paths: ["c"]),
            ]
        )
        try store.saveScan(old)
        try store.saveScan(latest)

        #expect(try store.latestScan()?.id == "latest")
        #expect(try store.previousScan()?.id == "old")
        let changes = store.diff(latest: latest, previous: old)
        #expect(changes.count == 7)
        #expect(changes.contains {
            $0.scope == .topLevelFolder(path: "/fixture/home/Library", name: "Library")
                && $0.kind == .grew && $0.byteDelta == 40
        })
        #expect(changes.contains {
            $0.scope == .rule(id: "old-app") && $0.kind == .gone && $0.byteDelta == -10
        })
        #expect(changes.contains {
            $0.scope == .rule(id: "new-rule") && $0.kind == .new && $0.byteDelta == 5
        })
    }
}

@Test func decisionsAreKeyedByPathAndFullFileID() throws {
    try withTemporaryStore { store, _ in
        let kept = item(fileID: UInt64.max)
        try store.recordDecision(for: kept, kind: .keep, date: Date(timeIntervalSince1970: 5))

        #expect(try store.isKept(kept))
        #expect(try store.decision(for: kept)?.kind == .keep)
        #expect(try store.isKept(item(fileID: UInt64.max - 1)) == false)

        try store.removeDecision(for: kept)
        #expect(try store.isKept(kept) == false)
    }
}

@Test func cleanupHistoryRoundTripsAndMarksIndividualEntryUndone() throws {
    try withTemporaryStore { store, _ in
        let entries = [
            CleanupEntry(
                findingID: "one",
                title: "Cache",
                action: "delete",
                originalPath: "/fixture/home/cache",
                trashURL: nil,
                bytes: 10
            ),
            CleanupEntry(
                findingID: "two",
                title: "Download",
                action: "trash",
                originalPath: "/fixture/home/file",
                trashURL: URL(fileURLWithPath: "/fixture/trash/file"),
                bytes: 20
            ),
        ]
        try store.recordCleanup(entries, id: "cleanup", date: Date(timeIntervalSince1970: 7))

        var maybeRecord = try store.lastCleanup()
        var record = try #require(maybeRecord)
        #expect(record.id == "cleanup")
        #expect(record.entries.count == 2)
        #expect(record.entries.allSatisfy { !$0.undone })

        try store.markUndone(cleanupID: "cleanup", originalPath: "/fixture/home/file")
        maybeRecord = try store.lastCleanup()
        record = try #require(maybeRecord)
        #expect(record.entries.first { $0.originalPath == "/fixture/home/file" }?.undone == true)
        #expect(record.entries.first { $0.originalPath == "/fixture/home/cache" }?.undone == false)
    }
}

@Test func cleanupsAreNewestFirstAndRespectLimit() throws {
    try withTemporaryStore { store, _ in
        let entry = CleanupEntry(
            findingID: "download",
            title: "Download",
            action: "trash",
            originalPath: "/fixture/home/download",
            trashURL: URL(fileURLWithPath: "/fixture/trash/download"),
            bytes: 20
        )
        try store.recordCleanup([entry], id: "old", date: Date(timeIntervalSince1970: 10))
        try store.recordCleanup([entry], id: "new", date: Date(timeIntervalSince1970: 20))

        let records = try store.cleanups(limit: 1)

        #expect(records.map(\.id) == ["new"])
        #expect(records.first?.entries.first?.findingID == "download")
        #expect(try store.cleanups(limit: 0).isEmpty)
    }
}
