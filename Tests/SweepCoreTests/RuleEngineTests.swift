import Foundation
import Testing
@testable import SweepCore

@Test func doubleStarGlobClaimsNestedDirectoriesAsUnits() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let engine = RuleEngine(
        rules: [testRule(match: RuleMatch(pathGlob: "Projects/**/node_modules"))],
        facts: FakeFacts(home: fixture.root.path)
    )

    #expect(engine.claimsAsUnit(
        path: fixture.path("Projects/client/web/node_modules"),
        isDirectory: true
    ))
    #expect(!engine.claimsAsUnit(
        path: fixture.path("Projects/client/web/node_modules/file.js"),
        isDirectory: false
    ))
}

@Test func higherPriorityKnownRuleWinsGenericConvention() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let date = Date(timeIntervalSince1970: 1_000)
    let generic = testRule(
        id: "generic.cache",
        match: RuleMatch(pathGlob: "Library/Caches/*"),
        priority: 100
    )
    let known = testRule(
        id: "apps.known-cache",
        match: RuleMatch(pathGlob: "Library/Caches/Known"),
        bucket: .review,
        priority: 200
    )
    let engine = RuleEngine(
        rules: [generic, known],
        facts: FakeFacts(home: fixture.root.path)
    )

    let finding = try #require(engine.classify([
        fixture.item("Library/Caches/Known", modified: date),
    ]).first)
    #expect(finding.ruleID == "apps.known-cache")
    #expect(finding.bucket == .review)
}

@Test func safetyGuardsOverrideRules() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let catchAll = testRule(match: RuleMatch(pathGlob: "**"))
    let repo = fixture.path("Projects/dirty")
    let facts = FakeFacts(
        home: fixture.root.path,
        now: now,
        running: ["com.google.Chrome"],
        repositories: [
            GitState(root: repo, isDirty: true, hasRemote: true, lastCommit: now),
        ]
    )
    let engine = RuleEngine(rules: [catchAll], facts: facts)
    let items = [
        fixture.item("Projects/dirty/node_modules", modified: now),
        fixture.item("Library/Application Support/Google/Chrome/Partitions/x", modified: now),
        fixture.item("Library/Application Support/Cursor/User/globalStorage/state.vscdb", directory: false, modified: now),
        fixture.item("Library/Application Support/Google/Chrome/Default/Cache", modified: now),
        ScannedItem(
            path: "/private/var/folders/example/code_sign_clone",
            isDirectory: true,
            logicalSize: 1,
            allocatedSize: 1,
            reclaimableSize: 0,
            fileCount: 1,
            fileID: 1,
            device: 1,
            modified: now,
            flags: [.sharesAllBlocks]
        ),
    ]

    let findings = engine.classify(items)
    #expect(findings.map(\.bucket).allSatisfy { $0 == .dontTouch })
    #expect(Set(findings.map(\.ruleID)) == [
        "guard.dirty-repository",
        "guard.chromium-partitions",
        "guard.live-database",
        "guard.active-browser-profile",
        "guard.outside-home",
    ])
}

@Test func noRemoteRepositoryIsProtectedEvenWhenClean() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let root = fixture.path("Projects/local-only")
    let facts = FakeFacts(
        home: fixture.root.path,
        repositories: [
            GitState(root: root, isDirty: false, hasRemote: false, lastCommit: nil),
        ]
    )
    let engine = RuleEngine(
        rules: [testRule(match: RuleMatch(pathGlob: "Projects/**"))],
        facts: facts
    )

    let finding = try #require(engine.classify([
        fixture.item("Projects/local-only/build", modified: facts.now),
    ]).first)
    #expect(finding.ruleID == "guard.repository-without-remote")
    #expect(finding.evidence == [.noRemote])
}

@Test func spotlightRequirementStaysVisibleButIsNotPreselected() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let rule = testRule(
        match: RuleMatch(pathGlob: "Library/Caches/Test"),
        conditions: RuleConditions(requiresSpotlight: true)
    )
    let engine = RuleEngine(
        rules: [rule],
        facts: FakeFacts(home: fixture.root.path, spotlightWorks: false)
    )
    let finding = try #require(engine.classify([
        fixture.item("Library/Caches/Test", modified: .distantPast),
    ]).first)

    #expect(finding.bucket == .rebuilds)
    #expect(!engine.presentation(for: finding).isPreselected)
}

@Test func lastUsedPrefersSpotlightAndFallsBackToMtime() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let modified = Date(timeIntervalSince1970: 1_000)
    let opened = Date(timeIntervalSince1970: 2_000)
    let path = fixture.path("Downloads/archive.zip")
    let rule = testRule(match: RuleMatch(pathGlob: "Downloads/*.zip"))

    let spotlightEngine = RuleEngine(
        rules: [rule],
        facts: FakeFacts(home: fixture.root.path, opened: [path: opened])
    )
    let spotlightFinding = try #require(spotlightEngine.classify([
        fixture.item("Downloads/archive.zip", directory: false, modified: modified),
    ]).first)
    #expect(spotlightFinding.lastUsed == LastUsed(date: opened, source: .spotlight))

    let fallbackEngine = RuleEngine(
        rules: [rule],
        facts: FakeFacts(home: fixture.root.path)
    )
    let fallbackFinding = try #require(fallbackEngine.classify([
        fixture.item("Downloads/archive.zip", directory: false, modified: modified),
    ]).first)
    #expect(fallbackFinding.lastUsed == LastUsed(date: modified, source: .mtime))
}

@Test func templatesUseComputedValuesWithoutChangingSafetyFields() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let old = now.addingTimeInterval(-40 * 86_400)
    let rule = testRule(
        match: RuleMatch(pathGlob: "Library/Caches/Spotify"),
        conditions: RuleConditions(minAgeDays: 30)
    )
    let engine = RuleEngine(
        rules: [rule],
        facts: FakeFacts(home: fixture.root.path, now: now)
    )

    let finding = try #require(engine.classify([
        fixture.item("Library/Caches/Spotify", modified: old, size: 1_048_576),
    ]).first)
    #expect(finding.title.contains("Spotify"))
    #expect(finding.explanation.whyStale.contains("40 days"))
    #expect(finding.evidence == [.staleDays(40)])
    #expect(finding.action == .delete)
}

@Test func parentMarkerAndBundlePatternRefineMatches() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let markerRule = testRule(
        id: "test.marker",
        match: RuleMatch(pathGlob: "Projects/**/build", parentMarker: "package.json")
    )
    let bundleRule = testRule(
        id: "test.bundle",
        match: RuleMatch(
            pathGlob: "Library/Containers/*",
            bundleIDPattern: "com.example.*"
        ),
        conditions: RuleConditions(appNotInstalled: "owner")
    )
    let engine = RuleEngine(
        rules: [markerRule, bundleRule],
        facts: FakeFacts(home: fixture.root.path, now: now)
    )
    let findings = engine.classify([
        fixture.item("Projects/app/build", modified: now),
        fixture.item("Projects/app/package.json", directory: false, modified: now),
        fixture.item("Projects/unmarked/build", modified: now),
        fixture.item("Library/Containers/com.example.Removed", modified: now),
        fixture.item("Library/Containers/org.other.App", modified: now),
    ])

    #expect(findings.filter { $0.ruleID == "test.marker" }.count == 1)
    let bundleFinding = try #require(findings.first { $0.ruleID == "test.bundle" })
    #expect(bundleFinding.evidence == [.bundleNotInstalled("com.example.Removed")])
}

@Test func gitignoredMatcherAddsEvidence() throws {
    let fixture = try TemporaryFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let repo = fixture.root.appendingPathComponent("Projects/repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try Data("node_modules/\n".utf8).write(to: repo.appendingPathComponent(".gitignore"))
    try FileManager.default.createDirectory(
        at: repo.appendingPathComponent("node_modules"),
        withIntermediateDirectories: true
    )
    try runGit(["init", "-q"], in: repo)
    let rule = testRule(
        match: RuleMatch(pathGlob: "Projects/repo/node_modules", gitignored: true)
    )
    let engine = RuleEngine(
        rules: [rule],
        facts: FakeFacts(
            home: fixture.root.path,
            now: now,
            repositories: [
                GitState(root: repo.path, isDirty: false, hasRemote: true, lastCommit: nil),
            ]
        )
    )

    let finding = try #require(engine.classify([
        fixture.item("Projects/repo/node_modules", modified: now),
    ]).first)
    #expect(finding.evidence == [.coveredByIgnore])
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitTestError.failed(process.terminationStatus)
    }
}

private enum GitTestError: Error {
    case failed(Int32)
}
