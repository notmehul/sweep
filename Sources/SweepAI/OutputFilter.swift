import Foundation

enum ModelOutputFilter {
    private static let bannedPhrases = ["safe to delete", "guaranteed"]

    static func accepts(_ text: String, allowedFactText: String) -> Bool {
        let lowercased = text.lowercased()
        guard !bannedPhrases.contains(where: lowercased.contains) else { return false }

        let allowedNumbers = numbers(in: allowedFactText)
        return numbers(in: text).isSubset(of: allowedNumbers)
    }

    static func accepts(_ explanation: FolderExplanation, allowedFactText: String) -> Bool {
        let titleWords = explanation.title.split(whereSeparator: \.isWhitespace)
        guard (1...5).contains(titleWords.count),
              isOneSentence(explanation.whatItIs),
              isOneSentence(explanation.ifRemoved)
        else {
            return false
        }
        return [explanation.title, explanation.whatItIs, explanation.ifRemoved]
            .allSatisfy { accepts($0, allowedFactText: allowedFactText) }
    }

    static func acceptsSentence(_ text: String, allowedFactText: String) -> Bool {
        isOneSentence(text) && accepts(text, allowedFactText: allowedFactText)
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
