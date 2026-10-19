import Foundation

enum ModelOutputFilter {
    private static let bannedPhrases = ["safe to delete", "guaranteed"]

    static func accepts(_ text: String, allowedFactText: String) -> Bool {
        let lowercased = text.lowercased()
        guard !bannedPhrases.contains(where: lowercased.contains) else { return false }

        let allowedNumbers = numbers(in: allowedFactText)
        return numbers(in: text).isSubset(of: allowedNumbers)
    }

    /// Phrases that promise the files come back. Only true for caches, and a wrong promise here
    /// could talk someone into deleting their own work, so it's allowed only for cache paths.
    private static let regenerationClaims = ["rebuild", "recreate", "regenerate", "again", "re-download", "redownload"]

    static func accepts(_ explanation: FolderExplanation, allowedFactText: String, mayClaimRegeneration: Bool) -> Bool {
        if !mayClaimRegeneration {
            let text = explanation.summary.lowercased()
            if regenerationClaims.contains(where: text.contains) { return false }
        }
        return accepts(explanation, allowedFactText: allowedFactText)
    }

    static func accepts(_ explanation: FolderExplanation, allowedFactText: String) -> Bool {
        let titleWords = explanation.title.split(whereSeparator: \.isWhitespace)
        guard (1...5).contains(titleWords.count),
              (1...3).contains(sentenceCount(explanation.summary))
        else {
            return false
        }
        return [explanation.title, explanation.summary]
            .allSatisfy { accepts($0, allowedFactText: allowedFactText) }
    }

    /// Words about what removal does. The bucket subtitle leaves that to Sweep's fixed sentence.
    private static let consequenceWords = ["remov", "delet", "lose", "lost", "erase", "gone", "trash"]

    /// The bucket screen's subtitle: one sentence describing the space, with numbers from the
    /// facts and nothing about consequences or regeneration.
    static func acceptsBucketSummary(_ text: String, allowedFactText: String) -> Bool {
        let lowercased = text.lowercased()
        guard !(regenerationClaims + consequenceWords).contains(where: lowercased.contains) else { return false }
        return acceptsSentence(text, allowedFactText: allowedFactText)
    }

    static func acceptsSentence(_ text: String, allowedFactText: String) -> Bool {
        isOneSentence(text) && accepts(text, allowedFactText: allowedFactText)
    }

    /// Sentence count. A full stop only ends a sentence before a space or the end, so "9.1 GB"
    /// and "setup.dmg" don't split one.
    static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, ".!?".contains(last) else { return 0 }
        let characters = Array(trimmed)
        return characters.indices.filter { index in
            ".!?".contains(characters[index])
                && (index + 1 == characters.endIndex || characters[index + 1].isWhitespace)
        }.count
    }

    private static func isOneSentence(_ text: String) -> Bool {
        sentenceCount(text) == 1
    }

    private static func numbers(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"[-+]?[0-9]+(?:[.,][0-9]+)*"#) else {
            return []
        }
        let range = NSRange(text.startIndex..., in: text)
        return Set(expression.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return normalizeNumber(String(text[swiftRange]))
        })
    }

    private static func normalizeNumber(_ number: String) -> String {
        number.trimmingCharacters(in: CharacterSet(charactersIn: "+-")).replacingOccurrences(of: ",", with: "")
    }
}
