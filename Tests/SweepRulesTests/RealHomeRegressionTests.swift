import Foundation
@testable import SweepCore
import SweepRules
import Testing

// Cases seen on a real Mac on 19 Oct 2026, where the first catalog offered things it must not.

private func classify(_ relatives: [(String, Bool)], repositories: [String] = [], opened: [String: Date] = [:],
                      added: [String: Date] = [:]) throws -> [Finding] {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let facts = CatalogFakeFacts(
        home: fixture.root.path, now: now,
        added: added.reduce(into: [:]) { $0[fixture.path($1.key)] = $1.value },
        repositories: repositories.map { GitState(root: fixture.path($0), isDirty: false, hasRemote: true,
                                                  lastCommit: now.addingTimeInterval(-200 * 86_400)) })
    let engine = RuleEngine(rules: try RuleCatalog.load(), facts: facts)
    return engine.classify(relatives.map { fixture.item($0.0, now: now, daysOld: 200, directory: $0.1) })
}

@Test func installedToolsAreNotDeveloperClutter() throws {
    let findings = try classify([
        (".local/codex-0.144.5/node_modules", true),
        (".local/share/cursor-agent/versions/2026.08.11-e8db854/node_modules", true),
        ("Library/Application Support/Zed/languages/vtsls/node_modules", true),
    ])
    #expect(!findings.contains { $0.ruleID == "dev.project-junk" })
}

@Test func projectClutterStillFoundInAStaleCleanRepo() throws {
    let findings = try classify([("Dev/old-app/node_modules", true)], repositories: ["Dev/old-app"])
    #expect(findings.contains { $0.ruleID == "dev.project-junk" && $0.bucket == .rebuilds })
}

@Test func onlyTopLevelDownloadsCountAsNeverOpened() throws {
    let old = Date(timeIntervalSince1970: 2_000_000_000 - 200 * 86_400)
    let findings = try classify(
        [("Downloads/five-labs/research/data/dev.json", false), ("Downloads/C3863.MP4", false)],
        added: ["Downloads/five-labs/research/data/dev.json": old, "Downloads/C3863.MP4": old])
    let flagged = findings.filter { $0.ruleID == "generic.downloads-never-opened" }.flatMap { $0.items.map(\.path) }
    #expect(flagged.allSatisfy { $0.hasSuffix("Downloads/C3863.MP4") })
    #expect(!flagged.contains { $0.hasSuffix("dev.json") })
}

@Test func secretWarningsSkipLibraryCertificatesAndPhotos() throws {
    let findings = try classify([
        ("Dev/app/venv/lib/python3.11/site-packages/certifi/cacert.pem", false),
        (".local/share/uv/python/lib/cacert.pem", false),
        ("Downloads/secret_pfp.jpg", false),
        ("Desktop/github-recovery-codes.txt", false),
    ])
    let warned = findings.filter { $0.ruleID == "yours.secret-looking-names" }.flatMap { $0.items.map(\.path) }
    #expect(warned.count == 1)
    #expect(warned.first?.hasSuffix("github-recovery-codes.txt") == true)
}

@Test func secretWarningsIgnoreAppSupportCertificates() throws {
    let findings = try classify([("Library/Application Support/Claude/ca-bundle.pem", false)])
    #expect(!findings.contains { $0.ruleID == "yours.secret-looking-names" })
}

@Test func leftoversOfAnOlderVersionSayTheCurrentAppIsSafe() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let facts = CatalogFakeFacts(home: fixture.root.path, now: now, installed: ["net.whatsapp.WhatsApp"],
                                 appNames: ["WhatsApp"])
    let engine = RuleEngine(rules: try RuleCatalog.load(), facts: facts)
    let finding = try #require(engine.classify([fixture.item("Library/Containers/desktop.WhatsApp", now: now, daysOld: 700)])
        .first { $0.ruleID == "generic.orphan-container" })
    #expect(finding.title == "Leftovers from an older WhatsApp")
    #expect(finding.explanation.whatItIs.contains("isn't affected"))
    #expect(finding.bucket == .review && finding.action == .trash)
}

@Test func macOSServiceFoldersNeverBecomeFindings() throws {
    let findings = try classify([("Library/Caches/com.apple.nsurlsessiond", true), ("Library/Caches/com.spotify.client", true)])
    #expect(!findings.contains { $0.items.contains { $0.path.contains("com.apple.") } })
    #expect(findings.contains { $0.items.contains { $0.path.hasSuffix("com.spotify.client") } })
}

@Test func readableNamesFromBundleIDs() {
    #expect(RuleEngine.readableName(bundleID: "com.raycast.macos") == "Raycast")
    #expect(RuleEngine.readableName(bundleID: "de.janbolz.silicio") == "Silicio")
    #expect(RuleEngine.readableName(bundleID: "desktop.WhatsApp") == "WhatsApp")
}

@Test func screenshotsGroupByTheDateInTheirName() throws {
    let findings = try classify([("Desktop/Screenshot 2024-09-19 at 3.20.00 PM.png", false),
                                 ("Downloads/audit/screenshots/01-robots.png", false),
                                 (".codex/assets/Screenshot 2025-01-01 at 1.00.00 PM.png", false)])
    let shots = findings.filter { $0.ruleID == "yours.screenshots-recordings" }
    #expect(shots.map(\.title) == ["Screenshots and recordings from September 2024"])
}

@Test func onlyStrayDuplicatesAreOffered() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(rules: try RuleCatalog.load(), facts: CatalogFakeFacts(home: fixture.root.path, now: now))
    let deliberate = [fixture.item("Documents/audit/old/shot.png", now: now, daysOld: 10, directory: false),
                      fixture.item("Documents/audit/new/shot.png", now: now, daysOld: 5, directory: false)]
    let stray = [fixture.item("Documents/report.pdf", now: now, daysOld: 10, directory: false),
                 fixture.item("Downloads/report (1).pdf", now: now, daysOld: 5, directory: false)]
    #expect(engine.classifyDuplicates([deliberate]).isEmpty)
    #expect(engine.classifyDuplicates([stray]).map { $0.items[0].path }.first?.hasSuffix("report (1).pdf") == true)
}

/// The engine skips the rule regexes for files whose names can't match any file rule.
/// Every file-rule fixture must get past that fast filter, or the rule would silently never fire.
// yours.large-old-files is exempt: files of 500 MB and up are always reported by the walker.
@Test(arguments: catalogFixtureCases.filter { !$0.directory && $0.ruleID != "yours.large-old-files" })
func everyFileRuleFixturePassesTheFastFilter(testCase: RuleFixtureCase) {
    #expect(RuleEngine.fileMightMatch(testCase.relativePath), "\(testCase.ruleID): \(testCase.relativePath)")
}
