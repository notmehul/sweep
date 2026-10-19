# Status

**Current milestone:** P0, the toolchain spike. The repository was scaffolded on 19 Oct 2026.

## Milestones

Each one ends in an app you open and click.

| # | Scope | Exit criteria | State |
|---|---|---|---|
| P0 | Toolchain spike | `swift test` passes. `scripts/run.sh` opens a signed `Sweep.app` window. That window shows a `Canvas` animation, plus the on-device model's availability and one hand-written `Generable` reply under `--options runtime`. | in progress: package, tests, signed bundle, Canvas animation and model availability verified 19 Oct; hand-written `Generable` reply still to do |
| P1 | Engine + scan screen + results (read-only) | Golden fixture tests pass, and every known case in `rules.md` has a test. On this Mac: the sunburst grows live with real progress, a full home scan takes under 3 minutes, the totals are within 2% of `du -A`, and the three buckets are shown. | in progress: walker, system facts, candidate sources, rule engine, safety gate and fixture coverage implemented; full-scan performance and app wiring remain |
| P2 | Bucket detail, item cards, keep/ignore, saved scans, export report | Decisions persist across relaunches. Two scans give the correct "what changed". Ten item cards checked by hand. | in progress: bucket detail, saved scans, decisions, scan changes and redacted JSON export implemented; hand-checking remains |
| P3 | Clean, confirmation sheet, done screen, undo, history | Clean then undo restores fixtures. A real cleanup here frees the predicted amount. A running app blocks with "Quit X first". Then test on friends' Macs. | in progress: confirmation, safety-gated cleanup, done screen, per-cleanup undo and history implemented; real cleanup and friend testing remain |
| P4 | On-device AI: headline, unknown-folder explanations, "what changed" | Fake-model tests pass. The app works fully with AI off. Live evals are gated on availability. | not started |
| P5 | "Ask about my Mac", menu-bar view, icon, Developer ID and notarization | Notarized build opens on a clean Mac. | in progress: menu-bar view implemented; Ask, icon, Developer ID and notarization remain |

## Open items

- A paid Developer ID account is needed before sharing with non-technical friends (P5).
- The final name, the icon, and the visual style of the sunburst.
