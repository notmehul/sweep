import Foundation
import SweepCore
import SweepRules
import Testing

// Rules for clutter on non-developer Macs: designers, video editors, families.

@Test func largeOldFilesOfAnyTypeAreShownButNotInsideLibrariesOrApps() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let big: Int64 = 1_073_741_824
    let paths = [
        "Documents/Lookbook SS25.psd", "Movies/A001_C002.braw", "Documents/Thesis Draft.pdf",
        "Pictures/Photos Library.photoslibrary/originals/A/clip.mov",
        "Movies/Wedding.fcpbundle/Original Media/clip.mov",
        "Library/Application Support/Big/data.bin", ".cache/huge.bin",
    ]
    let files = paths.map { fixture.item($0, now: now, directory: false, size: big) }
    let library = fixture.item("Movies/Wedding.fcpbundle", now: now, size: big)
    let small = fixture.item("Documents/small.psd", now: now, directory: false, size: 10_000_000)
    let yearAgo = now.addingTimeInterval(-400 * 86_400)
    let opened = Dictionary(uniqueKeysWithValues: (files + [library, small]).map { ($0.path, yearAgo) })
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now, opened: opened)
    )

    let shown = Set(engine.classify(files + [library, small])
        .filter { $0.ruleID == "yours.large-old-files" }
        .flatMap { $0.items.map(\.path) })

    #expect(shown == Set(files.prefix(3).map(\.path)))
}

@Test func lightroomSmartPreviewsAndOtherAppleFoldersStayOut() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let smart = fixture.item("Pictures/Lightroom/Lightroom Catalog Smart Previews.lrdata", now: now)
    let notes = fixture.item("Library/Containers/com.apple.Notes/Data/Library/Caches", now: now)
    let mailData = fixture.item("Library/Containers/com.apple.mail/Data/Library/Mail", now: now)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    )

    #expect(engine.classify([smart, notes, mailData]).isEmpty)
}

@Test func creativeCachesWaitForTheirAppAndTheGateKnowsWhichApp() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let cache = fixture.item("Movies/CacheClip", now: now)
    let davinci = "com.blackmagic-design.DaVinciResolve"

    let running = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now, running: [davinci])
    )
    #expect(!running.classify([cache]).contains { $0.ruleID == "apps.davinci-cache" })

    let closed = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now)
    )
    let finding = try #require(closed.classify([cache]).first { $0.ruleID == "apps.davinci-cache" })
    // The path names no app, so the click-time check relies on the recorded owner.
    #expect(SafetyGate.bundleIdentifier(for: finding) == davinci)
}

@Test func chatMediaIsShownNeverRemoved() throws {
    let fixture = try CatalogFixture()
    defer { fixture.remove() }
    let now = Date(timeIntervalSince1970: 2_000_000_000)
    let engine = RuleEngine(
        rules: try RuleCatalog.load(),
        facts: CatalogFakeFacts(home: fixture.root.path, now: now, installed: ["net.whatsapp.WhatsApp"])
    )
    let findings = engine.classify([
        fixture.item("Library/Messages/Attachments", now: now),
        fixture.item("Library/Group Containers/group.net.whatsapp.WhatsApp.shared/Message/Media", now: now),
    ])

    #expect(findings.count == 2)
    #expect(findings.allSatisfy { $0.bucket == .yours && $0.action == .showOnly })
}
