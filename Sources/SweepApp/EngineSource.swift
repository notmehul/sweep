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
        var finished: [String: SizeNode] = [:]
        var partial: [String: [SizeNode]] = [:]
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
                let parent = (node.path as NSString).deletingLastPathComponent
                if parent == home { finished[node.path] = node } else { partial[parent, default: []].append(node) }
                continuation.yield(.progress(last, tree: Self.liveTree(home: home, estimate: estimate,
                                                                       finished: finished, partial: partial)))
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
            .filter { $0.bucket != .dontTouch }
        let tree = Self.colorize(result.root, findings: findings)

        let freeable = findings.filter { $0.bucket != .yours }.reduce(0) { $0 + $1.reclaimableSize }
        func bytes(_ b: Bucket) -> Int64 { findings.filter { $0.bucket == b }.reduce(0) { $0 + $1.reclaimableSize } }
        let top = findings.filter { $0.bucket != .yours }.sorted { $0.reclaimableSize > $1.reclaimableSize }.prefix(3)
        let summary = await ResilientExplainer().summarize(ScanSummaryFacts(
            freeableBytes: freeable,
            perBucketBytes: .init(rebuilds: bytes(.rebuilds), review: bytes(.review), yours: bytes(.yours)),
            topFindings: top.map { .init(title: $0.title, allocatedBytes: $0.reclaimableSize) },
            coverage: result.unreadablePaths.isEmpty ? 1 : 0.9))

        let coverage: Double = FDAProbe.hasFullDiskAccess() ? 1 : 0
        let saved = try? store?.saveScan(totalBytes: result.totalAllocated, freeBytes: volume?.freeBytes ?? 0,
                                         coverage: coverage, tree: result.root, findings: findings)
        let changes = await Self.changeSentence(latest: saved, previous: previous, store: store)

        continuation.yield(.progress(ScanProgress(scannedBytes: result.totalAllocated, totalBytes: result.totalAllocated,
                                                  filesSeen: result.filesSeen, currentPath: "Done"), tree: tree))
        continuation.yield(.finished(ScanReport(
            tree: tree, findings: findings,
            coverage: FDAProbe.hasFullDiskAccess() ? 1 : 0,
            isDeveloper: facts.persona.isDeveloper,
            summary: summary,
            usedBytes: volume?.usedBytes ?? result.totalAllocated,
            changes: changes)))
    }

    /// "Since 12 Oct, Downloads grew 2.1 GB." Only between scans that could see the same
    /// folders: a scan with Full Disk Access sees far more than one without, and comparing
    /// them would invent growth.
    static func changeSentence(latest: StoredScan?, previous: StoredScan?, store: Store?) async -> String? {
        guard let latest, let previous, let store, latest.coverage == previous.coverage else { return nil }
        let period = "since " + previous.date.formatted(.dateTime.day().month(.abbreviated))
        let facts = store.diff(latest: latest, previous: previous).compactMap { change -> ChangeFact? in
            guard case .topLevelFolder(_, let name) = change.scope, abs(change.byteDelta) >= 500_000_000 else { return nil }
            return ChangeFact(name: name, deltaBytes: change.byteDelta, period: period)
        }
        .sorted { abs($0.deltaBytes) > abs($1.deltaBytes) }
        return await ResilientExplainer().narrate(Array(facts.prefix(3)))
    }

    /// The sunburst while scanning: finished top-level folders as they are, plus folders still
    /// being read, sized by the parts of them already finished. Nothing shrinks as it grows.
    static func liveTree(home: String, estimate: Int64, finished: [String: SizeNode],
                         partial: [String: [SizeNode]]) -> SizeNode {
        var children = Array(finished.values)
        for (path, parts) in partial where finished[path] == nil {
            children.append(SizeNode(name: (path as NSString).lastPathComponent, path: path,
                                     allocatedSize: parts.reduce(0) { $0 + $1.allocatedSize },
                                     children: parts.sorted { $0.allocatedSize > $1.allocatedSize }))
        }
        return SizeNode(name: "Home", path: home, allocatedSize: estimate,
                        children: children.sorted { $0.path < $1.path })
    }

    /// Paints a sunburst node with a bucket when that bucket covers at least 40% of it, so a
    /// cache five folders deep still colours the rings you can see.
    static func colorize(_ node: SizeNode, findings: [Finding]) -> SizeNode {
        let covered = findings.flatMap { f in f.items.map { (path: $0.path, bucket: f.bucket, bytes: $0.allocatedSize) } }
        func paint(_ n: SizeNode) -> SizeNode {
            var out = n
            var byBucket: [Bucket: Int64] = [:]
            for c in covered where c.path == n.path || c.path.hasPrefix(n.path + "/") || n.path.hasPrefix(c.path + "/") {
                byBucket[c.bucket, default: 0] += n.path.hasPrefix(c.path + "/") ? n.allocatedSize : c.bytes
            }
            if let (bucket, bytes) = byBucket.max(by: { $0.value < $1.value }),
               n.allocatedSize > 0, Double(bytes) / Double(n.allocatedSize) >= 0.4 {
                out.bucket = bucket
            }
            out.children = n.children.map(paint)
            return out
        }
        return paint(node)
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
        let executor = CleanupExecutor(store: store, facts: MacFacts(measureApplicationSizes: false))
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
        return await CleanupExecutor(store: store, facts: MacFacts(measureApplicationSizes: false)).undoLast()
    }

    func keep(_ finding: Finding) {
        for item in finding.items { try? store?.recordDecision(for: item, kind: .keep) }
    }
}
