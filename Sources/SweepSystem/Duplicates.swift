import CryptoKit
import Darwin
import Foundation
import SweepCore

private let duplicateMinimumSize: Int64 = 1_048_576
private let sampleSize = 65_536

/// Confirms duplicate regular files in two hashing passes. Files that could download from
/// iCloud or share storage with another path are rejected before any content is opened.
public func findDuplicates(_ items: [ScannedItem]) async -> [[ScannedItem]] {
    let candidates = items.compactMap(DuplicateCandidate.init)
    let sizeGroups = Dictionary(grouping: candidates, by: { $0.item.logicalSize })
        .values
        .filter { $0.count > 1 }

    let sampled = await withTaskGroup(of: SampledCandidate?.self) { group in
        for candidates in sizeGroups {
            for candidate in candidates {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled,
                          let digest = try? sampleDigest(candidate)
                    else {
                        return nil
                    }
                    return SampledCandidate(candidate: candidate, digest: digest)
                }
            }
        }

        var result: [SampledCandidate] = []
        for await candidate in group {
            if let candidate { result.append(candidate) }
        }
        return result
    }

    let sampleGroups = Dictionary(grouping: sampled) {
        SampleKey(size: $0.candidate.item.logicalSize, digest: $0.digest)
    }.values.filter { $0.count > 1 }

    let fullyHashed = await withTaskGroup(of: FullyHashedCandidate?.self) { group in
        for candidates in sampleGroups {
            for candidate in candidates {
                group.addTask(priority: .utility) {
                    guard !Task.isCancelled,
                          let digest = try? fullDigest(candidate.candidate)
                    else {
                        return nil
                    }
                    return FullyHashedCandidate(candidate: candidate.candidate, digest: digest)
                }
            }
        }

        var result: [FullyHashedCandidate] = []
        for await candidate in group {
            if let candidate { result.append(candidate) }
        }
        return result
    }

    var duplicateGroups: [[ScannedItem]] = []
    let hashGroups = Dictionary(grouping: fullyHashed) {
        FullKey(size: $0.candidate.item.logicalSize, digest: $0.digest)
    }
    for matches in hashGroups.values where matches.count > 1 {
        var cloneIDs = Set<UInt64>()
        let independent = matches.filter { match in
            let cloneID = match.candidate.cloneID
            return cloneID == 0 || cloneIDs.insert(cloneID).inserted
        }
        guard independent.count > 1 else { continue }
        duplicateGroups.append(independent.map(\.candidate.item).sorted { $0.path < $1.path })
    }

    return duplicateGroups.sorted {
        let left = wastedBytes(in: $0)
        let right = wastedBytes(in: $1)
        return left == right ? $0[0].path < $1[0].path : left > right
    }
}

private struct DuplicateCandidate: Sendable {
    let item: ScannedItem
    let cloneID: UInt64

    init?(_ item: ScannedItem) {
        guard !item.isDirectory,
              item.logicalSize >= duplicateMinimumSize,
              item.flags.isDisjoint(with: [.dataless, .sharesAllBlocks, .hardLinked]),
              let metadata = fileMetadata(path: item.path),
              metadata.isRegular,
              !metadata.isDataless,
              !metadata.sharesAllBlocks,
              !metadata.isHardLinked
        else {
            return nil
        }
        self.item = item
        self.cloneID = metadata.cloneID
    }
}

private struct FileMetadata {
    let isRegular: Bool
    let isDataless: Bool
    let sharesAllBlocks: Bool
    let isHardLinked: Bool
    let cloneID: UInt64
}

private func fileMetadata(path: String) -> FileMetadata? {
    var status = stat()
    guard lstat(path, &status) == 0 else { return nil }
    let kind = status.st_mode & mode_t(S_IFMT)
    let extendedFlags = extendedAttribute(path: path, attribute: UInt32(ATTR_CMNEXT_EXT_FLAGS))
    return FileMetadata(
        isRegular: kind == mode_t(S_IFREG),
        isDataless: (status.st_flags & UInt32(SF_DATALESS)) != 0,
        sharesAllBlocks: (extendedFlags & UInt64(EF_SHARES_ALL_BLOCKS)) != 0,
        isHardLinked: status.st_nlink > 1,
        cloneID: extendedAttribute(path: path, attribute: UInt32(ATTR_CMNEXT_CLONEID))
    )
}

/// CMNEXT values are returned in a 4-byte-packed getattrlist buffer after its length word.
private func extendedAttribute(path: String, attribute: UInt32) -> UInt64 {
    var attributes = attrlist()
    attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
    attributes.forkattr = attribute
    var buffer = [UInt8](repeating: 0, count: 16)
    let result = path.withCString { fileSystemPath in
        buffer.withUnsafeMutableBytes { bytes in
            let options = UInt32(FSOPT_NOFOLLOW | FSOPT_ATTR_CMN_EXTENDED)
            return getattrlist(
                fileSystemPath,
                &attributes,
                bytes.baseAddress,
                bytes.count,
                options
            )
        }
    }
    guard result == 0 else { return 0 }
    return buffer.withUnsafeBytes { bytes in
        bytes.loadUnaligned(fromByteOffset: 4, as: UInt64.self)
    }
}

private struct SampledCandidate: Sendable {
    let candidate: DuplicateCandidate
    let digest: [UInt8]
}

private struct FullyHashedCandidate: Sendable {
    let candidate: DuplicateCandidate
    let digest: [UInt8]
}

private struct SampleKey: Hashable {
    let size: Int64
    let digest: [UInt8]
}

private struct FullKey: Hashable {
    let size: Int64
    let digest: [UInt8]
}

private func sampleDigest(_ candidate: DuplicateCandidate) throws -> [UInt8] {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: candidate.item.path))
    defer { try? handle.close() }

    let first = try handle.read(upToCount: sampleSize) ?? Data()
    let endOffset = try handle.seekToEnd()
    try handle.seek(toOffset: endOffset > UInt64(sampleSize) ? endOffset - UInt64(sampleSize) : 0)
    let last = try handle.read(upToCount: sampleSize) ?? Data()

    var hasher = SHA256()
    hasher.update(data: first)
    hasher.update(data: last)
    return Array(hasher.finalize())
}

private func fullDigest(_ candidate: DuplicateCandidate) throws -> [UInt8] {
    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: candidate.item.path))
    defer { try? handle.close() }

    var hasher = SHA256()
    while !Task.isCancelled {
        guard let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty else {
            return Array(hasher.finalize())
        }
        hasher.update(data: chunk)
    }
    throw CancellationError()
}

private func wastedBytes(in items: [ScannedItem]) -> Int64 {
    let total = items.reduce(Int64(0)) { $0 + max(0, $1.reclaimableSize) }
    return total - (items.map(\.reclaimableSize).max() ?? 0)
}
