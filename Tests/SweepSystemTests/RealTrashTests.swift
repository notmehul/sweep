import Foundation
@testable import SweepCore
import SweepStore
import Testing
@testable import SweepSystem

/// Moves a file Sweep itself creates in ~/Downloads to the real Trash, then undoes it.
/// Run with `SWEEP_REAL_TRASH=1 swift test --filter RealTrash`. Touches no user files.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWEEP_REAL_TRASH"] == "1"))
func RealTrashRoundTrip() async throws {
    let home = NSHomeDirectory()
    let path = (home as NSString).appendingPathComponent("Downloads/sweep-e2e-\(UUID().uuidString).txt")
    let content = Data("Sweep end-to-end test file. Safe to delete.\n".utf8)
    try content.write(to: URL(fileURLWithPath: path))
    defer { try? FileManager.default.removeItem(atPath: path) }

    let attributes = try FileManager.default.attributesOfItem(atPath: path)
    let item = ScannedItem(path: path, isDirectory: false, logicalSize: Int64(content.count),
                           allocatedSize: (try URL(fileURLWithPath: path).resourceValues(forKeys: [.totalFileAllocatedSizeKey])).totalFileAllocatedSize.map(Int64.init) ?? 4096,
                           reclaimableSize: 4096, fileCount: 1,
                           fileID: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0,
                           device: (attributes[.systemNumber] as? NSNumber)?.int32Value ?? 0,
                           modified: attributes[.modificationDate] as? Date ?? .now)
    let finding = Finding(id: "e2e", ruleID: "generic.downloads-never-opened", title: "Sweep test file",
                          group: "Old downloads", bucket: .review, items: [item], evidence: [], lastUsed: nil,
                          action: .trash, explanation: Explanation(whatItIs: "", ifRemoved: "", whyStale: ""),
                          isDeveloper: false)

    let store = try Store(path: FileManager.default.temporaryDirectory.appendingPathComponent("sweep-e2e-\(UUID().uuidString).sqlite"))
    let executor = CleanupExecutor(store: store, facts: MacFacts(measureApplicationSizes: false))
    let report = await executor.clean([finding])
    print("REALTRASH trashed=\(report.trashedCount) skipped=\(report.skipped.map(\.reason))")
    #expect(report.trashedCount == 1)
    #expect(!FileManager.default.fileExists(atPath: path))

    let restored = await executor.undoLast()
    #expect(restored)
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == content)
    print("REALTRASH restored=\(restored) identical=\((try? Data(contentsOf: URL(fileURLWithPath: path))) == content)")
}
