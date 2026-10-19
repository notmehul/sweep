import Foundation
import SweepAI
import SweepCore
import SweepRules
import SweepStore
import SweepSystem

/// The real scan: walker → rule engine → on-device summary, saved to the store.
struct EngineScanSource: ScanSource {
    var store: Store?

    func scan() -> AsyncStream<ScanUpdate> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                await run(continuation)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ continuation: AsyncStream<ScanUpdate>.Continuation) async {
        let home = NSHomeDirectory()
        let volume = try? VolumeInfo.home()
        let previous = try? store?.latestScan()
        // Progress is measured against the home folder. The last scan knows its size; on a
        // first scan we start from an estimate and stretch it, so the bar never moves backwards.
        var estimate = previous.map { Int64(Double($0.tree.allocatedSize) * 1.03) }
            ?? Int64(Double(volume?.usedBytes ?? 100_000_000_000) * 0.45)
        var shown = 0.0

        func progress(_ p: ScanProgress) -> ScanProgress {
            if Double(p.scannedBytes) > Double(estimate) * 0.95 { estimate = Int64(Double(p.scannedBytes) / 0.95) }
            var out = p
            out.totalBytes = estimate
            shown = max(shown, min(0.97, out.fraction))
            out.scannedBytes = Int64(shown * Double(estimate))
            return out
        }

        continuation.yield(.progress(progress(ScanProgress(scannedBytes: 0, totalBytes: estimate, filesSeen: 0,
                                                           currentPath: "Getting ready")), tree: nil))

        let facts = MacFacts(homeDirectory: home)
        let rules = (try? RuleCatalog.load()) ?? []
        let engine = RuleEngine(rules: rules, facts: facts)

        var items: [ScannedItem] = []
        var finished: [SizeNode] = []
        var last = ScanProgress(scannedBytes: 0, totalBytes: estimate, filesSeen: 0, currentPath: "~")
        var result: WalkResult?

        let hasAccess = FDAProbe.hasFullDiskAccess(home: home)
        let walk = Walker().scan(roots: [home], totalBytes: estimate,
                                 claimsAsUnit: { engine.claimsAsUnit(path: $0, isDirectory: $1) },
                                 excluding: hasAccess ? [] : FDAProbe.protectedFolders(home: home))
        for await event in walk {
            if Task.isCancelled { return }
            switch event {
            case .progress(let p):
                last = progress(p)
                last.currentPath = Self.tilde(last.currentPath, home: home)
                continuation.yield(.progress(last, tree: nil))
            case .subtree(let node):
                finished.append(node)
                let partial = SizeNode(name: "Home", path: home, allocatedSize: estimate,
                                       children: finished.sorted { $0.allocatedSize > $1.allocatedSize })
                continuation.yield(.progress(last, tree: partial))
            case .item(let item):
                items.append(item)
            case .finished(let r):
                result = r
            }
        }
        guard let result, !Task.isCancelled else { return }

        // Apps, never-opened downloads, screenshots, secrets and duplicates don't come from the
        // walker (it only reports big files and whole folders), so they're gathered separately.
        last.currentPath = "Checking apps and downloads"
        continuation.yield(.progress(last, tree: nil))
        let candidates = await CandidateCollector().collect(home: home, facts: facts, walkerItems: items)
        let allItems = items + candidates.extraItems
        let kept = Set(allItems.filter { (try? store?.isKept($0)) == true }.map(\.path))
        let findings = (engine.classify(allItems.filter { !kept.contains($0.path) })
                        + engine.classifyDuplicates(candidates.duplicateGroups.map { $0.filter { !kept.contains($0.path) } }))
            .filter { $0.bucket != .dontTouch && !Self.belongsToMacOS($0) }
        let tree = Self.colorize(result.root, findings: findings)

        let freeable = findings.filter { $0.bucket != .yours }.reduce(0) { $0 + $1.reclaimableSize }
        func bytes(_ b: Bucket) -> Int64 { findings.filter { $0.bucket == b }.reduce(0) { $0 + $1.reclaimableSize } }
        let top = findings.filter { $0.bucket != .yours }.sorted { $0.reclaimableSize > $1.reclaimableSize }.prefix(3)
        let summary = await ResilientExplainer().summarize(ScanSummaryFacts(
            freeableBytes: freeable,
            perBucketBytes: .init(rebuilds: bytes(.rebuilds), review: bytes(.review), yours: bytes(.yours)),
            topFindings: top.map { .init(title: $0.title, allocatedBytes: $0.reclaimableSize) },
            coverage: result.unreadablePaths.isEmpty ? 1 : 0.9))

        _ = try? store?.saveScan(totalBytes: result.totalAllocated, freeBytes: volume?.freeBytes ?? 0,
                                 coverage: FDAProbe.hasFullDiskAccess() ? 1 : 0, tree: result.root, findings: findings)

        continuation.yield(.progress(ScanProgress(scannedBytes: result.totalAllocated, totalBytes: result.totalAllocated,
                                                  filesSeen: result.filesSeen, currentPath: "Done"), tree: tree))
        continuation.yield(.finished(ScanReport(
            tree: tree, findings: findings,
            coverage: FDAProbe.hasFullDiskAccess() ? 1 : 0,
            isDeveloper: facts.persona.isDeveloper,
            summary: summary,
            usedBytes: volume?.usedBytes ?? result.totalAllocated)))
    }

    /// Paints sunburst nodes with the bucket of the finding that covers them.
    static func colorize(_ node: SizeNode, findings: [Finding]) -> SizeNode {
        let covered = findings.flatMap { f in f.items.map { ($0.path, f.bucket) } }
        func paint(_ n: SizeNode) -> SizeNode {
            var out = n
            out.bucket = covered.first { n.path == $0.0 || n.path.hasPrefix($0.0 + "/") }?.1
            if out.bucket == nil { out.children = n.children.map(paint) }
            return out
        }
        return paint(node)
    }

    /// Caches of macOS's own services (com.apple.*) are left alone: the services are usually
    /// running, and "never touch system stuff" is a promise to the user.
    static func belongsToMacOS(_ finding: Finding) -> Bool {
        finding.items.contains { $0.path.split(separator: "/").contains { $0.hasPrefix("com.apple.") } }
    }

    static func tilde(_ path: String, home: String) -> String {
        path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

/// Runs a confirmed cleanup through the safety gate and records it for undo.
struct EngineCleaner: Cleaner {
    var store: Store?

    func clean(_ findings: [Finding]) async -> CleanOutcome {
        guard let store else {
            return CleanOutcome(freedBytes: 0, trashedBytes: 0, deletedCount: 0, trashedCount: 0,
                                skipped: findings.map { ($0.title, "Sweep couldn't open its history file, so it cleaned nothing.") },
                                canUndo: false)
        }
        let executor = CleanupExecutor(store: store, facts: MacFacts())
        let report = await executor.clean(findings)
        let skippedTitles = Set(report.skipped.map(\.title))
        let trashed = findings.filter { $0.action == .trash && !skippedTitles.contains($0.title) }
        let removed = findings.filter { $0.action != .trash && !skippedTitles.contains($0.title) }
        // Measured free-space change is the truth for deletions; Trash only frees space once emptied.
        let predicted = removed.reduce(0) { $0 + $1.reclaimableSize }
        return CleanOutcome(
            freedBytes: report.freedBytes > 0 ? report.freedBytes : predicted,
            trashedBytes: trashed.reduce(0) { $0 + $1.reclaimableSize },
            deletedCount: report.deletedCount + report.toolCommandCount,
            trashedCount: report.trashedCount,
            skipped: report.skipped.map { ($0.title, $0.reason) },
            canUndo: report.canUndo)
    }

    func undoLast() async -> Bool {
        guard let store else { return false }
        return await CleanupExecutor(store: store, facts: MacFacts()).undoLast()
    }

    func keep(_ finding: Finding) {
        for item in finding.items { try? store?.recordDecision(for: item, kind: .keep) }
    }
}
