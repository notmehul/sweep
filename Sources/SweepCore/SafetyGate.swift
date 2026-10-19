import Foundation

public enum GateResult: Sendable, Hashable {
    case ok
    case skip(reason: String)
}

public enum SafetyGate {
    public static func check(
        _ finding: Finding,
        current: [ScannedItem]?,
        facts: any SystemFacts
    ) -> GateResult {
        switch finding.bucket {
        case .yours:
            return .skip(reason: "Sweep never removes your personal files.")
        case .dontTouch:
            return .skip(reason: "This item is marked as something Sweep must not touch.")
        case .rebuilds, .review:
            break
        }

        switch finding.action {
        case .showOnly:
            return .skip(reason: "This item can only be shown in Finder.")
        case .delete where finding.bucket != .rebuilds:
            return .skip(reason: "Only files that rebuild themselves can be deleted directly.")
        case .delete, .trash, .toolCommand:
            break
        }

        guard let current else {
            return .skip(reason: "Sweep couldn't verify that this item is unchanged.")
        }

        let home = canonicalPath(facts.homeDirectory)
        for scanned in finding.items {
            let path = canonicalPath(scanned.path)
            guard isInside(path, directory: home) else {
                return .skip(reason: "This item is outside your home folder.")
            }
            if path == home {
                return .skip(reason: "Sweep will never remove your home folder.")
            }
            let protectedRoots = ["Desktop", "Documents", "Downloads", "Library"]
                .map { canonicalPath((home as NSString).appendingPathComponent($0)) }
            if protectedRoots.contains(path) {
                return .skip(reason: "Sweep will not remove a main folder in your home folder.")
            }

            guard let refreshed = current.first(where: { $0.path == scanned.path }) else {
                return .skip(reason: "This item is no longer where Sweep found it.")
            }
            guard refreshed.fileID == scanned.fileID else {
                return .skip(reason: "This item was replaced since the scan.")
            }
            guard sizeMatches(scanned: scanned, current: refreshed) else {
                return .skip(reason: "This item changed size since the scan.")
            }
            guard refreshed.modified <= scanned.modified else {
                return .skip(reason: "This item was changed after Sweep scanned it.")
            }
        }

        if let bundleID = bundleIdentifier(for: finding), facts.isRunning(bundleID: bundleID) {
            return .skip(reason: "Quit the app that owns this item, then try again.")
        }

        if finding.isDeveloper {
            for item in finding.items {
                if let state = facts.gitState(repoContaining: item.path) {
                    if state.isDirty {
                        return .skip(reason: "This project has uncommitted changes. Commit or save them first.")
                    }
                    if !state.hasRemote {
                        return .skip(reason: "This project has no remote copy, so Sweep left it alone.")
                    }
                }
            }
        }

        return .ok
    }

    public static func bundleIdentifier(for finding: Finding) -> String? {
        for evidence in finding.evidence {
            switch evidence {
            case .appRunning(let bundleID), .bundleNotInstalled(let bundleID):
                if looksLikeBundleIdentifier(bundleID) { return bundleID }
            default:
                break
            }
        }

        for item in finding.items {
            for component in URL(fileURLWithPath: item.path).pathComponents.reversed() {
                if looksLikeBundleIdentifier(component) { return component }
            }
        }
        return nil
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func isInside(_ path: String, directory: String) -> Bool {
        path.hasPrefix(directory + "/")
    }

    private static func sizeMatches(scanned: ScannedItem, current: ScannedItem) -> Bool {
        if !scanned.isDirectory {
            return current.allocatedSize == scanned.allocatedSize
        }
        guard scanned.allocatedSize > 0 else { return current.allocatedSize == 0 }
        let change = abs(Double(current.allocatedSize - scanned.allocatedSize))
        return change <= Double(scanned.allocatedSize) * 0.01
    }

    private static func looksLikeBundleIdentifier(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count >= 2, parts.allSatisfy({ !$0.isEmpty }) else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
        }
    }
}
