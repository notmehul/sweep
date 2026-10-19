import Foundation
import SweepCore

/// Bundled cleanup rules. Rules ship inside the app and are never fetched at runtime.
public enum RuleCatalog {
    public static var directory: URL? { Bundle.module.url(forResource: "rules", withExtension: nil) }

    public static func load() throws -> [Rule] {
        guard let directory else { throw RuleCatalogError.missingResources }
        return try load(from: directory)
    }

    static func load(from directory: URL) throws -> [Rule] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            throw RuleCatalogError.missingResources
        }

        let files = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "schema.json" }
            .sorted { $0.path < $1.path }
        guard !files.isEmpty else { throw RuleCatalogError.noRules }

        let decoder = JSONDecoder()
        var rules: [Rule] = []
        for file in files {
            do {
                let data = try Data(contentsOf: file)
                try validateShape(data, file: file.lastPathComponent)
                rules.append(contentsOf: try decoder.decode([Rule].self, from: data))
            } catch {
                if let catalogError = error as? RuleCatalogError { throw catalogError }
                throw RuleCatalogError.invalidFile(file.lastPathComponent, String(describing: error))
            }
        }

        var seen = Set<String>()
        for rule in rules {
            guard !rule.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.group.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.explain.whatItIs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.explain.ifRemoved.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !rule.explain.whyStale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw RuleCatalogError.missingRequiredField(rule.id)
            }
            let idPattern = try NSRegularExpression(pattern: "^[a-z0-9]+([.-][a-z0-9]+)*$")
            let idRange = NSRange(rule.id.startIndex..<rule.id.endIndex, in: rule.id)
            guard idPattern.firstMatch(in: rule.id, range: idRange)?.range == idRange else {
                throw RuleCatalogError.invalidID(rule.id)
            }
            guard seen.insert(rule.id).inserted else {
                throw RuleCatalogError.duplicateID(rule.id)
            }
            guard rule.match.pathGlob != nil
                    || rule.match.regex != nil
                    || rule.match.parentMarker != nil
                    || rule.match.bundleIDPattern != nil
                    || rule.match.gitignored != nil
            else {
                throw RuleCatalogError.emptyMatch(rule.id)
            }
            let matchStrings = [
                rule.match.pathGlob,
                rule.match.regex,
                rule.match.parentMarker,
                rule.match.bundleIDPattern,
            ].compactMap { $0 }
            guard matchStrings.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw RuleCatalogError.emptyMatch(rule.id)
            }
            let conditionStrings = [
                rule.conditions.appInstalled,
                rule.conditions.appNotInstalled,
                rule.conditions.appNotRunning,
            ].compactMap { $0 }
            guard conditionStrings.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }) else {
                throw RuleCatalogError.missingRequiredField(rule.id)
            }
            if let regex = rule.match.regex {
                do {
                    _ = try NSRegularExpression(pattern: regex)
                } catch {
                    throw RuleCatalogError.invalidRegex(rule.id)
                }
            }
            if let days = rule.conditions.minAgeDays, days < 0 {
                throw RuleCatalogError.invalidAge(rule.id)
            }
            if rule.conditions.appInstalled != nil, rule.conditions.appNotInstalled != nil {
                throw RuleCatalogError.conflictingConditions(rule.id)
            }
            if rule.bucket != .rebuilds, case .delete = rule.action {
                throw RuleCatalogError.unsafeAction(rule.id)
            }
        }
        return rules
    }

    private static func validateShape(_ data: Data, file: String) throws {
        guard let objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              !objects.isEmpty
        else {
            throw RuleCatalogError.invalidFile(file, "The top level must be a non-empty array.")
        }

        let ruleKeys: Set<String> = [
            "id", "match", "conditions", "bucket", "action", "group", "title",
            "explain", "developer", "unit", "priority",
        ]
        let matchKeys: Set<String> = [
            "pathGlob", "regex", "parentMarker", "bundleIDPattern", "gitignored",
        ]
        let conditionKeys: Set<String> = [
            "minAgeDays", "appInstalled", "appNotInstalled", "appNotRunning",
            "cleanRepo", "notSymlinkTarget", "requiresSpotlight",
        ]
        let explanationKeys: Set<String> = ["whatItIs", "ifRemoved", "whyStale"]

        for (index, object) in objects.enumerated() {
            try requireExactKeys(
                object,
                required: ruleKeys,
                allowed: ruleKeys,
                context: "rule \(index)",
                file: file
            )
            guard let match = object["match"] as? [String: Any], !match.isEmpty else {
                throw RuleCatalogError.invalidFile(file, "rule \(index) has no match fields.")
            }
            try requireExactKeys(
                match,
                required: [],
                allowed: matchKeys,
                context: "rule \(index).match",
                file: file
            )
            guard let conditions = object["conditions"] as? [String: Any] else {
                throw RuleCatalogError.invalidFile(file, "rule \(index).conditions must be an object.")
            }
            try requireExactKeys(
                conditions,
                required: [],
                allowed: conditionKeys,
                context: "rule \(index).conditions",
                file: file
            )
            guard let explanation = object["explain"] as? [String: Any] else {
                throw RuleCatalogError.invalidFile(file, "rule \(index).explain must be an object.")
            }
            try requireExactKeys(
                explanation,
                required: explanationKeys,
                allowed: explanationKeys,
                context: "rule \(index).explain",
                file: file
            )
            if let action = object["action"] as? [String: Any] {
                try requireExactKeys(
                    action,
                    required: ["toolCommand"],
                    allowed: ["toolCommand"],
                    context: "rule \(index).action",
                    file: file
                )
            }
        }
    }

    private static func requireExactKeys(
        _ object: [String: Any],
        required: Set<String>,
        allowed: Set<String>,
        context: String,
        file: String
    ) throws {
        let keys = Set(object.keys)
        if let missing = required.subtracting(keys).sorted().first {
            throw RuleCatalogError.invalidFile(file, "\(context) is missing '\(missing)'.")
        }
        if let unknown = keys.subtracting(allowed).sorted().first {
            throw RuleCatalogError.invalidFile(file, "\(context) contains unknown field '\(unknown)'.")
        }
    }
}

public enum RuleCatalogError: Error, Equatable, CustomStringConvertible {
    case missingResources
    case noRules
    case invalidFile(String, String)
    case missingRequiredField(String)
    case invalidID(String)
    case duplicateID(String)
    case emptyMatch(String)
    case invalidRegex(String)
    case invalidAge(String)
    case conflictingConditions(String)
    case unsafeAction(String)

    public var description: String {
        switch self {
        case .missingResources: "Bundled rule resources are missing."
        case .noRules: "The bundled catalog contains no rules."
        case .invalidFile(let file, let reason): "\(file) is not a valid rule file: \(reason)"
        case .missingRequiredField(let id): "\(id) is missing required text."
        case .invalidID(let id): "Rule ID '\(id)' is not a stable slug."
        case .duplicateID(let id): "Rule ID '\(id)' appears more than once."
        case .emptyMatch(let id): "\(id) has no match criteria."
        case .invalidRegex(let id): "\(id) has an invalid regular expression."
        case .invalidAge(let id): "\(id) has a negative minimum age."
        case .conflictingConditions(let id): "\(id) requires an app to be both installed and absent."
        case .unsafeAction(let id): "\(id) deletes data outside the rebuilds bucket."
        }
    }
}
