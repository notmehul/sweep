import Foundation
import FoundationModels
import Testing
@testable import SweepAI

@Test func templateExplainsCacheInPlainLanguage() async {
    let facts = FolderFacts(
        path: "~/Library/Application Support/Spotify/PersistentCache",
        allocatedBytes: 9_100_000_000,
        itemCount: 481,
        topChildren: [.init(name: "Storage", allocatedBytes: 8_700_000_000)],
        owningBundleID: "com.spotify.client",
        newestModificationDate: Date(timeIntervalSince1970: 1_781_748_000),
        fileTypeHistogram: ["data": 481]
    )

    let explanation = await TemplateExplainer().explainFolder(facts)

    #expect(explanation?.title == "PersistentCache")
    #expect(explanation?.kind == .cache)
    #expect(explanation?.whatItIs == "This folder holds 9.1 GB of temporary files used to make an app load faster.")
    #expect(explanation?.ifRemoved == "The app may recreate or download these files the next time you use it.")
}

@Test func templateSummaryAlwaysReturnsASentence() async {
    let facts = ScanSummaryFacts(
        freeableBytes: 12_400_000_000,
        perBucketBytes: .init(rebuilds: 9_100_000_000, review: 3_300_000_000, yours: 800_000_000),
        topFindings: [.init(title: "Spotify cache", allocatedBytes: 9_100_000_000)],
        coverage: 0.92
    )

    let summary = await TemplateExplainer().summarize(facts)

    #expect(summary == "Sweep found 12 GB you could free: 9.1 GB can be rebuilt and 3.3 GB needs your review, after scanning 92% of your Mac.")
    #expect(summary.hasSuffix("."))
}

@Test func templateSummaryHandlesNoFindings() async {
    let facts = ScanSummaryFacts(
        freeableBytes: 0,
        perBucketBytes: .init(rebuilds: 0, review: 0, yours: 0),
        topFindings: [],
        coverage: 1
    )

    #expect(await TemplateExplainer().summarize(facts) == "Sweep did not find any space to free after scanning 100% of your Mac.")
}

@Test func templateNarratesGrowthAndShrinkage() async {
    let changes = [
        ChangeFact(name: "Spotify cache", deltaBytes: 1_200_000_000, period: "this week"),
        ChangeFact(name: "Downloads", deltaBytes: -500_000_000, period: "this week"),
    ]

    let narration = await TemplateExplainer().narrate(changes)

    #expect(narration == "Spotify cache grew by 1.2 GB this week; Downloads shrank by 500 MB this week.")
    #expect(await TemplateExplainer().narrate([]) == nil)
}

@Test func postFilterRejectsBannedClaimsAndInventedNumbers() {
    let facts = "Size: 9.1 GB; count: 481"

    #expect(ModelOutputFilter.accepts("It uses 9.1 GB across 481 files.", allowedFactText: facts))
    #expect(!ModelOutputFilter.accepts("It is safe to delete.", allowedFactText: facts))
    #expect(!ModelOutputFilter.accepts("This is guaranteed to work.", allowedFactText: facts))
    #expect(!ModelOutputFilter.accepts("It uses 10 GB.", allowedFactText: facts))
}

@Test func postFilterEnforcesFolderShape() {
    let valid = FolderExplanation(
        title: "Spotify Cache",
        whatItIs: "It holds 9.1 GB of temporary music files.",
        ifRemoved: "Spotify may download 9.1 GB again.",
        kind: .cache
    )
    let longTitle = FolderExplanation(
        title: "One Two Three Four Five Six",
        whatItIs: valid.whatItIs,
        ifRemoved: valid.ifRemoved,
        kind: .cache
    )

    #expect(ModelOutputFilter.accepts(valid, allowedFactText: "Spotify 9.1 GB"))
    #expect(!ModelOutputFilter.accepts(longTitle, allowedFactText: "Spotify 9.1 GB"))
}

@Test func availabilityReasonsArePlainLanguage() {
    #expect(AIStatus.from(.available) == .ready)
    #expect(AIStatus.from(.unavailable(.modelNotReady)) == .downloading)
    #expect(
        AIStatus.from(.unavailable(.appleIntelligenceNotEnabled))
            == .off(reason: "Apple Intelligence is turned off.")
    )
    #expect(
        AIStatus.from(.unavailable(.deviceNotEligible))
            == .off(reason: "Apple Intelligence is not available on this Mac.")
    )
}

private struct EmptyExplainer: Explaining {
    func explainFolder(_ facts: FolderFacts) async -> FolderExplanation? { nil }
    func summarize(_ facts: ScanSummaryFacts) async -> String { "" }
    func narrate(_ changes: [ChangeFact]) async -> String? { nil }
}

@Test func resilientExplainerFallsBackWhenPrimaryHasNoAnswer() async {
    let facts = ScanSummaryFacts(
        freeableBytes: 2_000_000_000,
        perBucketBytes: .init(rebuilds: 2_000_000_000, review: 0, yours: 0),
        topFindings: [],
        coverage: 0.5
    )
    let explainer = ResilientExplainer(primary: EmptyExplainer(), fallback: TemplateExplainer())

    let summary = await explainer.summarize(facts)

    #expect(summary == "Sweep found 2.0 GB you could free: 2.0 GB can be rebuilt, after scanning 50% of your Mac.")
}
