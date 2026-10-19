import FoundationModels
import Testing
@testable import SweepAI

@Test func folderExplanationDecodesGeneratedContent() throws {
    let content = GeneratedContent(properties: [
        "title": "Spotify Cache",
        "summary": "This folder holds temporary music files. Spotify may download them again.",
        "kind": "cache",
    ])

    let generated = try GeneratedFolderExplanation(content)
    let explanation = try #require(generated.explanation())

    #expect(explanation.title == "Spotify Cache")
    #expect(explanation.summary == "This folder holds temporary music files. Spotify may download them again.")
    #expect(explanation.kind == .cache)
    #expect(try GeneratedFolderExplanation(generated.generatedContent).explanation() == explanation)
}

@Test func folderExplanationRejectsUnknownKind() throws {
    let content = GeneratedContent(properties: [
        "title": "Mystery Folder",
        "summary": "This folder has an unknown purpose. Its effect is not known.",
        "kind": "other",
    ])

    #expect(try GeneratedFolderExplanation(content).explanation() == nil)
}

@Test func generatedTextDecodesAndEncodesContent() throws {
    let content = GeneratedContent(properties: ["text": "Sweep found 9.1 GB you could free."])
    let generated = try GeneratedText(content)

    #expect(generated.text == "Sweep found 9.1 GB you could free.")
    #expect(try GeneratedText(generated.generatedContent).text == generated.text)
}

@Test func handWrittenSchemasCanBeConstructed() {
    _ = GeneratedFolderExplanation.generationSchema
    _ = GeneratedText.generationSchema
}
