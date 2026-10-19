import Foundation
import SweepCore
import SweepStore

public struct CleanSkip: Sendable, Hashable {
    public var title: String
    public var reason: String

    public init(title: String, reason: String) {
        self.title = title
        self.reason = reason
    }
}

public struct CleanReport: Sendable, Hashable {
    /// The measured increase in free space on the home volume.
    public var freedBytes: Int64
    /// The sum of scanner-computed reclaimable bytes for actions that succeeded.
    public var reclaimableBytes: Int64
    public var deletedCount: Int
    public var trashedCount: Int
    public var toolCommandCount: Int
    public var skipped: [CleanSkip]
    public var canUndo: Bool
    public var cleanupID: String?

    public init(
        freedBytes: Int64,
        reclaimableBytes: Int64,
        deletedCount: Int,
        trashedCount: Int,
        toolCommandCount: Int,
        skipped: [CleanSkip],
        canUndo: Bool,
        cleanupID: String?
    ) {
        self.freedBytes = freedBytes
        self.reclaimableBytes = reclaimableBytes
        self.deletedCount = deletedCount
        self.trashedCount = trashedCount
        self.toolCommandCount = toolCommandCount
        self.skipped = skipped
        self.canUndo = canUndo
        self.cleanupID = cleanupID
    }
}

public struct UndoFailure: Sendable, Hashable {
    public var originalPath: String
    public var reason: String

    public init(originalPath: String, reason: String) {
        self.originalPath = originalPath
        self.reason = reason
    }
}

public struct UndoReport: Sendable, Hashable {
    public var restoredCount: Int
    public var failures: [UndoFailure]

    public init(restoredCount: Int, failures: [UndoFailure]) {
        self.restoredCount = restoredCount
        self.failures = failures
    }

    public var succeeded: Bool { restoredCount > 0 && failures.isEmpty }
}

public struct FileItemRefresher: Sendable {
    public init() {}

    public func refresh(_ scanned: ScannedItem) -> ScannedItem? {
        let manager = FileManager.default
        guard manager.fileExists(atPath: scanned.path) else { return nil }
        let url = URL(fileURLWithPath: scanned.path)
        guard let attributes = try? manager.attributesOfItem(atPath: scanned.path) else { return nil }

        let type = attributes[.type] as? FileAttributeType
        let isDirectory = type == .typeDirectory
        let modified = attributes[.modificationDate] as? Date ?? .distantFuture
        let fileID = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let device = (attributes[.systemNumber] as? NSNumber)?.int32Value ?? 0

        var logicalSize: Int64 = 0
        var allocatedSize: Int64 = 0
        var fileCount = 0
        if isDirectory {
            guard addSizes(at: url, logical: &logicalSize, allocated: &allocatedSize, count: &fileCount) else {
                return nil
            }
            var hadEnumerationError = false
            if let enumerator = manager.enumerator(
                at: url,
                includingPropertiesForKeys: [.fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey],
                errorHandler: { _, _ in
                    hadEnumerationError = true
                    return false
                }
            ) {
                for case let child as URL in enumerator {
                    guard addSizes(
                        at: child,
                        logical: &logicalSize,
                        allocated: &allocatedSize,
                        count: &fileCount
                    ) else {
                        hadEnumerationError = true
                        break
                    }
                }
            }
            guard !hadEnumerationError else { return nil }
        } else {
            guard addSizes(at: url, logical: &logicalSize, allocated: &allocatedSize, count: &fileCount) else {
                return nil
            }
        }

        return ScannedItem(
            path: scanned.path,
            isDirectory: isDirectory,
            logicalSize: logicalSize,
            allocatedSize: allocatedSize,
            reclaimableSize: allocatedSize,
            fileCount: fileCount,
            fileID: fileID,
            device: device,
            modified: modified,
            flags: scanned.flags
        )
    }

    private func addSizes(
        at url: URL,
        logical: inout Int64,
        allocated: inout Int64,
        count: inout Int
    ) -> Bool {
        guard let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey,
        ]) else { return false }
        logical += Int64(values.fileSize ?? 0)
        allocated += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0)
        if values.isRegularFile == true { count += 1 }
        return true
    }
}

public actor CleanupExecutor {
    private let store: Store
    private let facts: any SystemFacts
    private let fileManager: FileManager
    private let toolCommands: ToolCommands
    private let refresher: FileItemRefresher

    public init(
        store: Store,
        facts: any SystemFacts,
        fileManager: FileManager = .default,
        toolCommands: ToolCommands = ToolCommands(),
        refresher: FileItemRefresher = FileItemRefresher()
    ) {
        self.store = store
        self.facts = facts
        self.fileManager = fileManager
        self.toolCommands = toolCommands
        self.refresher = refresher
    }

    public func clean(_ findings: [Finding]) async -> CleanReport {
        let freeBefore = freeSpace()
        var history: [CleanupEntry] = []
        var skipped: [CleanSkip] = []
        var reclaimableBytes: Int64 = 0
        var deletedCount = 0
        var trashedCount = 0
        var toolCommandCount = 0

        for finding in findings {
            if Task.isCancelled {
                skipped.append(CleanSkip(title: finding.title, reason: "Cleanup was cancelled."))
                continue
            }

            let current = finding.items.compactMap { refresher.refresh($0) }
            switch SafetyGate.check(finding, current: current, facts: facts) {
            case .skip(let reason):
                skipped.append(CleanSkip(title: finding.title, reason: reason))
                continue
            case .ok:
                break
            }

            switch finding.action {
            case .delete:
                for item in finding.items {
                    do {
                        try fileManager.removeItem(atPath: item.path)
                        deletedCount += 1
                        reclaimableBytes += item.reclaimableSize
                        history.append(entry(for: item, finding: finding, action: "delete", trashURL: nil))
                    } catch {
                        skipped.append(CleanSkip(
                            title: finding.title,
                            reason: "Sweep couldn't delete \(URL(fileURLWithPath: item.path).lastPathComponent): \(error.localizedDescription)"
                        ))
                    }
                }
            case .trash:
                for item in finding.items {
                    do {
                        var resultingURL: NSURL?
                        try fileManager.trashItem(
                            at: URL(fileURLWithPath: item.path),
                            resultingItemURL: &resultingURL
                        )
                        let trashURL = resultingURL as URL?
                        trashedCount += 1
                        reclaimableBytes += item.reclaimableSize
                        history.append(entry(for: item, finding: finding, action: "trash", trashURL: trashURL))
                    } catch {
                        skipped.append(CleanSkip(
                            title: finding.title,
                            reason: "Sweep couldn't move \(URL(fileURLWithPath: item.path).lastPathComponent) to the Trash: \(error.localizedDescription)"
                        ))
                    }
                }
            case .toolCommand(let command):
                let result = await toolCommands.run(command, itemPaths: finding.items.map(\.path))
                if result.succeeded {
                    toolCommandCount += 1
                    reclaimableBytes += finding.reclaimableSize
                    for item in finding.items {
                        history.append(entry(
                            for: item,
                            finding: finding,
                            action: "toolCommand:\(command.rawValue)",
                            trashURL: nil
                        ))
                    }
                } else {
                    skipped.append(CleanSkip(
                        title: finding.title,
                        reason: result.reason ?? "The cleanup command couldn't finish."
                    ))
                }
            case .showOnly:
                skipped.append(CleanSkip(title: finding.title, reason: "This item can only be shown in Finder."))
            }
        }

        var cleanupID: String?
        if !history.isEmpty {
            do {
                cleanupID = try store.recordCleanup(history).id
            } catch {
                skipped.append(CleanSkip(
                    title: "Cleanup history",
                    reason: "The cleanup finished, but Sweep couldn't save its history: \(error.localizedDescription)"
                ))
            }
        }

        let freeAfter = freeSpace()
        let measured = max(0, (freeAfter ?? 0) - (freeBefore ?? freeAfter ?? 0))
        let canUndo = cleanupID != nil && history.contains { $0.action == "trash" && $0.trashURL != nil }
        return CleanReport(
            freedBytes: measured,
            reclaimableBytes: reclaimableBytes,
            deletedCount: deletedCount,
            trashedCount: trashedCount,
            toolCommandCount: toolCommandCount,
            skipped: skipped,
            canUndo: canUndo,
            cleanupID: cleanupID
        )
    }

    public func undoLast() async -> Bool {
        undoLastDetailed().succeeded
    }

    public func undoLastDetailed() -> UndoReport {
        let record: CleanupRecord
        do {
            guard let last = try store.lastCleanup() else {
                return UndoReport(
                    restoredCount: 0,
                    failures: [UndoFailure(originalPath: "", reason: "There is no cleanup to undo.")]
                )
            }
            record = last
        } catch {
            return UndoReport(
                restoredCount: 0,
                failures: [UndoFailure(originalPath: "", reason: "Sweep couldn't read cleanup history.")]
            )
        }

        var restored = 0
        var failures: [UndoFailure] = []
        for entry in record.entries where entry.action == "trash" && !entry.undone {
            guard isSafeRestorePath(entry.originalPath) else {
                failures.append(UndoFailure(
                    originalPath: entry.originalPath,
                    reason: "The original location is no longer safely inside your home folder."
                ))
                continue
            }
            guard let trashURL = entry.trashURL else {
                failures.append(UndoFailure(
                    originalPath: entry.originalPath,
                    reason: "Sweep didn't record where this item went in the Trash."
                ))
                continue
            }
            guard !fileManager.fileExists(atPath: entry.originalPath) else {
                failures.append(UndoFailure(
                    originalPath: entry.originalPath,
                    reason: "An item already exists at the original location."
                ))
                continue
            }
            guard fileManager.fileExists(atPath: trashURL.path) else {
                failures.append(UndoFailure(
                    originalPath: entry.originalPath,
                    reason: "This item is no longer in the Trash."
                ))
                continue
            }

            do {
                try fileManager.createDirectory(
                    at: URL(fileURLWithPath: entry.originalPath).deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try fileManager.moveItem(at: trashURL, to: URL(fileURLWithPath: entry.originalPath))
                try store.markUndone(cleanupID: record.id, originalPath: entry.originalPath)
                restored += 1
            } catch {
                failures.append(UndoFailure(
                    originalPath: entry.originalPath,
                    reason: "Sweep couldn't restore this item: \(error.localizedDescription)"
                ))
            }
        }
        if restored == 0 && failures.isEmpty {
            failures.append(UndoFailure(originalPath: "", reason: "This cleanup has nothing in the Trash to restore."))
        }
        return UndoReport(restoredCount: restored, failures: failures)
    }

    private func entry(
        for item: ScannedItem,
        finding: Finding,
        action: String,
        trashURL: URL?
    ) -> CleanupEntry {
        CleanupEntry(
            findingID: finding.id,
            title: finding.title,
            action: action,
            originalPath: item.path,
            trashURL: trashURL,
            bytes: item.reclaimableSize
        )
    }

    private func freeSpace() -> Int64? {
        let home = URL(fileURLWithPath: facts.homeDirectory)
        let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    private func isSafeRestorePath(_ path: String) -> Bool {
        let home = URL(fileURLWithPath: facts.homeDirectory)
            .standardizedFileURL.resolvingSymlinksInPath().path
        let lexical = URL(fileURLWithPath: path).standardizedFileURL.path
        let resolved = URL(fileURLWithPath: path)
            .standardizedFileURL.resolvingSymlinksInPath().path
        guard lexical.hasPrefix(home + "/"), resolved.hasPrefix(home + "/") else { return false }
        let protectedRoots = ["Desktop", "Documents", "Downloads", "Library"]
            .map { (home as NSString).appendingPathComponent($0) }
        return !protectedRoots.contains(resolved)
    }
}
