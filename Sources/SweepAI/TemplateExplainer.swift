import Foundation

public struct TemplateExplainer: Explaining {
    public init() {}

    public func explainFolder(_ facts: FolderFacts) async -> FolderExplanation? {
        let kind = folderKind(for: facts)
        let folderName = URL(fileURLWithPath: facts.path).lastPathComponent
        let title = shortTitle(folderName.isEmpty ? "Folder" : folderName, kind: kind)
        let size = ByteText.format(facts.allocatedBytes)
        let items = facts.itemCount == 1 ? "1 item" : "\(facts.itemCount) items"

        let whatItIs: String
        let ifRemoved: String
        switch kind {
        case .cache:
            whatItIs = "This folder holds \(size) of temporary files used to make an app load faster."
            ifRemoved = "The app may recreate or download these files the next time you use it."
        case .appData:
            whatItIs = "This folder holds \(size) of information used by \(appName(from: facts.owningBundleID))."
            ifRemoved = "Removing it may reset the app or remove information it relies on."
        case .userContent:
            whatItIs = "This folder contains \(items) you may have created or saved, using \(size)."
            ifRemoved = "Removing it would remove personal files, so review them in Finder first."
        case .developer:
            whatItIs = "This folder holds \(size) of files made by developer tools."
            ifRemoved = "Developer tools may rebuild these files, but the next build can take longer."
        case .unknown:
            whatItIs = "This folder contains \(items) using \(size), but Sweep could not identify its purpose."
            ifRemoved = "The effect of removing it is not known, so review it in Finder first."
        }

        return FolderExplanation(title: title, summary: whatItIs + " " + ifRemoved, kind: kind)
    }

    /// The screen already shows the total in large type, so the sentence says what it is made of.
    public func summarize(_ facts: ScanSummaryFacts) async -> String {
        guard facts.freeableBytes > 0 else {
            return "Nothing here needs cleaning right now. Your Mac is in good shape."
        }
        let named = facts.topFindings.prefix(3).map { "\(Self.lowercasingFirst($0.title)) (\(ByteText.format($0.allocatedBytes)))" }
        switch named.count {
        case 0: return "Most of it is app caches and files your apps can recreate."
        case 1: return "Most of it is \(named[0])."
        case 2: return "Most of it is \(named[0]) and \(named[1])."
        default: return "The biggest pieces are \(named[0]), \(named[1]) and \(named[2])."
        }
    }

    private static func lowercasingFirst(_ title: String) -> String {
        // Keep names like "Cursor" or "Telegram" capitalised; lower only generic leading words.
        let generic = ["App", "Old", "Downloads", "Installers", "Leftovers", "Big", "Screen", "Unused"]
        guard let first = title.split(separator: " ").first, generic.contains(String(first)) else { return title }
        return title.prefix(1).lowercased() + title.dropFirst()
    }

    public func narrate(_ changes: [ChangeFact]) async -> String? {
        guard !changes.isEmpty else { return nil }
        let phrases = changes.prefix(3).map { change in
            let direction = change.deltaBytes >= 0 ? "grew" : "shrank"
            return "\(change.name) \(direction) by \(ByteText.formatMagnitude(change.deltaBytes)) \(change.period)"
        }
        return sentence(from: phrases.joined(separator: "; "))
    }

    private func folderKind(for facts: FolderFacts) -> FolderExplanation.Kind {
        let path = facts.path.lowercased()
        if path.contains("cache") { return .cache }
        if ["node_modules", ".build", "deriveddata", ".venv", "/build", "/dist"].contains(where: path.contains) {
            return .developer
        }
        let personalTypes = ["image", "video", "audio", "document", "photo", "movie"]
        if facts.fileTypeHistogram.keys.contains(where: { key in
            personalTypes.contains { key.lowercased().contains($0) }
        }) {
            return .userContent
        }
        if facts.owningBundleID != nil { return .appData }
        return .unknown
    }

    private func shortTitle(_ folderName: String, kind: FolderExplanation.Kind) -> String {
        let words = folderName.split(whereSeparator: \.isWhitespace).prefix(4)
        var title = words.isEmpty ? "Folder" : words.joined(separator: " ")
        if kind == .cache && !title.localizedCaseInsensitiveContains("cache") {
            title += " Cache"
        }
        return title
    }

    private func appName(from bundleID: String?) -> String {
        guard let bundleID, let component = bundleID.split(separator: ".").last, !component.isEmpty else {
            return "an app"
        }
        return String(component)
    }

    private func sentence(from text: String) -> String {
        guard let last = text.last, !".!?".contains(last) else { return text }
        return text + "."
    }
}

enum ByteText {
    static func format(_ bytes: Int64) -> String {
        formatMagnitude(bytes)
    }

    static func formatMagnitude(_ bytes: Int64) -> String {
        let magnitude = Double(bytes.magnitude)
        let units = ["bytes", "KB", "MB", "GB", "TB", "PB"]
        var value = magnitude
        var unit = 0
        while value >= 1_000, unit < units.count - 1 {
            value /= 1_000
            unit += 1
        }
        if unit == 0 {
            let count = UInt64(magnitude)
            return count == 1 ? "1 byte" : "\(count) bytes"
        }
        let decimals = value < 10 ? 1 : 0
        return String(format: "%.\(decimals)f %@", locale: Locale(identifier: "en_US_POSIX"), value, units[unit])
    }
}
