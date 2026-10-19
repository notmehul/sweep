import Foundation
import SweepCore

public struct StoredScanFinding: Sendable, Hashable, Codable {
    public var id: String
    public var ruleID: String
    public var bucket: Bucket
    public var reclaimableBytes: Int64
    public var paths: [String]

    public init(id: String, ruleID: String, bucket: Bucket, reclaimableBytes: Int64, paths: [String]) {
        self.id = id
        self.ruleID = ruleID
        self.bucket = bucket
        self.reclaimableBytes = reclaimableBytes
        self.paths = paths
    }
}

public struct StoredScan: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var date: Date
    public var totalBytes: Int64
    public var freeBytes: Int64
    public var coverage: Double
    public var tree: SizeNode
    public var findings: [StoredScanFinding]

    public init(
        id: String,
        date: Date,
        totalBytes: Int64,
        freeBytes: Int64,
        coverage: Double,
        tree: SizeNode,
        findings: [StoredScanFinding]
    ) {
        self.id = id
        self.date = date
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.coverage = coverage
        self.tree = tree
        self.findings = findings
    }
}

public enum ScanChangeScope: Sendable, Hashable, Codable {
    case topLevelFolder(path: String, name: String)
    case rule(id: String)
}

public enum ScanChangeKind: String, Sendable, Hashable, Codable {
    case grew, shrank, new, gone
}

public struct ScanChange: Sendable, Hashable, Codable {
    public var scope: ScanChangeScope
    public var kind: ScanChangeKind
    public var byteDelta: Int64
    public var previousBytes: Int64
    public var currentBytes: Int64

    public init(
        scope: ScanChangeScope,
        kind: ScanChangeKind,
        byteDelta: Int64,
        previousBytes: Int64,
        currentBytes: Int64
    ) {
        self.scope = scope
        self.kind = kind
        self.byteDelta = byteDelta
        self.previousBytes = previousBytes
        self.currentBytes = currentBytes
    }
}

public enum DecisionKind: String, Sendable, Hashable, Codable {
    case keep, ignore
}

public struct Decision: Sendable, Hashable, Codable {
    public var path: String
    public var fileID: UInt64
    public var kind: DecisionKind
    public var date: Date

    public init(path: String, fileID: UInt64, kind: DecisionKind, date: Date = .now) {
        self.path = path
        self.fileID = fileID
        self.kind = kind
        self.date = date
    }
}

public struct CleanupEntry: Sendable, Hashable, Codable {
    public var findingID: String
    public var title: String
    public var action: String
    public var originalPath: String
    public var trashURL: URL?
    public var bytes: Int64

    public init(
        findingID: String,
        title: String,
        action: String,
        originalPath: String,
        trashURL: URL?,
        bytes: Int64
    ) {
        self.findingID = findingID
        self.title = title
        self.action = action
        self.originalPath = originalPath
        self.trashURL = trashURL
        self.bytes = bytes
    }
}

public struct CleanupHistoryEntry: Sendable, Hashable, Codable {
    public var cleanupID: String
    public var date: Date
    public var findingID: String
    public var title: String
    public var action: String
    public var originalPath: String
    public var trashURL: URL?
    public var bytes: Int64
    public var undone: Bool

    public init(
        cleanupID: String,
        date: Date,
        findingID: String,
        title: String,
        action: String,
        originalPath: String,
        trashURL: URL?,
        bytes: Int64,
        undone: Bool
    ) {
        self.cleanupID = cleanupID
        self.date = date
        self.findingID = findingID
        self.title = title
        self.action = action
        self.originalPath = originalPath
        self.trashURL = trashURL
        self.bytes = bytes
        self.undone = undone
    }
}

public struct CleanupRecord: Sendable, Hashable, Codable, Identifiable {
    public var id: String
    public var date: Date
    public var entries: [CleanupHistoryEntry]

    public init(id: String, date: Date, entries: [CleanupHistoryEntry]) {
        self.id = id
        self.date = date
        self.entries = entries
    }
}
