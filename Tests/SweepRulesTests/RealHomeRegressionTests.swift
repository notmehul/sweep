import Foundation
import SweepCore
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
