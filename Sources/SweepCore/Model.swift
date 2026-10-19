import Foundation

/// One file or directory as measured by the walker. A directory that a rule claims as a
/// unit (e.g. `node_modules`) carries its whole subtree's totals and has no children emitted.
public struct ScannedItem: Sendable, Hashable, Codable {
    public var path: String
    public var isDirectory: Bool
    /// Bytes the file says it holds.
    public var logicalSize: Int64
    /// Bytes actually allocated on disk (sparse files are smaller than logical).
    public var allocatedSize: Int64
    /// Bytes freed if this item is removed: excludes blocks shared with clones.
    public var reclaimableSize: Int64
    public var fileCount: Int
    public var fileID: UInt64
    public var device: Int32
    public var modified: Date
    public var flags: ItemFlags

    public init(path: String, isDirectory: Bool, logicalSize: Int64, allocatedSize: Int64,
                reclaimableSize: Int64, fileCount: Int, fileID: UInt64, device: Int32,
                modified: Date, flags: ItemFlags = []) {
        self.path = path; self.isDirectory = isDirectory; self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize; self.reclaimableSize = reclaimableSize
        self.fileCount = fileCount; self.fileID = fileID; self.device = device
        self.modified = modified; self.flags = flags
    }
}

public struct ItemFlags: OptionSet, Sendable, Hashable, Codable {
    public let rawValue: UInt32
    public init(rawValue: UInt32) { self.rawValue = rawValue }
    /// APFS clone sharing every block with another file: removing it frees nothing.
    public static let sharesAllBlocks = ItemFlags(rawValue: 1 << 0)
    public static let maySharesBlocks = ItemFlags(rawValue: 1 << 1)
    public static let sparse = ItemFlags(rawValue: 1 << 2)
    /// iCloud placeholder: never read or hash, reading downloads it.
    public static let dataless = ItemFlags(rawValue: 1 << 3)
    public static let hardLinked = ItemFlags(rawValue: 1 << 4)
    /// Contents could not be read (permissions / TCC); sizes are partial.
    public static let unreadable = ItemFlags(rawValue: 1 << 5)
}

/// Depth-limited size tree that feeds the sunburst.
public struct SizeNode: Sendable, Hashable, Codable {
    public var name: String
    public var path: String
    public var allocatedSize: Int64
    public var bucket: Bucket?
    public var children: [SizeNode]
    public init(name: String, path: String, allocatedSize: Int64, bucket: Bucket? = nil, children: [SizeNode] = []) {
        self.name = name; self.path = path; self.allocatedSize = allocatedSize
        self.bucket = bucket; self.children = children
    }
}

public struct ScanProgress: Sendable {
    public var scannedBytes: Int64
    /// Used bytes on the volume, known before the scan starts; progress = scanned / total.
    public var totalBytes: Int64
    public var filesSeen: Int
    public var currentPath: String
    public init(scannedBytes: Int64, totalBytes: Int64, filesSeen: Int, currentPath: String) {
        self.scannedBytes = scannedBytes; self.totalBytes = totalBytes
        self.filesSeen = filesSeen; self.currentPath = currentPath
    }
    public var fraction: Double { totalBytes > 0 ? min(1, Double(scannedBytes) / Double(totalBytes)) : 0 }
}

public enum ToolCommand: String, Sendable, Codable, CaseIterable {
    case simctlRuntimeDelete, brewCleanup, npmCacheClean, uvCacheClean, bunCacheRm
}

public enum Action: Sendable, Hashable, Codable {
    case delete
    case trash
    case toolCommand(ToolCommand)
    case showOnly
}

public enum Evidence: Sendable, Hashable, Codable {
    case bundleNotInstalled(String)
    case notSymlinkTarget(active: String)
    case staleDays(Int)
    case neverOpened
    case gitDirty
    case noRemote
    case coveredByIgnore
    case sharesBlocks
    case appRunning(String)
    case duplicateOf(String)
    case installerForInstalledApp(String)
}

public struct LastUsed: Sendable, Hashable, Codable {
    public enum Source: String, Sendable, Codable { case spotlight, mtime, git }
    public var date: Date?
    public var source: Source
    public init(date: Date?, source: Source) { self.date = date; self.source = source }
}

/// The three plain-language answers every item card shows.
public struct Explanation: Sendable, Hashable, Codable {
    public var whatItIs: String
    public var ifRemoved: String
    public var whyStale: String
    public init(whatItIs: String, ifRemoved: String, whyStale: String) {
        self.whatItIs = whatItIs; self.ifRemoved = ifRemoved; self.whyStale = whyStale
    }
}

/// A cleanup candidate. Only the rule engine in SweepCore creates one: the initializer is
/// internal, so the AI layer and the app can describe findings but never assign a bucket.
public struct Finding: Sendable, Hashable, Codable, Identifiable {
    public let id: String
    public let ruleID: String
    public let title: String
    /// Grouping label in the bucket detail view, e.g. "App caches".
    public let group: String
    public let bucket: Bucket
    public let items: [ScannedItem]
    public let evidence: [Evidence]
    public let lastUsed: LastUsed?
    public let action: Action
    public let explanation: Explanation
    /// Present only for developer-tool findings; hidden unless the persona includes developer.
    public let isDeveloper: Bool

    init(id: String, ruleID: String, title: String, group: String, bucket: Bucket, items: [ScannedItem],
         evidence: [Evidence], lastUsed: LastUsed?, action: Action, explanation: Explanation, isDeveloper: Bool) {
        self.id = id; self.ruleID = ruleID; self.title = title; self.group = group; self.bucket = bucket
        self.items = items; self.evidence = evidence; self.lastUsed = lastUsed; self.action = action
        self.explanation = explanation; self.isDeveloper = isDeveloper
    }

    public var reclaimableSize: Int64 { items.reduce(0) { $0 + $1.reclaimableSize } }
    public var allocatedSize: Int64 { items.reduce(0) { $0 + $1.allocatedSize } }
}

/// Facts about the machine the rule engine needs. SweepSystem provides the real one;
/// tests provide a fake, so classification stays pure and testable.
public protocol SystemFacts: Sendable {
    var homeDirectory: String { get }
    var now: Date { get }
    func isInstalled(bundleID: String) -> Bool
    func isRunning(bundleID: String) -> Bool
    /// Spotlight last-opened date for a path, nil when unknown or Spotlight unavailable.
    func lastOpened(path: String) -> Date?
    var spotlightWorks: Bool { get }
    /// nil when git (Command Line Tools) is not installed or path is not in a repo.
    func gitState(repoContaining path: String) -> GitState?
    var hasDeveloperTools: Bool { get }
}

public struct GitState: Sendable, Hashable {
    public var root: String
    public var isDirty: Bool
    public var hasRemote: Bool
    public var lastCommit: Date?
    public init(root: String, isDirty: Bool, hasRemote: Bool, lastCommit: Date?) {
        self.root = root; self.isDirty = isDirty; self.hasRemote = hasRemote; self.lastCommit = lastCommit
    }
}
