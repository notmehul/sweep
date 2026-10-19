import Foundation
import FoundationModels
import Testing
@testable import SweepAI

private let facts = """
    Total: 3.0 GB
    Largest items: Playwright browsers: 964 MB; Homebrew downloads: 844 MB; WhatsApp cache: 708 MB
    """

@Test func bucketSummaryDescribesTheSpaceAndLeavesConsequencesToSweep() {
    let describes = "Most of this is Playwright's test browsers (964 MB) and Homebrew downloads (844 MB)."
    let promises = "Most of this is Playwright browsers (964 MB), which download again when needed."
    let threatens = "Most of this is Playwright browsers (964 MB), which would be lost if removed."

    #expect(ModelOutputFilter.acceptsBucketSummary(describes, allowedFactText: facts))
    #expect(!ModelOutputFilter.acceptsBucketSummary(promises, allowedFactText: facts))
    #expect(!ModelOutputFilter.acceptsBucketSummary(threatens, allowedFactText: facts))
}

@Test func fileNamesAndDecimalsDoNotEndASentence() {
    #expect(ModelOutputFilter.sentenceCount("Most of this is setup.dmg (2.0 GB) and state.vscdb.") == 1)
    #expect(ModelOutputFilter.sentenceCount("It is a cache. It comes back.") == 2)
}

@Test func bucketSummaryRejectsInventedNumbersAndExtraSentences() {
    let invented = "Most of this is Playwright browsers (1.2 GB)."
    let long = "Playwright uses 964 MB. Homebrew uses 844 MB."

    #expect(!ModelOutputFilter.acceptsBucketSummary(invented, allowedFactText: facts))
    #expect(!ModelOutputFilter.acceptsBucketSummary(long, allowedFactText: facts))
}

@Test func liveBucketSummaryNamesTheLargestItemsThenSaysWhatHappens() async throws {
    guard SystemLanguageModel.default.availability == .available else { return }
    let explainer = OnDeviceExplainer()

    let rebuilds = try #require(await explainer.summarizeBucket(.init(
        kind: .rebuilds, totalBytes: 3_000_000_000, itemCount: 18,
        largest: [.init(title: "Playwright browsers", group: "Developer tool caches", allocatedBytes: 964_300_000),
                  .init(title: "Homebrew downloads", group: "Developer tool caches", allocatedBytes: 844_000_000),
                  .init(title: "WhatsApp cache", group: "App caches", allocatedBytes: 708_000_000)])))
    let review = try #require(await explainer.summarizeBucket(.init(
        kind: .review, totalBytes: 24_400_000_000, itemCount: 3,
        largest: [.init(title: "DaVinci Resolve", group: "Apps you don't use", allocatedBytes: 4_100_000_000),
                  .init(title: "setup.dmg", group: "Old downloads", allocatedBytes: 2_000_000_000)])))
    print("LIVE bucket rebuilds:", rebuilds, "| review:", review)

    #expect(rebuilds.contains("Playwright"))
    #expect(rebuilds.hasSuffix(OnDeviceExplainer.fate(of: .rebuilds)))
    #expect(review.hasSuffix(OnDeviceExplainer.fate(of: .review)))
}
