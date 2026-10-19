import Foundation
import FoundationModels
import Testing
@testable import SweepAI

@Test func liveModelProducesFilteredFolderExplanationAndSummary() async throws {
    guard SystemLanguageModel.default.availability == .available else { return }

    let folderFacts = FolderFacts(
        path: "~/Library/Application Support/Spotify/PersistentCache",
        allocatedBytes: 9_100_000_000,
        itemCount: 481,
        topChildren: [
            .init(name: "Storage", allocatedBytes: 8_700_000_000),
            .init(name: "Index", allocatedBytes: 400_000_000),
        ],
        owningBundleID: "com.spotify.client",
        newestModificationDate: Date(timeIntervalSince1970: 1_781_748_000),
        fileTypeHistogram: ["data": 480, "database": 1]
    )
    let summaryFacts = ScanSummaryFacts(
        freeableBytes: 12_400_000_000,
        perBucketBytes: .init(
            rebuilds: 9_100_000_000,
            review: 3_300_000_000,
            yours: 800_000_000
        ),
        topFindings: [
            .init(title: "Spotify cache", allocatedBytes: 9_100_000_000),
            .init(title: "Old installer", allocatedBytes: 3_300_000_000),
        ],
        coverage: 0.92
    )
    let explainer = OnDeviceExplainer()

    let explanation = try #require(await explainer.explainFolder(folderFacts))
    let summary = await explainer.summarize(summaryFacts)
    let combined = "\(explanation.title) \(explanation.whatItIs) \(explanation.ifRemoved) \(summary)".lowercased()

    #expect((1...5).contains(explanation.title.split(whereSeparator: \.isWhitespace).count))
    #expect(!explanation.whatItIs.isEmpty)
    #expect(!explanation.ifRemoved.isEmpty)
    #expect(!summary.isEmpty)
    #expect(!combined.contains("safe to delete"))
    #expect(!combined.contains("guaranteed"))

    print("LIVE_FOLDER_TITLE: \(explanation.title)")
    print("LIVE_FOLDER_WHAT: \(explanation.whatItIs)")
    print("LIVE_FOLDER_REMOVAL: \(explanation.ifRemoved)")
    print("LIVE_SUMMARY: \(summary)")
}
