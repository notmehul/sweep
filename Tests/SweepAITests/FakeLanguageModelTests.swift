import FoundationModels
import Testing
@testable import SweepAI

// Custom LanguageModel executors arrived in macOS 27; the app itself runs on 26.
@available(macOS 27, *)
private struct FakeLanguageModel: LanguageModel {
    typealias Executor = FakeLanguageModelExecutor
    var response: String

    var capabilities: LanguageModelCapabilities {
        LanguageModelCapabilities([.guidedGeneration])
    }

    var executorConfiguration: FakeLanguageModelExecutor.Configuration {
        .init(response: response)
    }
}

@available(macOS 27, *)
private struct FakeLanguageModelExecutor: LanguageModelExecutor {
    struct Configuration: Hashable, Sendable {
        var response: String
    }

    typealias Model = FakeLanguageModel
    let configuration: Configuration

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    func prewarm(model: FakeLanguageModel, transcript: Transcript) {}

    func respond(
        to request: LanguageModelExecutorGenerationRequest,
        model: FakeLanguageModel,
        streamingInto channel: LanguageModelExecutorGenerationChannel
    ) async throws {
        #expect(request.schema != nil)
        await channel.send(.response(action: .appendText(configuration.response, tokenCount: 20)))
    }
}

@available(macOS 27, *)
@Test func fakeExecutorDrivesARealLanguageModelSession() async throws {
    let json = """
        {
          "title": "Spotify Cache",
          "summary": "This folder holds temporary music files. Spotify may recreate these files.",
          "kind": "cache"
        }
        """
    let session = LanguageModelSession(
        model: FakeLanguageModel(response: json),
        instructions: "Use only the supplied facts."
    )

    let response = try await session.respond(
        to: "Explain the Spotify cache.",
        generating: GeneratedFolderExplanation.self,
        options: GenerationOptions(samplingMode: .greedy)
    )

    #expect(response.content.title == "Spotify Cache")
    #expect(response.content.kind == "cache")
}
