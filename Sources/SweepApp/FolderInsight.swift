import Foundation
import SweepAI
import SweepCore

/// An explanation of a folder the rules may not know, and who wrote it.
struct FolderInsight: Sendable {
    var explanation: FolderExplanation
    /// true when Apple's on-device model wrote it; false for Sweep's built-in wording.
    var byAppleIntelligence: Bool
}

extension AppModel {
    /// Opens the card for a sunburst segment and asks the on-device model about it once.
    func inspect(_ segment: SunburstSegment) {
        inspectedFolder = segment
        guard insights[segment.id] == nil, let tree = report?.tree ?? liveTree else { return }
        let facts = Self.folderFacts(for: segment, in: tree)
        Task {
            let insight: FolderInsight
            if let ai = await OnDeviceExplainer().explainFolder(facts) {
                insight = FolderInsight(explanation: ai, byAppleIntelligence: true)
            } else if let plain = await TemplateExplainer().explainFolder(facts) {
                insight = FolderInsight(explanation: plain, byAppleIntelligence: false)
            } else {
                return
            }
            insights[segment.id] = insight
        }
    }

    /// Facts only: names, sizes, counts and dates. File contents never leave the disk, and
    /// these facts never leave the Mac (the model runs on it).
    nonisolated static func folderFacts(for segment: SunburstSegment, in tree: SizeNode) -> FolderFacts {
        let node = find(segment.id, in: tree)
        let home = NSHomeDirectory()
        let path = segment.id.hasPrefix(home) ? "~" + segment.id.dropFirst(home.count) : segment.id
        let children = (node?.children ?? []).filter { $0.name != "Other" }.prefix(10)
            .map { FolderFacts.Child(name: $0.name, allocatedBytes: $0.allocatedSize) }
        let listing = (try? FileManager.default.contentsOfDirectory(atPath: segment.id)) ?? []
        var histogram: [String: Int] = [:]
        for name in listing.prefix(500) {
            let ext = (name as NSString).pathExtension.lowercased()
            histogram[ext.isEmpty ? "folder or no extension" : ext, default: 0] += 1
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: segment.id))?[.modificationDate] as? Date
        let owner = segment.id.split(separator: "/").map(String.init).last { part in
            part.contains(".") && !part.contains(" ") && part.split(separator: ".").count >= 3
        }
        return FolderFacts(path: String(path), allocatedBytes: segment.size, itemCount: listing.count,
                           topChildren: Array(children), owningBundleID: owner,
                           newestModificationDate: modified, fileTypeHistogram: histogram)
    }

    nonisolated private static func find(_ path: String, in node: SizeNode) -> SizeNode? {
        if node.path == path { return node }
        for child in node.children where path == child.path || path.hasPrefix(child.path + "/") {
            if let hit = find(path, in: child) { return hit }
        }
        return nil
    }
}
