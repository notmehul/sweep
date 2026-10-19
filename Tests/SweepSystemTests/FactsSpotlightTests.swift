import Foundation
import Testing
@testable import SweepSystem

@Test func spotlightScopedQueriesReturnWithoutCrashing() throws {
    let home = FileManager.default.temporaryDirectory
        .appendingPathComponent("SweepSpotlight-\(UUID().uuidString)", isDirectory: true)
    let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: home) }
    try Data("fixture".utf8).write(to: downloads.appendingPathComponent("fixture.txt"))

    let spotlight = Spotlight(timeout: 0.2, applicationScope: home.path)
    let probe: Bool = spotlight.spotlightWorks
    _ = spotlight.lastOpened(path: downloads.appendingPathComponent("fixture.txt").path)
    _ = spotlight.dateAdded(path: downloads.appendingPathComponent("fixture.txt").path)
    _ = spotlight.downloadsNeverOpened(home: home.path)
    _ = spotlight.bigStaleFiles(home: home.path, minBytes: 1, olderThanDays: 1)
    _ = spotlight.screenshots(home: home.path)

    #expect(probe == true || probe == false)
}
