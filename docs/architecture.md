# Architecture

Sweep is a SwiftPM package built with the Command Line Tools alone. `scripts/bundle.sh` wraps the build into `Sweep.app`. The engine is a set of libraries the app calls directly; there's no command-line interface for users, and the tests drive the engine.

## Modules


| Target | Responsibility | Depends on |
|---|---|---|
| `SweepCore` | Model types, rule engine, classifier, safety gate. No AppKit. **The only place a `Finding` or `Bucket` is created.** | none |
| `CAttrBulk` | C wrapper around the `getattrlistbulk` loop. Returns allocated size, `ATTR_CMNEXT_PRIVATESIZE`, `EXT_FLAGS`, `CLONEID`, `FILEID` and object type. | none |
| `SweepSystem` | Adapters to macOS: `Walker` (emits `AsyncStream<WalkEvent>`: progress, items, finished folders), `CandidateCollector` (apps, Spotlight downloads/screenshots, secrets, duplicates), `CleanupExecutor`, Spotlight (scoped `MDQuery`), InstalledApps, RunningApps, Git, Simctl, Trash, FDAProbe, VolumeInfo/`tmutil` | Core, CAttrBulk |
| `SweepRules` | `Resources/rules/{generic,apps,dev}/*.json`, `schema.json` and the loader | Core |
| `SweepStore` | SQLite3: snapshots, findings, decisions (keep/ignore), history (for undo) | Core |
| `SweepAI` | FoundationModels behind the `Explaining` protocol; hand-written `Generable` types; template fallback and an output filter that rejects "it comes back" claims outside caches | Core |
| `SweepApp` | SwiftUI app. `AppModel` is an `@Observable` state machine: welcome → scanning → results → cleaning → done. | everything |

## Key types (SweepCore)

- **`Bucket`:** `rebuilds | review | yours | dontTouch`.
- **`Finding`:** `paths`, `ruleID`, the bucket, sizes, a list of `Evidence`, `lastUsed`, an `Action`, and an optional explanation.
  - Sizes: logical, allocated, and reclaimable (= the space only this item uses).
  - `lastUsed` records its source: spotlight, mtime or git.
  - Its initializer is `internal`, so only the rule engine can create one.
- **`Evidence`:**
  - `bundleNotInstalled`, `notSymlinkTarget`, `staleDays`
  - `gitDirty`, `noRemote`, `coveredByIgnore`
  - `sharesBlocks`, `appRunning`
  - `ownerApp`: the app a rule waits on (`appNotRunning`). The safety gate re-checks it at click time, because paths like `Movies/CacheClip` don't name their app.
- **`Action`:** `delete | trash | toolCommand(allow-list) | showOnly`.
- **`ScanProgress`:** bytes scanned, total used bytes, files counted, the current path, newly sized nodes for the sunburst, and the running total for each bucket.
- **`ScanSnapshot`:** free, purgeable and snapshot space; coverage (Full Disk Access, Spotlight working, folders skipped); persona; findings.

## Decisions and why

- **No Xcode required.** The project builds with the Command Line Tools, whose SDK has SwiftUI, FoundationModels and Swift Testing. The cost is no macros (`#Preview`, `@Generable`, `@Entry`, `@Model`); see `patterns.md`. Installing Xcode later is purely a convenience for development.
- **SQLite3, not SwiftData.** The `@Model` macro isn't available, and SQLite makes the scan-diff queries trivial.
- **The AI can't decide safety, by construction.** The AI's output types have no bucket field. `kind` in `FolderExplanation` only changes the wording shown to the user. The model receives facts only: path, sizes, the names of the biggest items inside, bundle IDs, dates. It never sees file contents. The code computes every number; the model only words them.
- **On-device only.** `scripts/check-no-cloud.sh` fails the build if `PrivateCloudComputeLanguageModel` appears.
- **Spotlight is queried per category, never per file.** A few scoped queries cover apps, big old files, Downloads and screenshots. Caches and developer clutter don't need Spotlight at all.
- **Sizes count the space a file actually uses.** When a rule matches a directory, the walker totals its subtree and stops reporting its children. Clones (same `CLONEID`, or the `EF_SHARES_ALL_BLOCKS` flag) are never duplicates. Hard links are de-duplicated by (dev, inode).
- **Rules ship inside the app,** never downloaded at runtime, and are reviewed through CODEOWNERS.
- **It can't be sandboxed** because it needs Full Disk Access. Distribution is through Developer ID and notarization (P5), so there's no App Store.
- **Signing:** development builds use the "Apple Development" identity, which keeps the Full Disk Access grant stable. Release builds switch to Developer ID with `--options runtime`.
