# Product

Sweep is for anyone with a Mac: non-technical people, finance people and developers. It covers only the local Mac: no backups, external drives or iCloud features. It finds stale things, old copies next to newer ones, apps nobody opens, and what can be removed. Then it explains each one in plain language.

## Screens

The app is one window that moves through five screens.

1. **Welcome and access.**
   - One sentence: "Finds what's taking space on your Mac and explains it. Nothing leaves your Mac."
   - One button grants Full Disk Access. It opens the right Settings pane, and the app detects the grant and moves on by itself.
   - If the user skips this step, Sweep scans what it can and shows the share it covered, e.g. "scanned 72% of your Mac".
   - Desktop, Documents and Downloads access is requested here, never in the middle of a scan.
2. **Scanning.**
   - A sunburst grows outward as the scan goes deeper. Home is at the centre, and each ring is one folder level deeper.
   - Segments are coloured by bucket once it's known.
   - Progress is scanned bytes divided by the disk's used bytes, so it's real progress rather than a spinner.
   - Underneath: live counters of files and GB, the current folder's name, and running totals for each bucket.
3. **Results.**
   - A headline: "You can free 38 GB."
   - One sentence from the on-device model, or from a template when the model isn't available.
   - Three bucket cards, each with its size and item count.
   - Clicking a sunburst segment jumps to its items.
4. **Bucket detail.**
   - Items are grouped, each with an icon, a size, when it was last opened, and a checkbox.
   - An item card shows what the item is, what happens if it's removed, why Sweep thinks it's stale (with evidence), and a "Show in Finder" button.
   - "Keep this, don't ask again" stores a decision so the item doesn't come back.
5. **Clean and done.**
   - The button states exactly what will happen: "Free 21 GB: delete caches (12 GB), move 9 items to Trash (9 GB)".
   - A confirmation sheet lists the actions.
   - Afterwards, an animated before/after bar shows the space measured as freed. If macOS is still holding space in snapshots or as purgeable, one line explains it.
   - Undo, and a history of every past cleanup.

**Later:**
- a menu-bar mini view showing free space and the last scan date
- an "Ask about my Mac" box, which answers using tools that query the scan
- Help → "Export scan report…": JSON with personal file names removed, which testers send back

## Buckets

| Bucket | Default | Action | Contents |
|---|---|---|---|
| Rebuilds itself | ticked | delete | App caches (`~/Library/Caches/*`, app `Cache`/`Code Cache`/`GPUCache` folders, the `Caches` folders inside app containers); data left behind by deleted apps; developer clutter in projects untouched for 30+ days (whatever `.gitignore` covers, plus `node_modules`, `.venv`, `build`, `dist*`); old tool versions the active symlink doesn't point to (keep the current one plus one); package caches, cleaned with the tool's own command |
| Probably don't need | unticked | move to Trash | Apps not opened in 6+ months (size includes the app's data); installers for apps already installed; downloads never opened; duplicates confirmed by hash; old copies next to new ones (two Xcodes, old app copies, old Node/Python versions, iPhone backups, IPSW update files); what's already in the Trash |
| Your call | no checkbox | Show in Finder | Big files not opened in a year; screenshots and recordings grouped by month; files whose names suggest secrets (warning only) |
| Don't touch | hidden | none | Repos with uncommitted changes or no remote, live app databases (`state.vscdb`, chat histories), active browser profiles, Chromium `Partitions/`, anything outside `$HOME` |

**Fitting the person:** developer groups appear only when developer tools are present (Xcode, Homebrew, Node, or git from the Command Line Tools).

**When Spotlight isn't working:** "unused" and "never opened" items are marked "couldn't verify" and start unticked.

## What Sweep never does

- strip app languages
- touch system folders
- run as root
- "clean memory"
- clean anything automatically outside "Rebuilds itself"
- delete Docker.raw; it explains `docker system prune` instead
- use a cloud model

Emptying the Trash gets its own confirmation and is excluded from the undo promise.

## Who it's for

The scanner works out who's using it and adapts. A finance user never sees the words "node_modules". A developer sees their stale projects and old toolchains.
