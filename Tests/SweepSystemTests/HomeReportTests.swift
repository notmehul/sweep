import Foundation
import SweepCore
import SweepRules
import SweepSystem
import Testing

/// Read-only report of what Sweep would offer on this Mac. Never deletes anything.
/// Run with `SWEEP_HOME_REPORT=1 swift test --filter HomeReport`.
@Test(.enabled(if: ProcessInfo.processInfo.environment["SWEEP_HOME_REPORT"] == "1"))
func HomeReport() async throws {
    let home = NSHomeDirectory()
    let facts = MacFacts(homeDirectory: home)
    let engine = RuleEngine(rules: try RuleCatalog.load(), facts: facts)
    var items: [ScannedItem] = []
    for await event in Walker().scan(roots: [home], totalBytes: 1,
                                     claimsAsUnit: { engine.claimsAsUnit(path: $0, isDirectory: $1) }) {
        if case .item(let item) = event { items.append(item) }
    }
    let candidates = await CandidateCollector().collect(home: home, facts: facts, walkerItems: items)
    let findings = engine.classify(items + candidates.extraItems) + engine.classifyDuplicates(candidates.duplicateGroups)
    print("REPORT spotlight=\(facts.spotlightWorks) developer=\(facts.persona.isDeveloper) items=\(items.count) extras=\(candidates.extraItems.count) dupGroups=\(candidates.duplicateGroups.count)")
    for bucket in Bucket.allCases {
        let inBucket = findings.filter { $0.bucket == bucket }
        let total = inBucket.reduce(0) { $0 + $1.reclaimableSize }
        print("REPORT == \(bucket) \(inBucket.count) findings \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
        for f in inBucket.sorted(by: { $0.reclaimableSize > $1.reclaimableSize }).prefix(25) {
            let path = f.items.first.map { $0.path.replacingOccurrences(of: home, with: "~") } ?? ""
            print("REPORT   \(ByteCountFormatter.string(fromByteCount: f.reclaimableSize, countStyle: .file)) | \(f.title) | \(f.ruleID) | \(f.action) | \(path)")
        }
    }
}
