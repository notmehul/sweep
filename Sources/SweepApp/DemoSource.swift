import Foundation
import SweepCore

/// Replays a believable scan without touching the disk. Used for UI work
/// (`SWEEP_DEMO=1 scripts/run.sh`) and until the real engine is wired in.
struct DemoSource: ScanSource {
    var duration: TimeInterval = 7

    func scan() -> AsyncStream<ScanUpdate> {
        AsyncStream { continuation in
            let task = Task {
                let tree = Self.tree
                let total: Int64 = 245 * Self.gb
                let steps = 140
                for step in 0...steps {
                    if Task.isCancelled { break }
                    let fraction = Double(step) / Double(steps)
                    let revealed = Self.reveal(tree, fraction: fraction)
                    let progress = ScanProgress(scannedBytes: Int64(Double(total) * fraction), totalBytes: total,
                                                filesSeen: Int(fraction * 1_284_330),
                                                currentPath: Self.paths[min(Self.paths.count - 1, Int(fraction * Double(Self.paths.count)))])
                    continuation.yield(.progress(progress, tree: revealed))
                    try? await Task.sleep(for: .seconds(duration / Double(steps)))
                }
                continuation.yield(.finished(ScanReport(
                    tree: tree, findings: Self.findings, coverage: 1, isDeveloper: true,
                    summary: "Most of it is Cursor's search index, app caches, and two apps you haven't opened since March.",
                    usedBytes: total)))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Shows top-level folders as they "finish", in order, so the rings grow outward.
    private static func reveal(_ tree: SizeNode, fraction: Double) -> SizeNode {
        var out = tree
        var budget = Int64(Double(tree.allocatedSize) * fraction)
        out.children = tree.children.compactMap { child in
            guard budget > 0 else { return nil }
            defer { budget -= child.allocatedSize }
            if budget >= child.allocatedSize { return child }
            var partial = child
            partial.children = []
            partial.allocatedSize = budget
            return partial
        }
        return out
    }

    private static let gb: Int64 = 1_000_000_000

    private static let paths = [
        "~/Library/Application Support/Cursor", "~/Library/Application Support/Slack/Cache",
        "~/Library/Caches/com.spotify.client", "~/Library/Containers/ru.keepcoder.Telegram",
        "~/Dev/memory-bench/node_modules", "~/Downloads", "~/Movies", "~/Documents", "~/Pictures",
    ]

    private static func node(_ name: String, _ gbs: Double, _ bucket: Bucket? = nil, _ children: [SizeNode] = [],
                             parent: String = "~") -> SizeNode {
        SizeNode(name: name, path: parent + "/" + name, allocatedSize: Int64(gbs * Double(gb)), bucket: bucket,
                 children: children)
    }

    static let tree = SizeNode(name: "Home", path: "~", allocatedSize: Int64(232 * Double(gb)), children: [
        node("Library", 96, nil, [
            node("Application Support", 48, nil, [
                node("Cursor", 18, .rebuilds, parent: "~/Library/Application Support"),
                node("Claude", 11, nil, parent: "~/Library/Application Support"),
                node("Slack", 6, .rebuilds, parent: "~/Library/Application Support"),
                node("DaVinci Resolve", 5, .review, parent: "~/Library/Application Support"),
                node("Other", 8, nil, parent: "~/Library/Application Support"),
            ], parent: "~/Library"),
            node("Caches", 15, .rebuilds, parent: "~/Library"),
            node("Containers", 22, nil, [
                node("Telegram", 9, .rebuilds, parent: "~/Library/Containers"),
                node("WhatsApp", 7, nil, parent: "~/Library/Containers"),
                node("Other", 6, nil, parent: "~/Library/Containers"),
            ], parent: "~/Library"),
            node("Other", 11, nil, parent: "~/Library"),
        ]),
        node("Dev", 58, nil, [
            node("memory-bench", 22, nil, [node("node_modules", 9, .rebuilds, parent: "~/Dev/memory-bench"),
                                           node("src", 13, nil, parent: "~/Dev/memory-bench")], parent: "~/Dev"),
            node("Aoura", 14, nil, [node("Pods", 6, .rebuilds, parent: "~/Dev/Aoura"),
                                    node("src", 8, nil, parent: "~/Dev/Aoura")], parent: "~/Dev"),
            node("old-projects", 22, nil, parent: "~/Dev"),
        ]),
        node("Downloads", 36, nil, [node("Installers", 8, .review, parent: "~/Downloads"),
                                    node("Never opened", 11, .review, parent: "~/Downloads"),
                                    node("Recent", 17, nil, parent: "~/Downloads")]),
        node("Movies", 22, .yours),
        node("Documents", 12),
        node("Pictures", 8),
    ])

    /// Decoded from JSON because `Finding`'s initializer is internal to SweepCore.
    static let findings: [Finding] = {
        let json = """
        [
        \(f("cursor-snapshots", "apps.cursor.snapshots", "Cursor search index", "App data", "rebuilds", "~/Library/Application Support/Cursor/snapshots", 18.2, "delete", "Cursor's index of your code projects, used for search.", "Cursor rebuilds it the next time you open a project. Search is slower until then.", "Most of it belongs to projects you haven't opened in months.", 120))
        ,\(f("lib-caches", "generic.library-caches", "App caches", "App caches", "rebuilds", "~/Library/Caches", 14.6, "delete", "Files apps keep so they open and load faster.", "Apps recreate what they need. The first launch may be a little slower.", "Caches can always be rebuilt.", 2))
        ,\(f("telegram-media", "apps.telegram.cache", "Telegram media cache", "App caches", "rebuilds", "~/Library/Containers/ru.keepcoder.Telegram/Data/Library/Caches", 9.1, "delete", "Photos and videos Telegram saved while you scrolled chats.", "Telegram downloads them again if you open those chats.", "Your messages stay; only the cached media goes.", 5))
        ,\(f("slack-cache", "apps.slack.cache", "Slack cache", "App caches", "rebuilds", "~/Library/Application Support/Slack/Cache", 2.4, "delete", "Images and files Slack stored to load channels faster.", "Slack fetches them again when needed.", "Caches can always be rebuilt.", 1))
        ,\(f("mb-node", "dev.node-modules", "memory-bench · node_modules", "Developer files", "rebuilds", "~/Dev/memory-bench/node_modules", 9.0, "delete", "Packages downloaded for this project.", "Running npm install brings them back.", "You haven't edited this project in 31 days and its code is safely committed.", 31, dev: true))
        ,\(f("aoura-pods", "dev.pods", "Aoura · Pods", "Developer files", "rebuilds", "~/Dev/Aoura/ios/Pods", 6.1, "delete", "iOS libraries downloaded for this project.", "pod install brings them back.", "Untouched for 64 days, code committed.", 64, dev: true))
        ,\(f("davinci", "generic.orphaned-app-data", "DaVinci Resolve leftovers", "Leftovers from deleted apps", "review", "~/Library/Application Support/Blackmagic Design", 5.2, "trash", "Settings and project library from DaVinci Resolve, which is no longer installed.", "If you reinstall DaVinci, your old projects won't be there.", "The app was removed from your Mac.", 40))
        ,\(f("installers", "generic.installers", "Installers for apps you already have", "Installers", "review", "~/Downloads/Installers", 8.3, "trash", "Disk images (.dmg) and packages you used to install apps.", "Nothing. The apps are already installed.", "Every one of these apps is already in Applications.", 180))
        ,\(f("never-opened", "generic.downloads-never-opened", "Downloads you never opened", "Old downloads", "review", "~/Downloads", 10.9, "trash", "214 files downloaded since January that were never opened.", "They go to the Trash, so you can still get them back.", "Not opened since they were downloaded.", 210))
        ,\(f("movies", "yours.big-files", "Screen recordings 2025", "Big and old", "yours", "~/Movies", 21.7, "showOnly", "Twelve screen recordings, each over a gigabyte.", "Sweep won't touch these. Open them in Finder to decide.", "None opened in over a year.", 400))
        ]
        """
        return (try? JSONDecoder().decode([Finding].self, from: Data(json.utf8))) ?? []
    }()

    private static func f(_ id: String, _ rule: String, _ title: String, _ group: String, _ bucket: String,
                          _ path: String, _ gbs: Double, _ action: String, _ what: String, _ removed: String,
                          _ why: String, _ days: Int, dev: Bool = false) -> String {
        let bytes = Int64(gbs * Double(gb))
        let used = Date.now.addingTimeInterval(-Double(days) * 86_400).timeIntervalSinceReferenceDate
        return """
        {"id":"\(id)","ruleID":"\(rule)","title":"\(title)","group":"\(group)","bucket":"\(bucket)",
         "items":[{"path":"\(path)","isDirectory":true,"logicalSize":\(bytes),"allocatedSize":\(bytes),
                   "reclaimableSize":\(bytes),"fileCount":1200,"fileID":1,"device":1,"modified":\(used),"flags":0}],
         "evidence":[{"staleDays":{"_0":\(days)}}],"lastUsed":{"date":\(used),"source":"spotlight"},
         "action":{"\(action)":{}},
         "explanation":{"whatItIs":"\(what)","ifRemoved":"\(removed)","whyStale":"\(why)"},"isDeveloper":\(dev)}
        """
    }
}

/// Pretends to clean so the flow can be walked end to end in demo mode.
struct DemoCleaner: Cleaner {
    func clean(_ findings: [Finding]) async -> CleanOutcome {
        try? await Task.sleep(for: .seconds(2.2))
        return CleanOutcome(freedBytes: findings.filter { $0.action != .trash }.reduce(0) { $0 + $1.reclaimableSize },
                            trashedBytes: findings.filter { $0.action == .trash }.reduce(0) { $0 + $1.reclaimableSize },
                            deletedCount: findings.filter { $0.action == .delete }.count,
                            trashedCount: findings.filter { $0.action == .trash }.count,
                            skipped: [], canUndo: true)
    }

    func undoLast() async -> Bool { true }
}
