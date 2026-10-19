import Foundation
import FoundationModels

public struct OnDeviceExplainer: Explaining {
    private static let instructions = """
        Write for a person who is not technical. Use short, plain sentences.
        Speak to the reader as "you". Never write "the person" or "the user".
        Base the explanation on the folder's name and the names of the largest items inside it.
        When those items belong to different apps, say the folder holds data for several apps
        rather than describing it as one app's files.
        Never claim that removing something is safe. Never use the phrase safe to delete.
        Never invent a number or change a number. Use only the facts in the prompt.
        Do not decide whether anything should be removed. Describe only what the facts support.
        For folder explanations, write one paragraph of two or three sentences: what the folder is
        and what is inside it, then what removing it would mean. Each sentence adds something new;
        never restate the same point, and never list the same names twice.
        Name the app in plain words, and say concretely what the files are for.
        A folder named Cache, Caches or similar holds copies an app keeps so things load faster; the app
        fetches or rebuilds them when needed. For any folder that is not a cache, never say the app
        rebuilds, recreates or downloads the files again; say what the person would lose instead.
        Avoid vague phrases such as "some stored information" or "data and database files".
        Example for a browser cache: "Copies of web pages and images Chrome keeps so sites open faster.
        Chrome downloads them again the next time you visit those sites."
        """

    private let model: SystemLanguageModel
    private let fallback: TemplateExplainer

    public init() {
        model = .default
        fallback = TemplateExplainer()
    }

    public func explainFolder(_ facts: FolderFacts) async -> FolderExplanation? {
        guard model.availability == .available else { return nil }
        let prompt = folderPrompt(facts)

        do {
            guard try await fits(
                prompt: prompt,
                schema: GeneratedFolderExplanation.generationSchema,
                responseTokens: 180
            ) else {
                return nil
            }
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedFolderExplanation.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 180)
            )
            guard let explanation = response.content.explanation(),
                  ModelOutputFilter.accepts(explanation, allowedFactText: prompt,
                                                  mayClaimRegeneration: facts.path.lowercased().contains("cache"))
            else {
                return nil
            }
            return explanation
        } catch {
            return nil
        }
    }

    public func summarize(_ facts: ScanSummaryFacts) async -> String {
        guard model.availability == .available else {
            return await fallback.summarize(facts)
        }
        let prompt = summaryPrompt(facts)

        do {
            guard try await fits(prompt: prompt, schema: GeneratedText.generationSchema, responseTokens: 100) else {
                return await fallback.summarize(facts)
            }
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedText.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 100)
            )
            let text = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard ModelOutputFilter.acceptsSentence(text, allowedFactText: prompt) else {
                return await fallback.summarize(facts)
            }
            return text
        } catch {
            return await fallback.summarize(facts)
        }
    }

    public func narrate(_ changes: [ChangeFact]) async -> String? {
        guard !changes.isEmpty, model.availability == .available else { return nil }
        let prompt = changePrompt(changes)

        do {
            guard try await fits(prompt: prompt, schema: GeneratedText.generationSchema, responseTokens: 100) else {
                return nil
            }
            let session = LanguageModelSession(model: model, instructions: Self.instructions)
            let response = try await session.respond(
                to: prompt,
                generating: GeneratedText.self,
                options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: 100)
            )
            let text = response.content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return ModelOutputFilter.acceptsSentence(text, allowedFactText: prompt) ? text : nil
        } catch {
            return nil
        }
    }

    private func fits(prompt: String, schema: GenerationSchema, responseTokens: Int) async throws -> Bool {
        let instructionTokens = try await model.tokenCount(for: Instructions(Self.instructions))
        let promptTokens = try await model.tokenCount(for: prompt)
        let schemaTokens = try await model.tokenCount(for: schema)
        return instructionTokens + promptTokens + schemaTokens + responseTokens <= model.contextSize
    }

    private func folderPrompt(_ facts: FolderFacts) -> String {
        let children = facts.topChildren.map {
            "\($0.name): \(ByteText.format($0.allocatedBytes))"
        }.joined(separator: "; ")
        let histogram = facts.fileTypeHistogram.keys.sorted().map {
            "\($0): \(facts.fileTypeHistogram[$0, default: 0])"
        }.joined(separator: "; ")

        return """
            Explain this folder using only these facts.
            Write the summary as two or three sentences that each add something new.
            Path: \(facts.path)
            Allocated size: \(ByteText.format(facts.allocatedBytes))
            Item count: \(facts.itemCount)
            Largest children: \(children.isEmpty ? "none listed" : children)
            Owning app bundle: \(facts.owningBundleID ?? "not known")
            Newest modification: \(facts.newestModificationDate?.ISO8601Format() ?? "not known")
            File types: \(histogram.isEmpty ? "not known" : histogram)
            """
    }

    private func summaryPrompt(_ facts: ScanSummaryFacts) -> String {
        let findings = facts.topFindings.map {
            "\($0.title): \(ByteText.format($0.allocatedBytes))"
        }.joined(separator: "; ")
        let coverage = Int((facts.coverage * 100).rounded())

        return """
            The screen already shows the total, so do not repeat it.
            In one plain sentence, tell the person what most of that space is, naming the largest findings with their sizes.
            Example: "Most of it is Cursor's search index (18 GB) and app caches (15 GB)."
            Freeable: \(ByteText.format(facts.freeableBytes))
            Rebuilds itself: \(ByteText.format(facts.perBucketBytes.rebuilds))
            Needs review: \(ByteText.format(facts.perBucketBytes.review))
            User content: \(ByteText.format(facts.perBucketBytes.yours))
            Not offered for removal: \(ByteText.format(facts.perBucketBytes.dontTouch))
            Largest findings: \(findings.isEmpty ? "none" : findings)
            Coverage: \(coverage)%
            """
    }

    private func changePrompt(_ changes: [ChangeFact]) -> String {
        let facts = changes.map { change in
            let direction = change.deltaBytes >= 0 ? "grew" : "shrank"
            return "\(change.name): \(direction) by \(ByteText.formatMagnitude(change.deltaBytes)); period: \(change.period)"
        }.joined(separator: "\n")

        return """
            Describe what changed in one sentence using only these facts.
            \(facts)
            """
    }
}
