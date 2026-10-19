import Foundation
import SweepCore
import Testing
@testable import SweepSystem

private struct CandidateFacts: CandidateCollectionFacts {
    var homeDirectory: String
    var now = Date(timeIntervalSince1970: 2_000_000_000)
    var installedApplications: [InstalledApplication] = []

    func isInstalled(bundleID: String) -> Bool { false }
    func isRunning(bundleID: String) -> Bool { false }
    func lastOpened(path: String) -> Date? { nil }
    var spotlightWorks: Bool { true }
    func gitState(repoContaining path: String) -> GitState? { nil }
    var hasDeveloperTools: Bool { false }
}

@Test func candidateCollectorFindsSmallNamedFilesAppsAndDuplicates() async throws {
    let fixture = try FixtureTree()
    defer { fixture.remove() }
    let app = try fixture.directory("Applications/Old App.app")
    _ = try fixture.regularFile("Documents/id_ed25519", size: 32)
    _ = try fixture.regularFile("Documents/monkey.jpg", size: 32)
    _ = try fixture.regularFile("Desktop/Screen Recording 2026-03-01.mov", size: 32)
    _ = try fixture.regularFile("Downloads/copy-a.bin", size: 1_100_000)
    _ = try fixture.regularFile("Documents/copy-b.bin", size: 1_100_000)
    let facts = CandidateFacts(
        homeDirectory: fixture.root.path,
        installedApplications: [
            InstalledApplication(
                path: app.path,
                bundleID: "com.example.old",
                displayName: "Old App",
                allocatedSize: 8_192,
                lastUsed: nil,
                dateAdded: Date(timeIntervalSince1970: 1_000)
            ),
        ]
    )

    let candidates = await CandidateCollector().collect(
        home: fixture.root.path,
        facts: facts,
        walkerItems: []
    )
    let names = Set(candidates.extraItems.map {
        URL(fileURLWithPath: $0.path).lastPathComponent
    })

    #expect(names.contains("Old App.app"))
    #expect(names.contains("id_ed25519"))
    #expect(names.contains("Screen Recording 2026-03-01.mov"))
    #expect(!names.contains("monkey.jpg"))
    #expect(candidates.duplicateGroups.count == 1)
    #expect(candidates.duplicateGroups.first?.count == 2)
}
