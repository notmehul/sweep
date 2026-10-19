import Darwin
import Foundation
import SweepCore
import Testing
@testable import SweepSystem

private struct CollectedEvents {
    var progress: [ScanProgress] = []
    var items: [ScannedItem] = []
    var result: WalkResult?
    var subtrees: [SizeNode] = []
}

private func collect(_ stream: AsyncStream<WalkEvent>) async -> CollectedEvents {
    var collected = CollectedEvents()
    for await event in stream {
        switch event {
        case .progress(let progress):
            collected.progress.append(progress)
        case .item(let item):
            collected.items.append(item)
        case .subtree(let node):
            collected.subtrees.append(node)
        case .finished(let result):
            collected.result = result
        }
    }
    return collected
}

private func node(at path: String, in root: SizeNode) -> SizeNode? {
    if root.path == path { return root }
    for child in root.children {
        if let match = node(at: path, in: child) {
            return match
        }
    }
    return nil
}

@Test func sparseFileUsesAllocatedRatherThanLogicalSize() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let sparse = try fixture.sparseFile("sparse.bin", logicalSize: 64 * 1024 * 1024)

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 64 * 1024 * 1024,
        claimsAsUnit: { path, _ in path == sparse.path }
    ))
    let item = try #require(events.items.first { $0.path == sparse.path })

    #expect(item.logicalSize == 64 * 1024 * 1024)
    #expect(item.allocatedSize < item.logicalSize)
    #expect(item.flags.contains(.sparse))
}

@Test func cloneReportsOnlyItsPrivateReclaimableSpace() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let source = try fixture.regularFile("source.bin", size: 2 * 1024 * 1024)
    let clone = try fixture.clone(source, to: "clone.bin")

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 4 * 1024 * 1024,
        claimsAsUnit: { path, isDirectory in !isDirectory && (path == source.path || path == clone.path) }
    ))
    let cloneItem = try #require(events.items.first { $0.path == clone.path })

    #expect(cloneItem.reclaimableSize <= cloneItem.allocatedSize)
    if cloneItem.flags.contains(.sharesAllBlocks) {
        #expect(cloneItem.reclaimableSize == 0)
    }
    #expect(
        cloneItem.flags.contains(.sharesAllBlocks) ||
        cloneItem.flags.contains(.maySharesBlocks) ||
        cloneItem.reclaimableSize < cloneItem.allocatedSize
    )
}

@Test func hardLinksAreCountedOnce() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let original = try fixture.regularFile("original.bin", size: 1024 * 1024)
    _ = try fixture.hardLink(original, to: "linked.bin")
    let expected = try fixture.allocatedBytesDeduplicatingHardLinks()

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: expected,
        claimsAsUnit: { _, _ in false }
    ))
    let result = try #require(events.result)

    #expect(result.filesSeen == 1)
    #expect(result.totalAllocated == expected)
}

@Test func symlinkLoopIsNotFollowed() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    _ = try fixture.regularFile("inside/file.bin", size: 64 * 1024)
    _ = try fixture.symlink("inside/loop", destination: "..")

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 64 * 1024,
        claimsAsUnit: { _, _ in false }
    ))
    let result = try #require(events.result)

    #expect(result.filesSeen == 1)
    #expect(result.unreadablePaths.isEmpty)
}

@Test func claimedDirectoryEmitsOneItemAndNoChildren() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let claimed = try fixture.directory("claimed")
    _ = try fixture.regularFile("claimed/one.bin", size: 128 * 1024)
    _ = try fixture.regularFile("claimed/nested/two.bin", size: 256 * 1024)

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 384 * 1024,
        claimsAsUnit: { path, _ in
            path == claimed.path || path.hasPrefix(claimed.path + "/")
        }
    ))
    let result = try #require(events.result)
    let item = try #require(events.items.first)
    let claimedNode = try #require(node(at: claimed.path, in: result.root))

    #expect(events.items.count == 1)
    #expect(item.path == claimed.path)
    #expect(item.isDirectory)
    #expect(item.fileCount == 2)
    #expect(claimedNode.children.isEmpty)
}

@Test func totalsMatchFileManagerAndProgressFinishesAtTotal() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    _ = try fixture.regularFile("one.bin", size: 1024 * 1024)
    _ = try fixture.regularFile("folder/two.bin", size: 3 * 1024 * 1024)
    let expected = try fixture.allocatedBytesDeduplicatingHardLinks()

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: expected,
        claimsAsUnit: { _, _ in false }
    ))
    let result = try #require(events.result)
    let finalProgress = try #require(events.progress.last)
    let tolerance = max(Int64(1), expected / 100)

    #expect(abs(result.totalAllocated - expected) <= tolerance)
    #expect(!events.progress.isEmpty)
    #expect(finalProgress.scannedBytes == result.totalAllocated)
    #expect(finalProgress.totalBytes == expected)
    #expect(finalProgress.filesSeen == result.filesSeen)
}

@Test func unreadableDirectoryIsReportedAndClaimMarkedPartial() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let unreadable = try fixture.directory("unreadable")
    _ = try fixture.regularFile("unreadable/file.bin", size: 4096)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0],
        ofItemAtPath: unreadable.path
    )
    defer {
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: unreadable.path
        )
    }

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 4096,
        claimsAsUnit: { path, _ in path == unreadable.path }
    ))
    let result = try #require(events.result)
    let item = try #require(events.items.first { $0.path == unreadable.path })

    #expect(result.unreadablePaths == [unreadable.path])
    #expect(item.flags.contains(.unreadable))
    #expect(item.fileCount == 0)
}

@Test func largeRegularFileIsEmittedWithoutAClaim() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let large = try fixture.regularFile("large.bin", size: 51 * 1024 * 1024)

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 51 * 1024 * 1024,
        claimsAsUnit: { _, _ in false }
    ))

    #expect(events.items.contains { $0.path == large.path })
}

@Test func everyClaimedItemIsDelivered() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    for index in 0..<300 {
        _ = try fixture.regularFile("claimed/\(index).bin", size: 1)
    }

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 300,
        claimsAsUnit: { _, isDirectory in !isDirectory }
    ))

    #expect(events.items.count == 300)
}

@Test func cancellationStopsBeforeFinishedEvent() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    for index in 0..<500 {
        _ = try fixture.regularFile("single/\(index).bin", size: 4096)
    }

    let stream = Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 500 * 4096,
        claimsAsUnit: { _, _ in
            usleep(2_000)
            return false
        }
    )
    let consumer = Task {
        var sawFinished = false
        for await event in stream {
            if case .finished = event {
                sawFinished = true
            }
        }
        return sawFinished
    }
    try await Task.sleep(nanoseconds: 30_000_000)
    consumer.cancel()

    #expect(await consumer.value == false)
}

@Test func volumeInfoHasConsistentCapacities() throws {
    let info = try VolumeInfo.home()
    #expect(info.usedBytes >= 0)
    #expect(info.freeBytes >= 0)
    #expect(info.purgeableBytes >= 0)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["SWEEP_HOME_BENCH"] == "1"))
func HomeBench() async throws {
    let volume = try VolumeInfo.home()
    let start = ContinuousClock.now
    let events = await collect(Walker().scan(
        roots: [NSHomeDirectory()],
        totalBytes: volume.usedBytes,
        claimsAsUnit: { _, _ in false }
    ))
    let elapsed = start.duration(to: .now)
    let result = try #require(events.result)
    print(
        "SWEEP_HOME_BENCH elapsed=\(elapsed) " +
        "totalAllocated=\(result.totalAllocated) files=\(result.filesSeen)"
    )
}

@Test func emitsEachTopLevelFolderAsItFinishes() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    _ = try fixture.regularFile("a/one.bin", size: 1024 * 1024)
    _ = try fixture.regularFile("b/two.bin", size: 2 * 1024 * 1024)

    let events = await collect(Walker().scan(
        roots: [fixture.root.path],
        totalBytes: 3 * 1024 * 1024,
        claimsAsUnit: { _, _ in false }
    ))
    let result = try #require(events.result)

    #expect(Set(events.subtrees.map(\.name)) == ["a", "b"])
    for subtree in events.subtrees {
        let final = try #require(node(at: subtree.path, in: result.root))
        #expect(final.allocatedSize == subtree.allocatedSize)
    }
}
