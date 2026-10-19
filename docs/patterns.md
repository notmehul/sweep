# Patterns

How code is written here. When you need a pattern that isn't listed, add it in the same change that introduces it.

## Swift style

- Swift 6 language mode with strict concurrency. Model types are `Sendable` value types.
- Long work (scanning, hashing) runs in a `TaskGroup` at `.utility` priority and checks `Task.isCancelled`.
- Progress flows as an `AsyncStream`, limited to about 30 updates a second, into `@Observable` app state on the main actor.

## Writing what the macros would write

The Command Line Tools ship no macro plugins for SwiftUI, SwiftData or FoundationModels.

- **Environment value** (instead of `@Entry`): write a `private struct FooKey: EnvironmentKey { static let defaultValue = ... }` plus an `EnvironmentValues` extension with a get/set property.
- **AI output** (instead of `@Generable`): conform to `Generable` by hand.
  - Give it a static `generationSchema` built with `GenerationSchema(type:description:properties:)`.
  - Give it `init(_ content: GeneratedContent) throws`, reading fields with `content.value(_:forProperty:)`.
  - Use `DynamicGenerationSchema` for shapes known only at runtime.
- **Previews** (instead of `#Preview`): launch the app with `SWEEP_FIXTURE_SNAPSHOT=<path.json>` to load a saved scan, so screens can be iterated on without rescanning.

## Tests

- Use Swift Testing (`import Testing`, `@Test`, `#expect`). XCTest isn't in the Command Line Tools.
- Build fixture trees in a temp folder made per test, with helpers that create the real edge cases: sparse files, `clonefile()` copies, hard links, git repos (dirty, no remote), fake `.app` bundles with an `Info.plist`, and version folders behind an `active` symlink.
- Every cleanup rule has at least one fixture test proving it matches what it should and skips its near-miss.
- AI tests use a fake `Explaining` or a fake `LanguageModelExecutor`. Live-model tests are gated on `SystemLanguageModel.default.availability`, use greedy sampling, and check structure and banned phrases, never exact wording.

## User-facing text

- Plain language with no jargon: "App caches", not "Chromium GPUCache".
- Each item card answers three questions: what it is, what happens if you remove it, and why Sweep thinks it's stale.
- Numbers are calculated by code. The model only words sentences around numbers it was given.

## SwiftUI without macro plugins

- `@State` is a macro in the macOS 27 SDK. Use `@ViewState` (an alias to the `SwiftUI.State` property wrapper, in `Theme.swift`), which bypasses the macro.
- Colours, type and spacing come only from `Theme`. Every colour has a light and a dark value.
- Each bucket's colour always comes with its SF Symbol (`Theme.symbol(for:)`), so colour is never the only signal.
- Dev aids:
  - `SWEEP_APPEARANCE=light|dark` pins the appearance for screenshots.
  - `SWEEP_AUTOSCAN=1` starts a scan on launch (with `open -g --env`), so no clicks are needed.
  - The app currently runs on `DemoSource`/`DemoCleaner` sample data until the engine is wired in.
