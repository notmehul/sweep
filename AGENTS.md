# Sweep: agent instructions

Sweep is a macOS app for people who aren't technical. You open it, watch it scan, and it shows what's taking space and what you can remove, explained in plain language by Apple's on-device model. It's open source, and every user-facing interaction happens in the app's window.

**The guiding principle is trust.** Every finding has to be true, every size has to be real, and every removal has to be undoable or clearly confirmed. When convenience and trust conflict, choose trust.

## Read first

1. `docs/status.md`: the current milestone, what's done, and what's next.
2. `docs/product.md`: the screens, the buckets, and what Sweep never does.
3. `docs/architecture.md`: the modules, the key types, and why each choice was made.
4. `docs/patterns.md`: how to write code here. Read it before adding a file.
5. `docs/rules.md`: read it before adding or changing a cleanup rule.

## Hard rules

These protect the user's files. A change that breaks one doesn't ship.

- **Buckets are decided only by `SweepCore`'s rule engine.**
  - AI output types carry no bucket.
  - A `Finding` is only ever created inside `SweepCore`.
- **The on-device model is the only model.** `scripts/check-no-cloud.sh` fails the build if any cloud model API appears.
- **Writes stay inside `$HOME`.**
  - Personal files go to the Trash.
  - Only the "rebuilds itself" bucket is deleted directly.
  - Everything runs as the user, never as root.
- **Re-check right before acting.** Just before any removal, the safety gate checks again:
  - file ID, edit date and size
  - the owning app isn't running
  - the repo is clean
  - the path is inside home
- **Sizes are allocated bytes,** and what's reclaimable is the space only this item uses. Clones, hard links and sparse files are counted once, honestly.
- **Never read a file flagged `SF_DATALESS`** (an iCloud placeholder), because reading it downloads it.
- **Tests run against fixture trees built in a temp folder.** The real home folder is only ever scanned, never modified, outside a deliberate manual run.

## Commands

- `swift build` / `swift test`: build with the Command Line Tools only. There's no Xcode project. Tests use Swift Testing, because XCTest isn't available.
- `scripts/run.sh`: build, bundle `build/Sweep.app`, sign it, and open it. Use this to see the UI.
- `scripts/check-no-cloud.sh`: the no-cloud guard. Run it before declaring work done.

## Toolchain gotchas

The Command Line Tools ship no macro plugins for SwiftUI, SwiftData or FoundationModels, so:
- `#Preview`, `@Entry`, `@Model` and `@Generable` won't compile. Write those conformances by hand; `docs/patterns.md` shows how.
- `@Observable` works.
- There's no asset catalog: colours are defined in code, and the icon is built with `iconutil`.

Development builds are signed with the "Apple Development" identity. The stable signature keeps the Full Disk Access grant across rebuilds; an ad-hoc signature would lose it every time.

## Definition of done

These apply on top of the global working agreement:
- `swift test` passes.
- `scripts/check-no-cloud.sh` passes.
- Any new rule has a fixture test.
- UI work was looked at in the running app, not only compiled.
- `docs/status.md` is updated when a milestone item moves.
