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
    print("LIVE title:", explanation.title, "| what:", explanation.whatItIs, "| removed:", explanation.ifRemoved, "| summary:", summary)
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

    let projects = FolderFacts(
        path: "~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Resolve Project Library",
        allocatedBytes: 64_000_000, itemCount: 212,
        topChildren: [.init(name: "Resolve Projects", allocatedBytes: 60_000_000)],
        owningBundleID: "com.blackmagic-design.DaVinciResolve",
        newestModificationDate: Date(timeIntervalSince1970: 1_781_748_000),
        fileTypeHistogram: ["database": 4, "data": 208])
    // nil is an acceptable answer: the filter rejects any promise that user data comes back.
    if let projectExplanation = await explainer.explainFolder(projects) {
        print("LIVE2 title:", projectExplanation.title, "| what:", projectExplanation.whatItIs, "| removed:", projectExplanation.ifRemoved)
        #expect(!projectExplanation.ifRemoved.lowercased().contains("rebuild"))
    } else {
        print("LIVE2 rejected by filter")
    }
}
