import Foundation
import Observation
import SweepCore

/// What a finished scan hands the UI.
struct ScanReport: Sendable {
    var tree: SizeNode
    var findings: [Finding]
    /// Share of the disk Sweep could read; below 1 without Full Disk Access.
    var coverage: Double
    var isDeveloper: Bool
    var summary: String
    /// Used space on the disk, for the before/after bar.
    var usedBytes: Int64
}

enum ScanUpdate: Sendable {
    case progress(ScanProgress, tree: SizeNode?)
    case finished(ScanReport)
}

/// Produces a scan. The real one wires walker + rules + facts; the demo one replays sample data.
protocol ScanSource: Sendable {
    func scan() -> AsyncStream<ScanUpdate>
}

struct CleanOutcome: Sendable {
    /// Space actually freed by deletions (Trash frees nothing until it's emptied).
    var freedBytes: Int64
    var trashedBytes: Int64
    var deletedCount: Int
    var trashedCount: Int
    var skipped: [(title: String, reason: String)]
    var canUndo: Bool
}

/// Carries out a confirmed cleanup.
protocol Cleaner: Sendable {
    func clean(_ findings: [Finding]) async -> CleanOutcome
    func undoLast() async -> Bool
    /// Remembers "keep this, don't ask again".
    func keep(_ finding: Finding)
}

extension Cleaner {
    func keep(_ finding: Finding) {}
}

@MainActor @Observable
final class AppModel {
    enum Screen: Equatable {
        case welcome, scanning, results, bucket(Bucket), cleaning, done
    }

    var screen: Screen = .welcome
    var hasFullDiskAccess = false
    var progress: ScanProgress?
    var liveTree: SizeNode?
    var report: ScanReport?
    var selection: Set<Finding.ID> = []
    var kept: Set<Finding.ID> = []
    var outcome: CleanOutcome?
    var confirming = false

    private let source: ScanSource
    private let cleaner: Cleaner
    private let accessProbe: @Sendable () -> Bool
    private var scanTask: Task<Void, Never>?

    init(source: ScanSource, cleaner: Cleaner, accessProbe: @escaping @Sendable () -> Bool) {
        self.source = source
        self.cleaner = cleaner
        self.accessProbe = accessProbe
        self.hasFullDiskAccess = accessProbe()
    }

    func refreshAccess() { hasFullDiskAccess = accessProbe() }

    func startScan() {
        scanTask?.cancel()
        progress = nil; liveTree = nil; report = nil; outcome = nil
        screen = .scanning
        scanTask = Task {
            for await update in source.scan() {
                switch update {
                case .progress(let p, let tree):
                    progress = p
                    if let tree { liveTree = tree }
                case .finished(let r):
                    report = r
                    selection = Set(r.findings.filter { $0.bucket == .rebuilds }.map(\.id))
                    screen = .results
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        screen = .welcome
    }

    func visibleFindings(in bucket: Bucket) -> [Finding] {
        guard let report else { return [] }
        return report.findings.filter {
            $0.bucket == bucket && !kept.contains($0.id) && (report.isDeveloper || !$0.isDeveloper)
        }
    }

    func total(of bucket: Bucket) -> Int64 {
        visibleFindings(in: bucket).reduce(0) { $0 + $1.reclaimableSize }
    }

    /// Headline number: what the two actionable buckets could free.
    var freeable: Int64 { total(of: .rebuilds) + total(of: .review) }

    var selectedFindings: [Finding] {
        guard let report else { return [] }
        return report.findings.filter { selection.contains($0.id) && !kept.contains($0.id) && $0.bucket != .yours }
    }

    var selectedBytes: Int64 { selectedFindings.reduce(0) { $0 + $1.reclaimableSize } }

    func toggle(_ finding: Finding) {
        if selection.contains(finding.id) { selection.remove(finding.id) } else { selection.insert(finding.id) }
    }

    func keep(_ finding: Finding) {
        cleaner.keep(finding)
        kept.insert(finding.id)
        selection.remove(finding.id)
    }

    func clean() {
        let chosen = selectedFindings
        confirming = false
        screen = .cleaning
        Task {
            outcome = await cleaner.clean(chosen)
            selection.subtract(chosen.map(\.id))
            screen = .done
        }
    }

    func undo() {
        Task {
            if await cleaner.undoLast() { outcome?.canUndo = false }
        }
    }
}
