import FoundationModels

struct GeneratedFolderExplanation: Generable {
    var title: String
    var whatItIs: String
    var ifRemoved: String
    var kind: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self,
            description: "A short, plain-language explanation of a folder.",
            properties: [
                .init(
                    name: "title",
                    description: "A plain title of no more than five words.",
                    type: String.self
                ),
                .init(
                    name: "whatItIs",
                    description: "One sentence explaining what the folder contains.",
                    type: String.self
                ),
                .init(
                    name: "ifRemoved",
                    description: "One sentence explaining what may happen if the folder is removed.",
                    type: String.self
                ),
                .init(
                    name: "kind",
                    description: "The folder's purpose, used only to choose wording.",
                    type: String.self,
                    guides: [.anyOf(FolderExplanation.Kind.allCases.map(\.rawValue))]
                ),
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        title = try content.value(String.self, forProperty: "title")
        whatItIs = try content.value(String.self, forProperty: "whatItIs")
        ifRemoved = try content.value(String.self, forProperty: "ifRemoved")
        kind = try content.value(String.self, forProperty: "kind")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: [
            "title": title,
            "whatItIs": whatItIs,
            "ifRemoved": ifRemoved,
            "kind": kind,
        ])
    }

    func explanation() -> FolderExplanation? {
        guard let kind = FolderExplanation.Kind(rawValue: kind) else { return nil }
        return FolderExplanation(title: title, whatItIs: whatItIs, ifRemoved: ifRemoved, kind: kind)
    }
}

struct GeneratedText: Generable {
    var text: String

    static var generationSchema: GenerationSchema {
        GenerationSchema(
            type: Self.self,
            description: "One short sentence in plain language.",
            properties: [
                .init(name: "text", description: "One complete sentence.", type: String.self),
            ]
        )
    }

    init(_ content: GeneratedContent) throws {
        text = try content.value(String.self, forProperty: "text")
    }

    var generatedContent: GeneratedContent {
        GeneratedContent(properties: ["text": text])
    }
}
