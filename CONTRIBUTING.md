# Reading and working on Sweep

Sweep is a SwiftPM package that builds with the Command Line Tools alone; there's no Xcode project. This page gets you from a fresh clone to knowing where things live. The deeper docs are in [`docs/`](docs).

## Run it

```sh
xcode-select --install       # once, if you don't have the Command Line Tools
swift test                   # every test runs against temporary fixture folders, never your files
scripts/run.sh               # build, bundle build/Sweep.app, sign and open it
SWEEP_DEMO=1 scripts/run.sh  # the same app replaying sample data, without scanning your disk
```

A scan is read-only. Nothing is removed until you press the clean button and confirm.

## How a scan flows

```
Walker ──▶ RuleEngine ──▶ CandidateCollector ──▶ findings ──▶ SwiftUI screens
 (sizes)    (buckets)      (apps, downloads,       │
                            duplicates)            ▼
                                     CleanupExecutor ──▶ SafetyGate re-checks ──▶ delete / Trash
```

1. **`Walker`** reads the home folder with `getattrlistbulk` (through the small C target `CAttrBulk`) and streams sizes as it goes. That stream draws the live sunburst.
2. **`RuleEngine`** matches each path against the JSON rules and puts it in a bucket: *rebuilds itself*, *probably don't need*, *your call*, or the hidden *don't touch*.
3. **`CandidateCollector`** adds what a size walk can't see: apps and when they were last opened (Spotlight), old downloads, screenshots, and hash-confirmed duplicates.
4. **`SweepAI`** words the results and explains any folder you click, using Apple's on-device model. It only ever sees names and numbers, and it can't change a bucket.
5. **`CleanupExecutor`** asks **`SafetyGate`** to re-check every item at click time (still there, unchanged, its app closed, inside your home folder) before deleting it or moving it to the Trash. **`SweepStore`** (SQLite) keeps history for undo.

## Where things live

| Folder | What's in it |
|---|---|
| `Sources/SweepCore` | Model types, the rule engine and the safety gate. The only place a finding's bucket is decided. No AppKit. |
| `Sources/SweepRules/Resources/rules` | The cleanup rules as JSON: `generic/` for any Mac, `apps/` for known apps, `dev/` for developer tools. |
| `Sources/SweepSystem` | Everything that talks to macOS: the walker, Spotlight, installed apps, git, the Trash, Full Disk Access. |
| `Sources/SweepAI` | On-device model calls, the template fallback, and the filter that rejects unsafe wording. |
| `Sources/SweepStore` | SQLite: past scans, keep/ignore decisions, cleanup history. |
| `Sources/SweepApp` | The SwiftUI app: screens, the sunburst, the aurora backdrop, the menu bar. |
| `Tests/` | Swift Testing, one target per module. |
| `scripts/` | `run.sh`, `bundle.sh`, `release.sh`, and `check-no-cloud.sh`, which fails the build if a cloud model API appears. |

## Things that surprise people

- **No macros.** The Command Line Tools ship without the SwiftUI and FoundationModels macro plugins, so `@Generable`, `#Preview` and `@State` are written out by hand. [`docs/patterns.md`](docs/patterns.md) shows how.
- **Rules are safety-critical.** A wrong rule can delete someone's files. Every rule needs a fixture test that it matches, and a near-miss it must skip. Read [`docs/rules.md`](docs/rules.md) before adding one.
- **Sizes are honest.** Clones, hard links and iCloud placeholders are counted the way the disk actually stores them, so Sweep's numbers are what you'd really get back.

## Docs

- [`AGENTS.md`](AGENTS.md): the hard rules that protect people's files (also read by coding agents).
- [`docs/product.md`](docs/product.md): the screens and what each bucket holds.
- [`docs/architecture.md`](docs/architecture.md): modules, key types, and why each choice was made.
- [`docs/status.md`](docs/status.md): what works and what's left.

## Releasing

Bump `CFBundleShortVersionString` in `Resources/Info.plist`, commit, then run `scripts/release.sh`. It runs the tests, builds a DMG and a zip, tags the version, and publishes a GitHub release. `scripts/release.sh --dry-run` builds into `dist/` without publishing.
