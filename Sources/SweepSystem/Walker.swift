import CAttrBulk
import Darwin
import Foundation
import SweepCore

public enum WalkEvent: Sendable {
    case progress(ScanProgress)
    case item(ScannedItem)
    /// A top-level folder under a root finished; lets the sunburst grow during the scan.
    case subtree(SizeNode)
    case finished(WalkResult)
}

public struct WalkResult: Sendable {
    public var root: SizeNode
    public var totalAllocated: Int64
    public var filesSeen: Int
    public var unreadablePaths: [String]

    public init(root: SizeNode, totalAllocated: Int64, filesSeen: Int, unreadablePaths: [String]) {
        self.root = root
        self.totalAllocated = totalAllocated
        self.filesSeen = filesSeen
        self.unreadablePaths = unreadablePaths
    }
}

public struct Walker: Sendable {
    public init() {}

    public func scan(
        roots: [String],
        totalBytes: Int64,
        claimsAsUnit: @escaping @Sendable (String, Bool) -> Bool,
        sunburstDepth: Int = 4,
        excluding excluded: Set<String> = []
    ) -> AsyncStream<WalkEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let operation = WalkOperation(
                    roots: roots,
                    totalBytes: totalBytes,
                    claimsAsUnit: claimsAsUnit,
                    sunburstDepth: max(0, sunburstDepth),
                    excluded: excluded,
                    continuation: continuation
                )
                await operation.run()
            }
            continuation.onTermination = { @Sendable _ in
                task.cancel()
            }
        }
    }
}

private struct FileIdentity: Hashable, Sendable {
    var device: Int32
    var fileID: UInt64
}

private actor HardLinkRegistry {
    private var seen: Set<FileIdentity> = []

    func insert(_ identity: FileIdentity) -> Bool {
        seen.insert(identity).inserted
    }
}

private final class ProgressEmitter: @unchecked Sendable {
    private let lock = NSLock()
    private let totalBytes: Int64
    private let continuation: AsyncStream<WalkEvent>.Continuation
    private var scannedBytes: Int64 = 0
    private var filesSeen: Int = 0
    private var lastEmission: UInt64 = 0

    init(totalBytes: Int64, continuation: AsyncStream<WalkEvent>.Continuation) {
        self.totalBytes = totalBytes
        self.continuation = continuation
    }

    func record(bytes: Int64, files: Int, path: String, force: Bool = false) {
        lock.lock()
        defer { lock.unlock() }

        scannedBytes += bytes
        filesSeen += files
        let now = DispatchTime.now().uptimeNanoseconds
        guard force || lastEmission == 0 || now - lastEmission >= 33_000_000 else {
            return
        }
        lastEmission = now
        continuation.yield(.progress(ScanProgress(
            scannedBytes: scannedBytes,
            totalBytes: totalBytes,
            filesSeen: filesSeen,
            currentPath: path
        )))
    }
}

private struct BulkEntry: Sendable {
    var name: String
    var isDirectory: Bool
    var isSymlink: Bool
    var fileID: UInt64
    var device: Int32
    var logicalSize: Int64
    var allocatedSize: Int64
    var privateSize: Int64
    var extFlags: UInt64
    var bsdFlags: UInt32
    var linkCount: UInt32
    var modified: Date

    init(_ entry: SweepEntry) {
        var nameField = entry.name
        name = withUnsafeBytes(of: &nameField) { bytes in
            let length = bytes.firstIndex(of: 0) ?? bytes.count
            return String(decoding: bytes[..<length], as: UTF8.self)
        }
        isDirectory = entry.isDirectory
        isSymlink = entry.isSymlink
        fileID = entry.fileID
        device = entry.device
        logicalSize = max(0, entry.logicalSize)
        allocatedSize = max(0, entry.allocatedSize)
        privateSize = entry.privateSize
        extFlags = entry.extFlags
        bsdFlags = entry.bsdFlags
        linkCount = entry.linkCount
        modified = Date(timeIntervalSince1970: TimeInterval(entry.modifiedSeconds))
    }
}

private final class EntryCollector {
    var entries: [BulkEntry] = []
}

private func collectEntry(_ context: UnsafeMutableRawPointer?, _ entry: UnsafePointer<SweepEntry>?) {
    guard let context, let entry else { return }
    let collector = Unmanaged<EntryCollector>.fromOpaque(context).takeUnretainedValue()
    collector.entries.append(BulkEntry(entry.pointee))
}

private func scanCancelled(_: UnsafeMutableRawPointer?) -> Bool {
    Task.isCancelled
}

private enum DirectoryRead {
    case entries([BulkEntry])
    case unreadable
    case skipped
}

private struct EntryResult: Sendable {
    var node: SizeNode
    var logical: Int64
    var allocated: Int64
    var reclaimable: Int64
    var fileCount: Int
    var newestModified: Date
    var unreadablePaths: [String]
}

private struct RootMetadata: Sendable {
    var entry: BulkEntry
    var path: String
}

private struct WalkOperation: Sendable {
    private static let largeFileBytes: Int64 = 50 * 1024 * 1024
    private static let sharesAllBlocks: UInt64 = 0x0000_0040
    private static let mayShareBlocks: UInt64 = 0x0000_0001
    private static let isSparse: UInt64 = 0x0000_0010
    private static let dataless: UInt32 = 0x4000_0000

    let roots: [String]
    let totalBytes: Int64
    let claimsAsUnit: @Sendable (String, Bool) -> Bool
    let sunburstDepth: Int
    /// Directories never opened, e.g. privacy-protected folders that would trigger a prompt.
    let excluded: Set<String>
    let continuation: AsyncStream<WalkEvent>.Continuation
    let hardLinks = HardLinkRegistry()

    func run() async {
        let progress = ProgressEmitter(totalBytes: totalBytes, continuation: continuation)
        let normalizedRoots = roots.map {
            URL(fileURLWithPath: $0).standardizedFileURL.path
        }

        let results = await withTaskGroup(of: EntryResult?.self, returning: [EntryResult].self) { group in
            for path in normalizedRoots {
                guard !Task.isCancelled, let metadata = rootMetadata(path: path) else { continue }
                group.addTask(priority: .utility) {
                    await scanRoot(metadata, progress: progress)
                }
            }

            var collected: [EntryResult] = []
            for await result in group {
                if Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let result {
                    collected.append(result)
                }
            }
            return collected
        }

        guard !Task.isCancelled else {
            continuation.finish()
            return
        }

        let totalAllocated = results.reduce(0) { $0 + $1.allocated }
        let filesSeen = results.reduce(0) { $0 + $1.fileCount }
        let rootNode = combinedRoot(from: results, normalizedRoots: normalizedRoots)
        let unreadable = Array(Set(results.flatMap(\.unreadablePaths))).sorted()
        progress.record(
            bytes: 0,
            files: 0,
            path: normalizedRoots.last ?? "",
            force: true
        )
        continuation.yield(.finished(WalkResult(
            root: rootNode,
            totalAllocated: totalAllocated,
            filesSeen: filesSeen,
            unreadablePaths: unreadable
        )))
        continuation.finish()
    }

    private func scanRoot(_ metadata: RootMetadata, progress: ProgressEmitter) async -> EntryResult? {
        guard !Task.isCancelled, !metadata.entry.isSymlink else { return nil }
        if !metadata.entry.isDirectory {
            return await scanFile(metadata.entry, path: metadata.path, depth: 0, progress: progress)
        }

        let claimed = claimsAsUnit(metadata.path, true)
        guard var result = await scanDirectory(
            metadata.entry,
            path: metadata.path,
            rootDevice: metadata.entry.device,
            depth: 0,
            suppressItems: claimed,
            parallelChildren: true,
            progress: progress
        ) else {
            return nil
        }
        if claimed {
            result.node.children = []
            emitDirectoryItem(metadata.entry, path: metadata.path, result: result)
        }
        return result
    }

    private func scanEntry(
        _ entry: BulkEntry,
        path: String,
        rootDevice: Int32,
        depth: Int,
        suppressItems: Bool,
        progress: ProgressEmitter
    ) async -> EntryResult? {
        guard !Task.isCancelled, !entry.isSymlink else { return nil }
        guard entry.device == rootDevice else { return nil }
        if entry.isDirectory {
            let claimed = !suppressItems && claimsAsUnit(path, true)
            guard var result = await scanDirectory(
                entry,
                path: path,
                rootDevice: rootDevice,
                depth: depth,
                suppressItems: suppressItems || claimed,
                parallelChildren: false,
                progress: progress
            ) else {
                return nil
            }
            if claimed {
                result.node.children = []
                emitDirectoryItem(entry, path: path, result: result)
            }
            return result
        }
        return await scanFile(
            entry,
            path: path,
            depth: depth,
            suppressItem: suppressItems,
            progress: progress
        )
    }

    private func scanDirectory(
        _ entry: BulkEntry,
        path: String,
        rootDevice: Int32,
        depth: Int,
        suppressItems: Bool,
        parallelChildren: Bool,
        progress: ProgressEmitter
    ) async -> EntryResult? {
        guard !Task.isCancelled else { return nil }
        switch readDirectory(path: path, rootDevice: rootDevice) {
        case .skipped:
            return nil
        case .unreadable:
            return EntryResult(
                node: SizeNode(name: displayName(path), path: path, allocatedSize: 0),
                logical: 0,
                allocated: 0,
                reclaimable: 0,
                fileCount: 0,
                newestModified: entry.modified,
                unreadablePaths: [path]
            )
        case .entries(let children):
            let childResults: [EntryResult]
            if parallelChildren {
                childResults = await withTaskGroup(
                    of: EntryResult?.self,
                    returning: [EntryResult].self
                ) { group in
                    for child in children {
                        guard !Task.isCancelled else { break }
                        let childPath = (path as NSString).appendingPathComponent(child.name)
                        group.addTask(priority: .utility) {
                            await scanEntry(
                                child,
                                path: childPath,
                                rootDevice: rootDevice,
                                depth: depth + 1,
                                suppressItems: suppressItems,
                                progress: progress
                            )
                        }
                    }
                    var values: [EntryResult] = []
                    for await value in group {
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }
                        if let value {
                            values.append(value)
                            if depth == 0 { continuation.yield(.subtree(value.node)) }
                        }
                    }
                    return values
                }
            } else {
                var values: [EntryResult] = []
                for child in children {
                    guard !Task.isCancelled else { return nil }
                    let childPath = (path as NSString).appendingPathComponent(child.name)
                    if let value = await scanEntry(
                        child,
                        path: childPath,
                        rootDevice: rootDevice,
                        depth: depth + 1,
                        suppressItems: suppressItems,
                        progress: progress
                    ) {
                        values.append(value)
                    }
                }
                childResults = values
            }

            guard !Task.isCancelled else { return nil }
            let allocated = childResults.reduce(0) { $0 + $1.allocated }
            let visibleChildren = depth < sunburstDepth ? childResults.map(\.node) : []
            return EntryResult(
                node: SizeNode(
                    name: displayName(path),
                    path: path,
                    allocatedSize: allocated,
                    children: mergedAndSorted(visibleChildren, parentPath: path, parentSize: allocated)
                ),
                logical: childResults.reduce(0) { $0 + $1.logical },
                allocated: allocated,
                reclaimable: childResults.reduce(0) { $0 + $1.reclaimable },
                fileCount: childResults.reduce(0) { $0 + $1.fileCount },
                newestModified: childResults.reduce(entry.modified) {
                    max($0, $1.newestModified)
                },
                unreadablePaths: childResults.flatMap(\.unreadablePaths)
            )
        }
    }

    private func scanFile(
        _ entry: BulkEntry,
        path: String,
        depth: Int,
        suppressItem: Bool = false,
        progress: ProgressEmitter
    ) async -> EntryResult? {
        guard !Task.isCancelled else { return nil }

        var logical = entry.logicalSize
        var allocated = entry.allocatedSize
        var reclaimable = entry.privateSize >= 0 ? entry.privateSize : allocated
        var fileCount = 1
        var flags = itemFlags(for: entry)
        if entry.linkCount > 1 {
            flags.insert(.hardLinked)
            let inserted = await hardLinks.insert(FileIdentity(
                device: entry.device,
                fileID: entry.fileID
            ))
            if !inserted {
                logical = 0
                allocated = 0
                reclaimable = 0
                fileCount = 0
            }
        }
        if entry.extFlags & Self.sharesAllBlocks != 0 {
            reclaimable = 0
        }

        progress.record(bytes: allocated, files: fileCount, path: path)
        let claimed = !suppressItem && claimsAsUnit(path, false)
        if !suppressItem && (claimed || entry.allocatedSize >= Self.largeFileBytes) {
            continuation.yield(.item(ScannedItem(
                path: path,
                isDirectory: false,
                logicalSize: logical,
                allocatedSize: allocated,
                reclaimableSize: reclaimable,
                fileCount: fileCount,
                fileID: entry.fileID,
                device: entry.device,
                modified: entry.modified,
                flags: flags
            )))
        }

        return EntryResult(
            node: SizeNode(name: entry.name, path: path, allocatedSize: allocated),
            logical: logical,
            allocated: allocated,
            reclaimable: reclaimable,
            fileCount: fileCount,
            newestModified: entry.modified,
            unreadablePaths: []
        )
    }

    private func emitDirectoryItem(
        _ entry: BulkEntry,
        path: String,
        result: EntryResult
    ) {
        var flags = itemFlags(for: entry)
        if !result.unreadablePaths.isEmpty {
            flags.insert(.unreadable)
        }
        continuation.yield(.item(ScannedItem(
            path: path,
            isDirectory: true,
            logicalSize: result.logical,
            allocatedSize: result.allocated,
            reclaimableSize: result.reclaimable,
            fileCount: result.fileCount,
            fileID: entry.fileID,
            device: entry.device,
            modified: result.newestModified,
            flags: flags
        )))
    }

    private func itemFlags(for entry: BulkEntry) -> ItemFlags {
        var flags: ItemFlags = []
        if entry.extFlags & Self.sharesAllBlocks != 0 {
            flags.insert(.sharesAllBlocks)
        }
        if entry.extFlags & Self.mayShareBlocks != 0 {
            flags.insert(.maySharesBlocks)
        }
        if entry.extFlags & Self.isSparse != 0 {
            flags.insert(.sparse)
        }
        if entry.bsdFlags & Self.dataless != 0 {
            flags.insert(.dataless)
        }
        return flags
    }

    private func rootMetadata(path: String) -> RootMetadata? {
        var status = stat()
        guard lstat(path, &status) == 0 else { return nil }
        let mode = status.st_mode & S_IFMT
        let isDirectory = mode == S_IFDIR
        let isSymlink = mode == S_IFLNK
        let entry = BulkEntry(
            name: displayName(path),
            isDirectory: isDirectory,
            isSymlink: isSymlink,
            fileID: UInt64(status.st_ino),
            device: Int32(status.st_dev),
            logicalSize: isDirectory ? 0 : max(0, status.st_size),
            allocatedSize: isDirectory ? 0 : max(0, status.st_blocks * 512),
            privateSize: -1,
            extFlags: 0,
            bsdFlags: status.st_flags,
            linkCount: UInt32(status.st_nlink),
            modified: Date(
                timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)
            )
        )
        return RootMetadata(entry: entry, path: path)
    }

    private func readDirectory(path: String, rootDevice: Int32) -> DirectoryRead {
        guard !excluded.contains(path) else { return .unreadable }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            return errno == EACCES || errno == EPERM ? .unreadable : .skipped
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0, Int32(status.st_dev) == rootDevice else {
            return .skipped
        }

        let collector = EntryCollector()
        let context = Unmanaged.passUnretained(collector).toOpaque()
        let result = sweep_read_dir_cancellable(
            descriptor,
            context,
            collectEntry,
            scanCancelled
        )
        if result == ECANCELED {
            return .skipped
        }
        return result == 0 ? .entries(collector.entries) : .unreadable
    }

    private func mergedAndSorted(
        _ children: [SizeNode],
        parentPath: String,
        parentSize: Int64
    ) -> [SizeNode] {
        guard parentSize > 0 else {
            return sorted(children)
        }
        var visible: [SizeNode] = []
        var otherSize: Int64 = 0
        for child in children {
            if Double(child.allocatedSize) / Double(parentSize) < 0.01 {
                otherSize += child.allocatedSize
            } else {
                visible.append(child)
            }
        }
        if otherSize > 0 {
            visible.append(SizeNode(
                name: "Other",
                path: parentPath,
                allocatedSize: otherSize
            ))
        }
        return sorted(visible)
    }

    private func sorted(_ nodes: [SizeNode]) -> [SizeNode] {
        nodes.sorted {
            if $0.allocatedSize == $1.allocatedSize {
                return $0.name < $1.name
            }
            return $0.allocatedSize > $1.allocatedSize
        }
    }

    private func combinedRoot(
        from results: [EntryResult],
        normalizedRoots: [String]
    ) -> SizeNode {
        if results.count == 1, normalizedRoots.count == 1 {
            return results[0].node
        }
        let allocated = results.reduce(0) { $0 + $1.allocated }
        return SizeNode(
            name: "Scan",
            path: "",
            allocatedSize: allocated,
            children: mergedAndSorted(
                results.map(\.node),
                parentPath: "",
                parentSize: allocated
            )
        )
    }
}

private extension BulkEntry {
    init(
        name: String,
        isDirectory: Bool,
        isSymlink: Bool,
        fileID: UInt64,
        device: Int32,
        logicalSize: Int64,
        allocatedSize: Int64,
        privateSize: Int64,
        extFlags: UInt64,
        bsdFlags: UInt32,
        linkCount: UInt32,
        modified: Date
    ) {
        self.name = name
        self.isDirectory = isDirectory
        self.isSymlink = isSymlink
        self.fileID = fileID
        self.device = device
        self.logicalSize = logicalSize
        self.allocatedSize = allocatedSize
        self.privateSize = privateSize
        self.extFlags = extFlags
        self.bsdFlags = bsdFlags
        self.linkCount = linkCount
        self.modified = modified
    }
}

private func displayName(_ path: String) -> String {
    let name = URL(fileURLWithPath: path).lastPathComponent
    return name.isEmpty ? path : name
}
