# Cleanup rules

Rules are JSON files under `Sources/SweepRules/Resources/rules/`. They decide which bucket every finding lands in, so a wrong rule can delete someone's files. Treat each one as safety-critical code.

## Order of precedence

1. **Don't-touch guards** run first and override everything:
   - a dirty or no-remote repo
   - live app databases
   - Chromium `Partitions/`
   - active browser profiles
   - anything outside `$HOME`, except a user-owned top-level `/Applications/<name>.app`
2. **Generic conventions** (`generic/`) cover any app without knowing it:
   - `~/Library/Caches/*`
   - app `Cache`/`Code Cache`/`GPUCache` folders
   - the `Caches` folders inside app containers
   - data whose non-Apple bundle ID is no longer installed (always review and Trash)
   - `.gitignore`-covered developer clutter
3. **Review rules** cover unused apps, installers for installed apps, old unopened downloads, and hash-confirmed duplicates.
4. **Known-app rules** (`apps/`, `dev/`) refine the generic conventions for specific apps, e.g. Cursor snapshots, Telegram media, Ollama models, Xcode DerivedData.

`/Applications` has one explicit exception to the outside-home guard: Sweep may classify only a top-level `.app` bundle, and the safety gate permits moving it to the Trash only when `st_uid == getuid()`. Nested bundles and every other outside-home path remain protected.

## A rule's shape

- `id`: a stable slug, e.g. `generic.library-caches`.
- `match`: one or more of: a path glob, a regex, a parent marker file such as `package.json`, a bundle-ID pattern, `gitignored`.
- `conditions`: any of:
  - `minAgeDays`
  - `appInstalled` / `appNotInstalled`
  - `appNotRunning`
  - `cleanRepo`
  - `notSymlinkTarget`
- `bucket`: `rebuilds | review | yours | dontTouch`.
- `action`:
  - `delete` (rebuilds only)
  - `trash`
  - `showOnly`
  - `toolCommand`, chosen from the allow-list: `simctlRuntimeDelete`, `brewCleanup`, `npmCacheClean`, `uvCacheClean`, `bunCacheRm`
- `explain`: three plain-language sentences: what it is, what happens if it's removed, and why it's stale.

## Adding a rule

1. Write the JSON. It must validate against `schema.json`.
2. Add a fixture test with one tree the rule should match and one near-miss it must skip.
3. `rebuilds` is reserved for things the owning app or tool really does regenerate. If you aren't sure, use `review`.
4. Use the tool's own command for state managed by that tool: Homebrew Cellar, rustup, pyenv, nvm, Docker. Deleting directories breaks their state.

## Known cases

These come from the manual cleanup that started this project:

| Item | Bucket | Note |
|---|---|---|
| Electron/Chromium `Cache`, `Code Cache`, `GPUCache` | rebuilds | Quit the app first. Never `Partitions/`. |
| `~/Library/Caches/<app>` | rebuilds | |
| Package caches (npm, bun, uv, Homebrew) | rebuilds | Use the tool's command. |
| Data left by removed non-Apple apps | review | Move to Trash. Launch Services and running apps count as installed; never classify `com.apple.*`. |
| Apps not opened for 180 days | review | Top-level `/Applications` or `~/Applications` bundles only; never Apple or running apps. Size is the bundle only in v1. |
| Installer matching an installed app | review | `.dmg`, `.pkg`, or `.zip` in Downloads; move to Trash. |
| Download added 60 days ago and never opened | review | Requires Spotlight evidence; move to Trash. |
| Hash-confirmed duplicates | review | Keep the oldest copy, preferring one outside Downloads; move the others to Trash. |
| Old CLI versions not targeted by the active symlink | rebuilds | Keep the current one plus one. |
| `.zst` next to the expanded file of the same name | rebuilds | |
| `node_modules`, `.venv`, `build`, `dist*` in projects untouched 30+ days | rebuilds | `dist-*` was missed by the original script. |
| Cursor `snapshots/{codebases,stores}` | review | A rebuildable index, but the semantic search is lost until rebuilt. |
| Simulator runtimes | review | `simctl runtime delete`; the folder is SIP-protected, so `rm` fails. |
| Chat/session histories older than 90 days | review | Prefer the app's own UI. |
| `state.vscdb`, conversation databases | dontTouch | Live state. |
| `/private/var/folders/**/code_sign_clone` | dontTouch | `du` showed 326 GB, but they're clones. |
| Large personal media, screen recordings | yours | |
| Secret-looking file names | yours | Warning only. Report the name, never the contents. |
| DaVinci `~/Movies/CacheClip`, Final Cut `Render Files` inside a `.fcpbundle`, Lightroom `Previews.lrdata` | rebuilds | The app re-renders them. Never Lightroom `Smart Previews`, which stand in for offline originals. Quit the app first; the owning app is recorded so the click-time check knows it. |
| Mail `Mail Downloads` | review | Copies of opened attachments. The only `com.apple.*` path Sweep classifies. |
| Messages attachments, WhatsApp media | yours | Family photos. Shown only; the explanation points to deleting inside the app. |
| Any file of 500 MB+ not opened for a year | yours | Any type (PSD, BRAW, PDF), outside `Library`, hidden folders and media libraries. |
