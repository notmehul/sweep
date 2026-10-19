import Foundation
import Testing
import SweepCore
@testable import SweepRules

@Test func catalogIsBundled() {
    #expect(RuleCatalog.directory != nil)
}

@Test func everyBundledRuleLoadsWithRequiredExplanation() throws {
    let rules = try RuleCatalog.load()

    #expect(!rules.isEmpty)
    #expect(Set(rules.map(\.id)).count == rules.count)
    for rule in rules {
        #expect(!rule.explain.whatItIs.isEmpty, "Missing whatItIs for \(rule.id)")
        #expect(!rule.explain.ifRemoved.isEmpty, "Missing ifRemoved for \(rule.id)")
        #expect(!rule.explain.whyStale.isEmpty, "Missing whyStale for \(rule.id)")
    }
}

@Test func loaderRejectsDuplicateIDsAndMissingRequiredText() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let rule = try #require(RuleCatalog.load().first)
    let duplicateData = try JSONEncoder().encode([rule, rule])
    try duplicateData.write(to: fixture.root.appendingPathComponent("duplicate.json"))

    #expect(throws: RuleCatalogError.duplicateID(rule.id)) {
        try RuleCatalog.load(from: fixture.root)
    }

    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("duplicate.json"))
    var incomplete = rule
    incomplete.title = ""
    try JSONEncoder().encode([incomplete]).write(
        to: fixture.root.appendingPathComponent("incomplete.json")
    )
    #expect(throws: RuleCatalogError.missingRequiredField(rule.id)) {
        try RuleCatalog.load(from: fixture.root)
    }

    try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("incomplete.json"))
    var rawRules = try #require(
        JSONSerialization.jsonObject(with: JSONEncoder().encode([rule])) as? [[String: Any]]
    )
    var conditions = try #require(rawRules[0]["conditions"] as? [String: Any])
    conditions["appNotRunnning"] = "owner"
    rawRules[0]["conditions"] = conditions
    try JSONSerialization.data(withJSONObject: rawRules).write(
        to: fixture.root.appendingPathComponent("typo.json")
    )
    do {
        _ = try RuleCatalog.load(from: fixture.root)
        Issue.record("A misspelled safety condition was accepted")
    } catch let error as RuleCatalogError {
        guard case .invalidFile(_, let reason) = error else {
            Issue.record("Unexpected catalog error: \(error)")
            return
        }
        #expect(reason.contains("unknown field 'appNotRunnning'"))
    }
}

@Test(arguments: catalogFixtureCases)
func everyCatalogRuleHasAMatchingFixture(testCase: RuleFixtureCase) throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let rules = try RuleCatalog.load()
    var items = [
        fixture.item(
            testCase.relativePath,
            now: now,
            directory: testCase.directory,
            size: testCase.size
        ),
    ]
    items += testCase.companions.map {
        fixture.item($0, now: now, directory: false)
    }
    let requiresOldOpened = [
        "yours.large-old-files", "generic.unused-apps",
    ].contains(testCase.ruleID)
    let opened = requiresOldOpened
        ? [fixture.path(testCase.relativePath): now.addingTimeInterval(-400 * 86_400)]
        : [:]
    let added = testCase.ruleID == "generic.downloads-never-opened"
        ? [fixture.path(testCase.relativePath): now.addingTimeInterval(-90 * 86_400)]
        : [:]
    let appNames = testCase.ruleID == "generic.installers" ? ["Cursor"] : []
    let engine = RuleEngine(
        rules: rules,
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            opened: opened,
            added: added,
            appNames: appNames,
            repositories: testCase.ruleID == "dev.project-junk"
                ? [GitState(root: fixture.path((testCase.relativePath as NSString).deletingLastPathComponent),
                            isDirty: false, hasRemote: true, lastCommit: nil)]
                : []
        )
    )

    let finding = try #require(engine.classify(items).first {
        $0.ruleID == testCase.ruleID
    })
    #expect(finding.bucket == testCase.bucket)
}

@Test func rebuildRulesAllHaveNamedFixtureCoverage() throws {
    let rules = try RuleCatalog.load()
    let registry = Set(catalogFixtureCases.map(\.ruleID)).union(["dev.old-cli-versions"])
    let rebuilds = Set(rules.filter { $0.bucket == .rebuilds }.map(\.id))

    #expect(rebuilds.isSubset(of: registry))
}

@Test func oldVersionsKeepTheActiveAndNewestSpare() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let base = fixture.root.appendingPathComponent(".local/share/mise")
    let versions = base.appendingPathComponent("versions")
    for version in ["1.0", "2.0", "3.0"] {
        try FileManager.default.createDirectory(
            at: versions.appendingPathComponent(version),
            withIntermediateDirectories: true
        )
    }
    try FileManager.default.createSymbolicLink(
        atPath: base.appendingPathComponent("active").path,
        withDestinationPath: "versions/current"
    )
    try FileManager.default.createSymbolicLink(
        atPath: versions.appendingPathComponent("current").path,
        withDestinationPath: "3.0/bin/tool"
    )
    let items = [
        fixture.item(".local/share/mise/versions/1.0", now: now, daysOld: 300),
        fixture.item(".local/share/mise/versions/2.0", now: now, daysOld: 100),
        fixture.item(".local/share/mise/versions/3.0", now: now, daysOld: 10),
    ]
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    )

    let oldVersions = engine.classify(items).filter { $0.ruleID == "dev.old-cli-versions" }
    #expect(oldVersions.count == 1)
    #expect(oldVersions.first?.items.first?.path.hasSuffix("/1.0") == true)
    #expect(oldVersions.first?.evidence == [.notSymlinkTarget(active: "3.0")])
}

@Test func knownCasesHaveExpectedActions() throws {
    let rules = try RuleCatalog.load()
    let byID = Dictionary(uniqueKeysWithValues: rules.map { ($0.id, $0) })

    #expect(byID["dev.npm-cache"]?.action == .toolCommand(.npmCacheClean))
    #expect(byID["dev.bun-cache"]?.action == .toolCommand(.bunCacheRm))
    #expect(byID["dev.uv-cache"]?.action == .toolCommand(.uvCacheClean))
    #expect(byID["dev.homebrew-cache"]?.action == .toolCommand(.brewCleanup))
    #expect(byID["dev.simulator-runtimes"]?.action == .toolCommand(.simctlRuntimeDelete))
    #expect(byID["apps.cursor-snapshots"]?.bucket == .review)
    #expect(byID["yours.secret-looking-names"]?.action == .showOnly)
    for id in [
        "generic.orphan-application-support", "generic.orphan-container",
        "generic.orphan-group-container", "generic.orphan-saved-state",
        "generic.orphan-preference",
    ] {
        #expect(byID[id]?.bucket == .review)
        #expect(byID[id]?.action == .trash)
    }
}

@Test func ruleFamilyNearMissesStayOut() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let rules = try RuleCatalog.load()

    let partitions = fixture.item(
        "Library/Application Support/Google/Chrome/Partitions/work/Cache",
        now: now
    )
    let youngSource = fixture.item(
        "Projects/recent/Sources/App.swift",
        now: now,
        daysOld: 3,
        directory: false
    )
    let youngModules = fixture.item(
        "Projects/recent/node_modules",
        now: now,
        daysOld: 100
    )
    let expandedMissing = fixture.item(
        "Downloads/missing-expanded.bin.zst",
        now: now,
        directory: false
    )
    let compressedBesideDirectory = fixture.item(
        "Downloads/folder.zst",
        now: now,
        directory: false
    )
    let sameNamedDirectory = fixture.item("Downloads/folder", now: now)
    let projectMarker = fixture.item(
        "Projects/recent/package.json",
        now: now,
        daysOld: 3,
        directory: false
    )
    let unrelatedBuild = fixture.item("Documents/build", now: now, daysOld: 400)
    let oldNamedBuildFile = fixture.item(
        "Projects/file-name/build",
        now: now,
        daysOld: 400,
        directory: false
    )
    let oldProjectMarker = fixture.item(
        "Projects/file-name/package.json",
        now: now,
        daysOld: 400,
        directory: false
    )
    let engine = RuleEngine(
        rules: rules,
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    )
    let findings = engine.classify([
        partitions, youngSource, youngModules, projectMarker, unrelatedBuild,
        oldNamedBuildFile, oldProjectMarker, expandedMissing,
        compressedBesideDirectory, sameNamedDirectory,
    ])

    #expect(findings.first { $0.items.contains(partitions) }?.bucket == .dontTouch)
    #expect(!findings.contains { $0.ruleID == "dev.project-junk" })
    #expect(!findings.contains { $0.ruleID == "generic.compressed-copy" })
}

@Test func dirtyProjectBlocksDeveloperJunk() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let root = fixture.path("Projects/dirty")
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            repositories: [
                GitState(root: root, isDirty: true, hasRemote: true, lastCommit: now),
            ]
        )
    )

    let finding = try #require(engine.classify([
        fixture.item("Projects/dirty/node_modules", now: now, daysOld: 100),
    ]).first)
    #expect(finding.ruleID == "guard.dirty-repository")
    #expect(finding.bucket == .dontTouch)
}

@Test func orphanRulesRequireTheBundleToBeAbsent() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            installed: [
                "com.example.Installed",
                "com.tinyspeck.slackmacgap",
                "com.apple.archiveutility",
            ]
        )
    )
    let findings = engine.classify([
        fixture.item("Library/Containers/com.example.Installed", now: now),
        fixture.item(
            "Library/Group Containers/group.com.tinyspeck.slackmacgap",
            now: now
        ),
        fixture.item(
            "Library/Preferences/com.apple.archiveutility.plist",
            now: now,
            directory: false
        ),
    ])

    #expect(!findings.contains { $0.ruleID.hasPrefix("generic.orphan-") })
    #expect(!engine.claimsAsUnit(
        path: fixture.path("Library/Containers/com.example.Installed"),
        isDirectory: true
    ))
    #expect(engine.claimsAsUnit(
        path: fixture.path("Library/Containers/com.example.Installed/Data/Library/Caches"),
        isDirectory: true
    ))
}

@Test func appleBundleIdentifiersAreNeverOrphans() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    )
    let items = [
        fixture.item("Library/Containers/com.apple.UnknownHelper", now: now),
        fixture.item(
            "Library/Preferences/com.apple.UnknownHelper.plist",
            now: now,
            directory: false
        ),
    ]

    #expect(!engine.classify(items).contains { $0.ruleID.hasPrefix("generic.orphan-") })
    #expect(!engine.claimsAsUnit(path: items[0].path, isDirectory: true))
}

@Test func orphanPreferencesAreReviewAndTrash() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let finding = try #require(RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    ).classify([
        fixture.item(
            "Library/Preferences/com.example.Removed.plist",
            now: now,
            directory: false
        ),
    ]).first)

    #expect(finding.ruleID == "generic.orphan-preference")
    #expect(finding.bucket == .review)
    #expect(finding.action == .trash)
}

@Test func secretLookingNamesAreSpecific() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    )
    let matching = [
        "Documents/recovery-codes.txt", "Documents/id_rsa", "Documents/id_ed25519",
        "Documents/certificate.pem", "Documents/signing.p12", "Documents/.env",
        "Documents/my-apikey.txt", "Documents/my-api-key.txt",
        "Documents/my-api_keys.txt", "Documents/client-secret.txt",
    ].map { fixture.item($0, now: now, directory: false) }
    let nearMisses = [
        "Documents/monkey.jpg", "Documents/keyboard.png", "Documents/keynote",
    ].map { fixture.item($0, now: now, directory: false) }
    let findings = engine.classify(matching + nearMisses)

    #expect(findings.filter { $0.ruleID == "yours.secret-looking-names" }.count == matching.count)
    for nearMiss in nearMisses {
        #expect(!findings.contains {
            $0.ruleID == "yours.secret-looking-names" && $0.items.contains(nearMiss)
        })
    }
}

@Test func newReviewRulesRequireTheirSafetyEvidence() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let old = now.addingTimeInterval(-200 * 86_400)
    let unusedPath = fixture.path("Applications/Old Tool.app")
    let applePath = fixture.path("Applications/Apple Tool.app")
    let runningPath = fixture.path("Applications/Running Tool.app")
    let installerPath = fixture.path("Downloads/Cursor-darwin-arm64.dmg")
    let downloadPath = fixture.path("Downloads/forgotten.txt")
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            running: ["com.example.running"],
            added: [unusedPath: old, applePath: old, runningPath: old, downloadPath: old],
            appNames: ["Cursor"],
            applicationBundleIDs: [
                unusedPath: "com.example.old",
                applePath: "com.apple.Tool",
                runningPath: "com.example.running",
            ]
        )
    )
    let findings = engine.classify([
        fixture.item("Applications/Old Tool.app", now: now, daysOld: 200),
        fixture.item("Applications/Apple Tool.app", now: now, daysOld: 200),
        fixture.item("Applications/Running Tool.app", now: now, daysOld: 200),
        fixture.item("Downloads/Cursor-darwin-arm64.dmg", now: now, directory: false),
        fixture.item("Downloads/forgotten.txt", now: now, daysOld: 200, directory: false),
    ])

    let unused = try #require(findings.first { $0.ruleID == "generic.unused-apps" })
    #expect(unused.items.first?.path == unusedPath)
    #expect(unused.evidence.contains(.neverOpened))
    #expect(!findings.contains {
        $0.ruleID == "generic.unused-apps"
            && ($0.items.first?.path == applePath || $0.items.first?.path == runningPath)
    })
    #expect(findings.first { $0.ruleID == "generic.installers" }?
        .evidence == [.installerForInstalledApp("Cursor")])
    #expect(findings.first { $0.ruleID == "generic.downloads-never-opened" }?
        .evidence.contains(.neverOpened) == true)
    #expect(installerPath.hasSuffix(".dmg"))
}

@Test func runningAppsAndLiveDatabasesAreNotCleanupCandidates() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            running: ["com.tinyspeck.slackmacgap"]
        )
    )
    let slackCache = fixture.item("Library/Application Support/Slack/Code Cache", now: now)
    let liveDatabase = fixture.item(
        "Library/Application Support/Slack/conversation.db",
        now: now,
        directory: false
    )
    let findings = engine.classify([slackCache, liveDatabase])

    #expect(!findings.contains { $0.items.contains(slackCache) && $0.bucket != .dontTouch })
    #expect(findings.first { $0.items.contains(liveDatabase) }?.ruleID == "guard.live-database")

    let unknownOwnerEngine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            running: ["com.acme.desktop"]
        )
    )
    let unresolvedCache = fixture.item(
        "Library/Caches/Acme",
        now: now
    )
    #expect(unknownOwnerEngine.classify([unresolvedCache]).isEmpty)
}

@Test func spotlightFailureLeavesRequiredFindingUnticked() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    var spotlightRule = try #require(
        RuleCatalog.load().first { $0.id == "yours.large-old-files" }
    )
    spotlightRule.bucket = .rebuilds
    spotlightRule.action = .delete
    let engine = RuleEngine(
        rules: [spotlightRule],
        facts: CatalogFakeFacts(
            home: fixture.root.path,
            now: now,
            spotlightWorks: false
        )
    )
    let finding = try #require(engine.classify([
        fixture.item(
            "Movies/old.mov",
            now: now,
            daysOld: 400,
            directory: false,
            size: 1_073_741_824
        ),
    ]).first)

    #expect(!engine.presentation(for: finding).isPreselected)
}

private let developerJunkNames = [
    "node_modules", ".venv", "venv", ".next", "__pycache__", ".turbo",
    ".pytest_cache", ".expo", "Pods", ".parcel-cache", ".svelte-kit",
    "build", "dist", "dist-client",
]

@Test(arguments: developerJunkNames)
func everyDeveloperJunkNameRequiresAnOldProject(name: String) throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now, repositories: [
            GitState(root: fixture.path("Projects/old"), isDirty: false, hasRemote: true, lastCommit: nil),
        ])
    )

    let finding = try #require(engine.classify([
        fixture.item("Projects/old/\(name)", now: now, daysOld: 100),
        fixture.item(
            "Projects/old/Sources/App.swift",
            now: now,
            daysOld: 40,
            directory: false
        ),
        fixture.item(
            "Projects/old/package.json",
            now: now,
            daysOld: 40,
            directory: false
        ),
    ]).first { $0.ruleID == "dev.project-junk" })
    #expect(finding.bucket == .rebuilds)
    #expect(finding.evidence == [.staleDays(40)])
}
