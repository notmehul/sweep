import Foundation
import Testing
@testable import SweepSystem

@Test func probeAnswersWithoutCrashingOnEmptyHome() throws {
    let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: home) }
    #expect(FDAProbe.hasFullDiskAccess(home: home) == false)
}
