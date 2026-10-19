# Status

**As of 19 Oct 2026:** the app runs end to end on a real Mac: scan, results, review, clean, undo, history. What's left before sharing is signing, plus testing on friends' Macs.

## Milestones

| # | Scope | State |
|---|---|---|
| P0 | Toolchain spike | Done. Builds with the Command Line Tools only; the `@State` macro is worked around with `@ViewState`. |
| P1 | Engine, scan screen, results | Done. A full home scan (1.4M files, about 180 GB) takes about 55 s in a release build. The sunburst grows live and colours what's cleanable. |
| P2 | Bucket detail, item cards, keep/ignore, saved scans, export report | Done. Rows are grouped per app. Items under 1 MB are hidden. The export removes personal path parts. |
| P3 | Clean, confirm, done, undo, history | Done. Verified on this Mac: the pip cache was deleted (61 MB measured against 60 MB predicted), and a real Trash round trip restored the file byte-identical. |
| P4 | On-device AI | Done. The results summary, the "what changed" sentence, and a one-paragraph explanation for any folder clicked in the sunburst, with a template fallback and a filter against "it comes back" claims. |
| P5 | Menu bar, icon, signing | The menu bar and icon are done. **Not started:** "Ask about my Mac", plus Developer ID signing and notarization, which need the paid account. |

## Known gaps

- When launched in the background (`open -g`, or a login item), SwiftUI creates no window until the app is activated. Double-clicking is unaffected.
- A first scan estimates progress, because the home folder's size isn't known yet. Later scans use the previous scan's total.
- Runs on macOS 26 and later. Before 26.4 the AI prompts aren't measured first; an over-long one just falls back to the template.
- Rules for non-developers (creative-app caches, Mail, Messages, WhatsApp, big files of any type, duplicates in Pictures and Movies) are tested on fixtures. Only DaVinci's cache was seen on a real Mac; the WhatsApp media path is unverified.
- Rules have so far only been checked against one real Mac (a developer's). Run the opt-in `HomeReport` test on friends' Macs before trusting the rules for everyone.

## How to check a Mac without changing it

- `SWEEP_HOME_REPORT=1 swift test -c release -Xswiftc -enable-testing --filter HomeReport` lists every finding, bucket and timing. It's read-only.
- `SWEEP_REAL_TRASH=1 swift test --filter RealTrash` round-trips a file Sweep creates itself through the real Trash.
