import Foundation
import FoundationModels

public enum AIStatus: Sendable, Equatable {
    case ready
    case downloading
    case off(reason: String)

    public static var current: AIStatus {
        from(SystemLanguageModel.default.availability)
    }

    static func from(_ availability: SystemLanguageModel.Availability) -> AIStatus {
        switch availability {
        case .available:
            return .ready
        case .unavailable(.modelNotReady):
            return .downloading
        case .unavailable(.appleIntelligenceNotEnabled):
            return .off(reason: "Apple Intelligence is turned off.")
        case .unavailable(.deviceNotEligible):
            return .off(reason: "Apple Intelligence is not available on this Mac.")
        case .unavailable:
            return .off(reason: "On-device explanations are not available right now.")
        }
    }
}

public struct ResilientExplainer: Explaining {
    private let primary: any Explaining
    private let fallback: any Explaining

    public init(
        primary: any Explaining = OnDeviceExplainer(),
        fallback: any Explaining = TemplateExplainer()
    ) {
        self.primary = primary
        self.fallback = fallback
    }

    public func explainFolder(_ facts: FolderFacts) async -> FolderExplanation? {
        if let explanation = await primary.explainFolder(facts) {
            return explanation
        }
        return await fallback.explainFolder(facts)
    }

    public func summarize(_ facts: ScanSummaryFacts) async -> String {
        let summary = await primary.summarize(facts).trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty { return summary }
        return await fallback.summarize(facts)
    }

    public func narrate(_ changes: [ChangeFact]) async -> String? {
        if let narration = await primary.narrate(changes), !narration.isEmpty {
            return narration
        }
        return await fallback.narrate(changes)
    }
}
