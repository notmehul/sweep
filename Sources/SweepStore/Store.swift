import Dispatch
import Foundation
import SQLite3
import SweepCore

public enum StoreError: Error, Sendable, Equatable {
    case open(String)
    case sqlite(code: Int32, message: String)
    case unsupportedSchema(Int32)
    case corruptData(String)
}

public final class Store: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Sweep", isDirectory: true)
            .appendingPathComponent("sweep.sqlite")
    }

    private static let schemaVersion: Int32 = 1
    private let queue = DispatchQueue(label: "app.sweep.store")
    private var database: OpaquePointer?

    public init(path: URL = Store.defaultURL) throws {
        if path.path != ":memory:" {
            try FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }

        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(path.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            if let connection { sqlite3_close(connection) }
            throw StoreError.open(message)
        }
        database = connection

        do {
            try queue.sync {
                try execute("PRAGMA foreign_keys = ON")
                try execute("PRAGMA busy_timeout = 5000")
                try migrate()
            }
        } catch {
            sqlite3_close(connection)
            database = nil
            throw error
        }
    }

    deinit {
        if let database {
            sqlite3_close(database)
        }
    }

    @discardableResult
    public func saveScan(
        id: String = UUID().uuidString,
        date: Date = .now,
        totalBytes: Int64,
        freeBytes: Int64,
        coverage: Double,
        tree: SizeNode,
        findings: [Finding]
    ) throws -> StoredScan {
        let storedFindings = findings.map {
            StoredScanFinding(
                id: $0.id,
                ruleID: $0.ruleID,
                bucket: $0.bucket,
                reclaimableBytes: $0.reclaimableSize,
                paths: $0.items.map(\.path)
            )
        }
        let scan = StoredScan(
            id: id,
            date: date,
            totalBytes: totalBytes,
            freeBytes: freeBytes,
            coverage: coverage,
            tree: tree,
            findings: storedFindings
        )
        try saveScan(scan)
        return scan
    }

    public func saveScan(_ scan: StoredScan) throws {
        try queue.sync {
            try transaction {
                let treeData = try encode(scan.tree)
                try withStatement(
                    "INSERT INTO scans (id, date, total_bytes, free_bytes, coverage, tree_json) VALUES (?, ?, ?, ?, ?, ?)"
                ) { statement in
                    bind(scan.id, at: 1, to: statement)
                    sqlite3_bind_double(statement, 2, scan.date.timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 3, scan.totalBytes)
                    sqlite3_bind_int64(statement, 4, scan.freeBytes)
                    sqlite3_bind_double(statement, 5, scan.coverage)
                    bind(treeData, at: 6, to: statement)
                    try stepDone(statement)
                }

                for finding in scan.findings {
                    let paths = try encode(finding.paths)
                    try withStatement(
                        """
                        INSERT INTO scan_findings
                            (scan_id, finding_id, rule_id, bucket, reclaimable_bytes, path_list)
                        VALUES (?, ?, ?, ?, ?, ?)
                        """
                    ) { statement in
                        bind(scan.id, at: 1, to: statement)
                        bind(finding.id, at: 2, to: statement)
                        bind(finding.ruleID, at: 3, to: statement)
                        bind(finding.bucket.rawValue, at: 4, to: statement)
                        sqlite3_bind_int64(statement, 5, finding.reclaimableBytes)
                        bind(paths, at: 6, to: statement)
                        try stepDone(statement)
                    }
                }
            }
        }
    }

    public func latestScan() throws -> StoredScan? {
        try queue.sync { try scan(offset: 0) }
    }

    public func previousScan() throws -> StoredScan? {
        try queue.sync { try scan(offset: 1) }
    }

    public func diff(latest: StoredScan, previous: StoredScan) -> [ScanChange] {
        var changes: [ScanChange] = []

        let latestFolders = Dictionary(uniqueKeysWithValues: latest.tree.children.map {
            ($0.path, (name: $0.name, bytes: $0.allocatedSize))
        })
        let previousFolders = Dictionary(uniqueKeysWithValues: previous.tree.children.map {
            ($0.path, (name: $0.name, bytes: $0.allocatedSize))
        })
        for path in Set(latestFolders.keys).union(previousFolders.keys).sorted() {
            let current = latestFolders[path]?.bytes ?? 0
            let old = previousFolders[path]?.bytes ?? 0
            guard current != old else { continue }
            let name = latestFolders[path]?.name ?? previousFolders[path]?.name ?? URL(fileURLWithPath: path).lastPathComponent
            changes.append(change(
                scope: .topLevelFolder(path: path, name: name),
                previous: old,
                current: current,
                existedBefore: previousFolders[path] != nil,
                existsNow: latestFolders[path] != nil
            ))
        }

        let latestRules = Dictionary(grouping: latest.findings, by: \.ruleID)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.reclaimableBytes } }
        let previousRules = Dictionary(grouping: previous.findings, by: \.ruleID)
            .mapValues { $0.reduce(Int64(0)) { $0 + $1.reclaimableBytes } }
        for ruleID in Set(latestRules.keys).union(previousRules.keys).sorted() {
            let current = latestRules[ruleID] ?? 0
            let old = previousRules[ruleID] ?? 0
            guard current != old else { continue }
            changes.append(change(
                scope: .rule(id: ruleID),
                previous: old,
                current: current,
                existedBefore: previousRules[ruleID] != nil,
                existsNow: latestRules[ruleID] != nil
            ))
        }
        return changes
    }

    public func recordDecision(
        for item: ScannedItem,
        kind: DecisionKind,
        date: Date = .now
    ) throws {
        try recordDecision(Decision(path: item.path, fileID: item.fileID, kind: kind, date: date))
    }

    public func recordDecision(_ decision: Decision) throws {
        try queue.sync {
            try withStatement(
                """
                INSERT INTO decisions (path, file_id, kind, date) VALUES (?, ?, ?, ?)
                ON CONFLICT(path, file_id) DO UPDATE SET kind = excluded.kind, date = excluded.date
                """
            ) { statement in
                bind(decision.path, at: 1, to: statement)
                bind(String(decision.fileID), at: 2, to: statement)
                bind(decision.kind.rawValue, at: 3, to: statement)
                sqlite3_bind_double(statement, 4, decision.date.timeIntervalSince1970)
                try stepDone(statement)
            }
        }
    }

    public func decision(for item: ScannedItem) throws -> Decision? {
        try queue.sync {
            try withStatement(
                "SELECT kind, date FROM decisions WHERE path = ? AND file_id = ?"
            ) { statement in
                bind(item.path, at: 1, to: statement)
                bind(String(item.fileID), at: 2, to: statement)
                guard try stepRow(statement) else { return nil }
                guard
                    let kind = DecisionKind(rawValue: columnText(statement, 0))
                else {
                    throw StoreError.corruptData("Unknown decision kind")
                }
                return Decision(
                    path: item.path,
                    fileID: item.fileID,
                    kind: kind,
                    date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                )
            }
        }
    }

    public func isKept(_ item: ScannedItem) throws -> Bool {
        try decision(for: item) != nil
    }

    public func removeDecision(for item: ScannedItem) throws {
        try queue.sync {
            try withStatement("DELETE FROM decisions WHERE path = ? AND file_id = ?") { statement in
                bind(item.path, at: 1, to: statement)
                bind(String(item.fileID), at: 2, to: statement)
                try stepDone(statement)
            }
        }
    }

    @discardableResult
    public func recordCleanup(
        _ entries: [CleanupEntry],
        id: String = UUID().uuidString,
        date: Date = .now
    ) throws -> CleanupRecord {
        let record = CleanupRecord(
            id: id,
            date: date,
            entries: entries.map {
                CleanupHistoryEntry(
                    cleanupID: id,
                    date: date,
                    findingID: $0.findingID,
                    title: $0.title,
                    action: $0.action,
                    originalPath: $0.originalPath,
                    trashURL: $0.trashURL,
                    bytes: $0.bytes,
                    undone: false
                )
            }
        )
        try queue.sync {
            try transaction {
                for entry in record.entries {
                    try withStatement(
                        """
                        INSERT INTO history
                            (cleanup_id, date, finding_id, title, action, original_path, trash_url, bytes, undone)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0)
                        """
                    ) { statement in
                        bind(entry.cleanupID, at: 1, to: statement)
                        sqlite3_bind_double(statement, 2, entry.date.timeIntervalSince1970)
                        bind(entry.findingID, at: 3, to: statement)
                        bind(entry.title, at: 4, to: statement)
                        bind(entry.action, at: 5, to: statement)
                        bind(entry.originalPath, at: 6, to: statement)
                        if let trashURL = entry.trashURL {
                            bind(trashURL.path, at: 7, to: statement)
                        } else {
                            sqlite3_bind_null(statement, 7)
                        }
                        sqlite3_bind_int64(statement, 8, entry.bytes)
                        try stepDone(statement)
                    }
                }
            }
        }
        return record
    }

    public func lastCleanup() throws -> CleanupRecord? {
        try cleanups(limit: 1).first
    }

    /// Completed cleanups, newest first.
    public func cleanups(limit: Int) throws -> [CleanupRecord] {
        guard limit > 0 else { return [] }
        return try queue.sync {
            var cleanupDates: [(id: String, date: Date)] = []
            try withStatement(
                """
                SELECT cleanup_id, MAX(date), MAX(rowid)
                FROM history
                GROUP BY cleanup_id
                ORDER BY MAX(date) DESC, MAX(rowid) DESC
                LIMIT ?
                """
            ) { statement in
                sqlite3_bind_int64(statement, 1, Int64(limit))
                while try stepRow(statement) {
                    cleanupDates.append((
                        id: columnText(statement, 0),
                        date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1))
                    ))
                }
            }

            return try cleanupDates.map { cleanup in
                var entries: [CleanupHistoryEntry] = []
                try withStatement(
                    """
                    SELECT finding_id, title, action, original_path, trash_url, bytes, undone
                    FROM history WHERE cleanup_id = ? ORDER BY rowid
                    """
                ) { statement in
                    bind(cleanup.id, at: 1, to: statement)
                    while try stepRow(statement) {
                        let trashPath = columnOptionalText(statement, 4)
                        entries.append(CleanupHistoryEntry(
                            cleanupID: cleanup.id,
                            date: cleanup.date,
                            findingID: columnText(statement, 0),
                            title: columnText(statement, 1),
                            action: columnText(statement, 2),
                            originalPath: columnText(statement, 3),
                            trashURL: trashPath.map { URL(fileURLWithPath: $0) },
                            bytes: sqlite3_column_int64(statement, 5),
                            undone: sqlite3_column_int(statement, 6) != 0
                        ))
                    }
                }
                return CleanupRecord(id: cleanup.id, date: cleanup.date, entries: entries)
            }
        }
    }

    public func markUndone(cleanupID: String, originalPath: String? = nil) throws {
        try queue.sync {
            let sql: String
            if originalPath == nil {
                sql = "UPDATE history SET undone = 1 WHERE cleanup_id = ?"
            } else {
                sql = "UPDATE history SET undone = 1 WHERE cleanup_id = ? AND original_path = ?"
            }
            try withStatement(sql) { statement in
                bind(cleanupID, at: 1, to: statement)
                if let originalPath { bind(originalPath, at: 2, to: statement) }
                try stepDone(statement)
            }
        }
    }

    private func migrate() throws {
        var version: Int32 = 0
        try withStatement("PRAGMA user_version") { statement in
            guard try stepRow(statement) else {
                throw StoreError.corruptData("Could not read the database schema version")
            }
            version = sqlite3_column_int(statement, 0)
        }
        guard version <= Self.schemaVersion else {
            throw StoreError.unsupportedSchema(version)
        }
        guard version == 0 else { return }

        try transaction {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS scans (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    id TEXT NOT NULL UNIQUE,
                    date REAL NOT NULL,
                    total_bytes INTEGER NOT NULL,
                    free_bytes INTEGER NOT NULL,
                    coverage REAL NOT NULL,
                    tree_json BLOB NOT NULL
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS scan_findings (
                    scan_id TEXT NOT NULL REFERENCES scans(id) ON DELETE CASCADE,
                    finding_id TEXT NOT NULL,
                    rule_id TEXT NOT NULL,
                    bucket TEXT NOT NULL,
                    reclaimable_bytes INTEGER NOT NULL,
                    path_list BLOB NOT NULL,
                    PRIMARY KEY (scan_id, finding_id)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS decisions (
                    path TEXT NOT NULL,
                    file_id TEXT NOT NULL,
                    kind TEXT NOT NULL CHECK (kind IN ('keep', 'ignore')),
                    date REAL NOT NULL,
                    PRIMARY KEY (path, file_id)
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS history (
                    cleanup_id TEXT NOT NULL,
                    date REAL NOT NULL,
                    finding_id TEXT NOT NULL,
                    title TEXT NOT NULL,
                    action TEXT NOT NULL,
                    original_path TEXT NOT NULL,
                    trash_url TEXT,
                    bytes INTEGER NOT NULL,
                    undone INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (cleanup_id, original_path)
                )
                """
            )
            try execute("PRAGMA user_version = 1")
        }
    }

    private func scan(offset: Int) throws -> StoredScan? {
        var result: StoredScan?
        try withStatement(
            """
            SELECT id, date, total_bytes, free_bytes, coverage, tree_json
            FROM scans ORDER BY sequence DESC LIMIT 1 OFFSET \(offset)
            """
        ) { statement in
            guard try stepRow(statement) else { return }
            let id = columnText(statement, 0)
            let tree: SizeNode = try decode(columnData(statement, 5), description: "scan tree")
            result = StoredScan(
                id: id,
                date: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                totalBytes: sqlite3_column_int64(statement, 2),
                freeBytes: sqlite3_column_int64(statement, 3),
                coverage: sqlite3_column_double(statement, 4),
                tree: tree,
                findings: []
            )
        }
        guard var result else { return nil }

        try withStatement(
            """
            SELECT finding_id, rule_id, bucket, reclaimable_bytes, path_list
            FROM scan_findings WHERE scan_id = ? ORDER BY finding_id
            """
        ) { statement in
            bind(result.id, at: 1, to: statement)
            while try stepRow(statement) {
                guard let bucket = Bucket(rawValue: columnText(statement, 2)) else {
                    throw StoreError.corruptData("Unknown bucket in stored finding")
                }
                let paths: [String] = try decode(columnData(statement, 4), description: "finding paths")
                result.findings.append(StoredScanFinding(
                    id: columnText(statement, 0),
                    ruleID: columnText(statement, 1),
                    bucket: bucket,
                    reclaimableBytes: sqlite3_column_int64(statement, 3),
                    paths: paths
                ))
            }
        }
        return result
    }

    private func change(
        scope: ScanChangeScope,
        previous: Int64,
        current: Int64,
        existedBefore: Bool,
        existsNow: Bool
    ) -> ScanChange {
        let kind: ScanChangeKind
        if !existedBefore {
            kind = .new
        } else if !existsNow {
            kind = .gone
        } else {
            kind = current > previous ? .grew : .shrank
        }
        return ScanChange(
            scope: scope,
            kind: kind,
            byteDelta: current - previous,
            previousBytes: previous,
            currentBytes: current
        )
    }

    private func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw StoreError.open("Database is closed") }
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw StoreError.sqlite(code: result, message: message)
        }
    }

    private func withStatement<T>(
        _ sql: String,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        guard let database else { throw StoreError.open("Database is closed") }
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw StoreError.sqlite(code: result, message: String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        return try body(statement)
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite statement failed"
            throw StoreError.sqlite(code: result, message: message)
        }
    }

    private func stepRow(_ statement: OpaquePointer) throws -> Bool {
        let result = sqlite3_step(statement)
        switch result {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            let message = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite query failed"
            throw StoreError.sqlite(code: result, message: message)
        }
    }

    private func bind(_ value: String, at index: Int32, to statement: OpaquePointer) {
        sqlite3_bind_text(statement, index, value, -1, Self.transient)
    }

    private func bind(_ value: Data, at index: Int32, to statement: OpaquePointer) {
        _ = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
    }

    private func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: text)
    }

    private func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return columnText(statement, index)
    }

    private func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let bytes = sqlite3_column_blob(statement, index) else { return Data() }
        return Data(bytes: bytes, count: count)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private func decode<T: Decodable>(_ data: Data, description: String) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw StoreError.corruptData("Could not decode \(description): \(error.localizedDescription)")
        }
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}
