import Foundation

/// A data-driven cleanup rule. Paths in `match` are relative to the user's home folder.
public struct Rule: Sendable, Hashable, Codable {
    public var id: String
    public var match: RuleMatch
    public var conditions: RuleConditions
    public var bucket: Bucket
    public var action: RuleAction
    public var group: String
    public var title: String
    public var explain: RuleExplanation
    public var developer: Bool
    /// Whether the walker should total the matching directory and omit its children.
    public var unit: Bool
    public var priority: Int

    public init(
        id: String,
        match: RuleMatch,
        conditions: RuleConditions = RuleConditions(),
        bucket: Bucket,
        action: RuleAction,
        group: String,
        title: String,
        explain: RuleExplanation,
        developer: Bool = false,
        unit: Bool = false,
        priority: Int = 0
    ) {
        self.id = id
        self.match = match
        self.conditions = conditions
        self.bucket = bucket
        self.action = action
        self.group = group
        self.title = title
        self.explain = explain
        self.developer = developer
        self.unit = unit
        self.priority = priority
    }
}

/// All populated match fields must match. This keeps adding a refinement from broadening a rule.
public struct RuleMatch: Sendable, Hashable, Codable {
    public var pathGlob: String?
    public var regex: String?
    public var parentMarker: String?
    public var bundleIDPattern: String?
    public var gitignored: Bool?

    public init(
        pathGlob: String? = nil,
        regex: String? = nil,
        parentMarker: String? = nil,
        bundleIDPattern: String? = nil,
        gitignored: Bool? = nil
    ) {
        self.pathGlob = pathGlob
        self.regex = regex
        self.parentMarker = parentMarker
        self.bundleIDPattern = bundleIDPattern
        self.gitignored = gitignored
    }
}

public struct RuleConditions: Sendable, Hashable, Codable {
    public var minAgeDays: Int?
    /// A bundle identifier or `owner`, meaning the bundle inferred from the matched path.
    public var appInstalled: String?
    /// A bundle identifier or `owner`, meaning the bundle inferred from the matched path.
    public var appNotInstalled: String?
    /// A bundle identifier or `owner`, meaning the bundle inferred from the matched path.
    public var appNotRunning: String?
    public var cleanRepo: Bool?
    public var notSymlinkTarget: Bool?
    public var requiresSpotlight: Bool?

    public init(
        minAgeDays: Int? = nil,
        appInstalled: String? = nil,
        appNotInstalled: String? = nil,
        appNotRunning: String? = nil,
        cleanRepo: Bool? = nil,
        notSymlinkTarget: Bool? = nil,
        requiresSpotlight: Bool? = nil
    ) {
        self.minAgeDays = minAgeDays
        self.appInstalled = appInstalled
        self.appNotInstalled = appNotInstalled
        self.appNotRunning = appNotRunning
        self.cleanRepo = cleanRepo
        self.notSymlinkTarget = notSymlinkTarget
        self.requiresSpotlight = requiresSpotlight
    }
}

public enum RuleAction: Sendable, Hashable, Codable {
    case delete
    case trash
    case showOnly
    case toolCommand(ToolCommand)

    private enum CodingKeys: String, CodingKey {
        case toolCommand
    }

    public init(from decoder: any Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let value = try? container.decode(String.self) {
            switch value {
            case "delete": self = .delete
            case "trash": self = .trash
            case "showOnly": self = .showOnly
            default:
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unknown rule action '\(value)'"
                )
            }
            return
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = .toolCommand(try container.decode(ToolCommand.self, forKey: .toolCommand))
    }

    public func encode(to encoder: any Encoder) throws {
        switch self {
        case .delete:
            var container = encoder.singleValueContainer()
            try container.encode("delete")
        case .trash:
            var container = encoder.singleValueContainer()
            try container.encode("trash")
        case .showOnly:
            var container = encoder.singleValueContainer()
            try container.encode("showOnly")
        case .toolCommand(let command):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(command, forKey: .toolCommand)
        }
    }

    public var action: Action {
        switch self {
        case .delete: .delete
        case .trash: .trash
        case .showOnly: .showOnly
        case .toolCommand(let command): .toolCommand(command)
        }
    }
}

public struct RuleExplanation: Sendable, Hashable, Codable {
    public var whatItIs: String
    public var ifRemoved: String
    public var whyStale: String

    public init(whatItIs: String, ifRemoved: String, whyStale: String) {
        self.whatItIs = whatItIs
        self.ifRemoved = ifRemoved
        self.whyStale = whyStale
    }
}

/// UI-only state derived from a finding and the evidence available when it was classified.
public struct FindingPresentation: Sendable, Hashable {
    public let finding: Finding
    public let evidenceComplete: Bool

    public init(finding: Finding, evidenceComplete: Bool) {
        self.finding = finding
        self.evidenceComplete = evidenceComplete
    }

    public var isPreselected: Bool {
        finding.bucket == .rebuilds && evidenceComplete
    }
}
