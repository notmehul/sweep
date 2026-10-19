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

    static func acceptsSentence(_ text: String, allowedFactText: String) -> Bool {
        isOneSentence(text) && accepts(text, allowedFactText: allowedFactText)
    }

    /// Sentence count, ignoring decimal points like "9.1 GB".
    static func sentenceCount(_ text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, ".!?".contains(last) else { return 0 }
        let characters = Array(trimmed)
        var count = 0
        for index in characters.indices where ".!?".contains(characters[index]) {
            let isDecimalPoint = characters[index] == "."
                && index > characters.startIndex && index + 1 < characters.endIndex
                && characters[index - 1].isNumber && characters[index + 1].isNumber
            if !isDecimalPoint { count += 1 }
        }
        return count
    }

    private static func isOneSentence(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last, ".!?".contains(last) else { return false }
        let characters = Array(trimmed)
        for index in characters.indices.dropLast() where ".!?".contains(characters[index]) {
            let isDecimalPoint = characters[index] == "."
                && index > characters.startIndex
                && characters.index(after: index) < characters.endIndex
                && characters[characters.index(before: index)].isNumber
                && characters[characters.index(after: index)].isNumber
            if !isDecimalPoint { return false }
        }
        return true
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
