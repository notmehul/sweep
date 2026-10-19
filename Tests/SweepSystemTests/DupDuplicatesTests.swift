import Darwin
import Foundation
import SweepCore
import Testing
@testable import SweepSystem

@Test func duplicateFinderConfirmsIdenticalFiles() async throws {
    let fixture = try DuplicateFixture()
    defer { fixture.remove() }
    let first = try fixture.write("first.bin", byte: 0x41, count: 1_200_000)
    let second = try fixture.write("second.bin", byte: 0x41, count: 1_200_000)
    let largerA = try fixture.write("larger-a.bin", byte: 0x42, count: 2_000_000)
    let largerB = try fixture.write("larger-b.bin", byte: 0x42, count: 2_000_000)
    let largerC = try fixture.write("larger-c.bin", byte: 0x42, count: 2_000_000)

    let groups = await findDuplicates(
        try [first, second, largerA, largerB, largerC].map(scannedItem)
    )

    #expect(groups.count == 2)
    #expect(groups[0].count == 3)
    #expect(Set(groups[0].map(\.path)) == Set([largerA.path, largerB.path, largerC.path]))
    #expect(Set(groups[1].map(\.path)) == Set([first.path, second.path]))
}

@Test func duplicateFinderRejectsSameSizeDifferentContent() async throws {
    let fixture = try DuplicateFixture()
    defer { fixture.remove() }
    let first = try fixture.write("first.bin", byte: 0x41, count: 1_200_000)
    let second = try fixture.write("second.bin", byte: 0x42, count: 1_200_000)

    let groups = await findDuplicates(try [first, second].map(scannedItem))

    #expect(groups.isEmpty)
}

@Test func duplicateFinderExcludesClonefileCopies() async throws {
    let fixture = try DuplicateFixture()
    defer { fixture.remove() }
    let original = try fixture.write("original.bin", byte: 0x43, count: 1_200_000)
    let clone = fixture.root.appendingPathComponent("clone.bin")
    try #require(clonefile(original.path, clone.path, 0) == 0)

    let groups = await findDuplicates(try [original, clone].map(scannedItem))

    #expect(groups.isEmpty)
}

@Test func duplicateFinderExcludesHardLinks() async throws {
    let fixture = try DuplicateFixture()
    defer { fixture.remove() }
    let original = try fixture.write("original.bin", byte: 0x44, count: 1_200_000)
    let linked = fixture.root.appendingPathComponent("linked.bin")
    try #require(link(original.path, linked.path) == 0)

    let groups = await findDuplicates(try [original, linked].map(scannedItem))

    #expect(groups.isEmpty)
}

private struct DuplicateFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepDuplicates-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func write(_ name: String, byte: UInt8, count: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(repeating: byte, count: count).write(to: url)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

private func scannedItem(_ url: URL) throws -> ScannedItem {
    var status = stat()
    try #require(lstat(url.path, &status) == 0)
    let allocated = Int64(status.st_blocks) * 512
    return ScannedItem(
        path: url.path,
        isDirectory: false,
        logicalSize: status.st_size,
        allocatedSize: allocated,
        reclaimableSize: allocated,
        fileCount: 1,
        fileID: status.st_ino,
        device: status.st_dev,
        modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
    )
}
