import Darwin
import Foundation

final class FixtureTree {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    func directory(_ relativePath: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }

    func regularFile(_ relativePath: String, size: Int) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }

        let chunkSize = min(size, 256 * 1024)
        let chunk = Data((0..<chunkSize).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 17) })
        var remaining = size
        while remaining > 0 {
            let count = min(remaining, chunk.count)
            try handle.write(contentsOf: chunk.prefix(count))
            remaining -= count
        }
        return url
    }

    func sparseFile(_ relativePath: String, logicalSize: Int64) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let descriptor = open(url.path, O_CREAT | O_EXCL | O_RDWR, 0o600)
        guard descriptor >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard ftruncate(descriptor, logicalSize) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        var byte: UInt8 = 0xA5
        guard pwrite(descriptor, &byte, 1, 0) == 1 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return url
    }

    func clone(_ source: URL, to relativePath: String) throws -> URL {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard clonefile(source.path, destination.path, 0) == 0 else {
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }
        return destination
    }

    func hardLink(_ source: URL, to relativePath: String) throws -> URL {
        let destination = root.appendingPathComponent(relativePath)
        try FileManager.default.linkItem(at: source, to: destination)
        return destination
    }

    func symlink(_ relativePath: String, destination: String) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createSymbolicLink(
            atPath: url.path,
            withDestinationPath: destination
        )
        return url
    }

    func allocatedBytesDeduplicatingHardLinks() throws -> Int64 {
        let keys: [URLResourceKey] = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys
        ) else {
            return 0
        }

        var identities: Set<FileIdentity> = []
        var total: Int64 = 0
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            var status = stat()
            guard lstat(url.path, &status) == 0 else { continue }
            let identity = FileIdentity(device: status.st_dev, inode: status.st_ino)
            guard identities.insert(identity).inserted else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private struct FileIdentity: Hashable {
    var device: dev_t
    var inode: ino_t
}
