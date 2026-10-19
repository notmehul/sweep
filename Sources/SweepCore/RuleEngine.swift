import Foundation

public final class RuleEngine: Sendable {
    private let rules: [CompiledRule]
    private let facts: any SystemFacts
    private let home: String

    public init(rules: [Rule], facts: any SystemFacts) {
        self.facts = facts
        self.home = Self.cleanPath(facts.homeDirectory)
        self.rules = rules
            .sorted {
                if $0.priority != $1.priority { return $0.priority > $1.priority }
                return $0.id < $1.id
            }
            .map(CompiledRule.init)
    }

    /// A path-only hot path for the walker. Directories are claimed only by unit rules;
    /// matching file rules are also reported even when the file is below the walker's
    /// normal large-file threshold. Conditions are checked again after measurement.
    public func claimsAsUnit(path: String, isDirectory: Bool) -> Bool {
        guard let relative = relativePath(path) else { return false }
        return rules.contains { compiled in
            guard compiled.rule.unit == isDirectory else { return false }
            let owner = owner(for: relative)
            return compiled.pathMatches(relative: relative, owner: owner)
                && unitConditionsAllow(compiled.rule, owner: owner)
        }
    }

    public func classify(_ items: [ScannedItem]) -> [Finding] {
        let normalizedItems = items.map { item -> ScannedItem in
            var copy = item
            copy.path = Self.cleanPath(item.path)
            return copy
        }
        let context = ClassificationContext(items: normalizedItems, home: home)
        var findings: [Finding] = []

        for item in normalizedItems {
            if let guarded = guardFinding(for: item) {
                findings.append(guarded)
                continue
            }

            guard let relative = relativePath(item.path) else { continue }
            let owner = owner(for: relative)
            // macOS's own services (com.apple.*) are usually running, and "never touch system
            // stuff" is a promise to the user, so their folders never become findings.
            if relative.split(separator: "/").contains(where: { $0.hasPrefix("com.apple.") }) { continue }
            for compiled in rules {
                guard matches(compiled, item: item, relative: relative, owner: owner, context: context),
                      let result = conditionResult(
                          compiled.rule,
                          item: item,
                          relative: relative,
                          owner: owner,
                          context: context
                      )
                else { continue }

                findings.append(makeFinding(
                    rule: compiled.rule,
                    item: item,
                    owner: owner,
                    evidence: result.evidence,
                    lastUsed: result.lastUsed
                ))
                break
            }
        }

        return groupMonthlyPersonalFiles(findings)
    }

    /// Turns hash-confirmed duplicate groups into review findings. The copy outside
    /// Downloads is preferred; otherwise the oldest copy is kept.
    public func classifyDuplicates(_ groups: [[ScannedItem]]) -> [Finding] {
        groups.flatMap { group -> [Finding] in
            let unique = Dictionary(
                group.map { (Self.cleanPath($0.path), $0) },
                uniquingKeysWith: { first, _ in first }
            ).values
            guard unique.count > 1 else { return [] }
            let sorted = unique.sorted { left, right in
                let leftInDownloads = isInDownloads(left.path)
                let rightInDownloads = isInDownloads(right.path)
                if leftInDownloads != rightInDownloads { return !leftInDownloads }
                if left.modified != right.modified { return left.modified < right.modified }
                return left.path < right.path
            }
            guard let kept = sorted.first else { return [] }
            // Copies inside organised folders are often deliberate (before/after evidence,
            // dataset snapshots). Offer only stray copies: loose in Downloads or Desktop, or
            // named like a copy ("report (1).pdf", "report copy.pdf"), and never inside a repo.
            return sorted.dropFirst().filter(isStrayCopy).map { duplicate in
                Finding(
                    id: "generic.duplicates:\(duplicate.path)",
                    ruleID: "generic.duplicates",
                    title: URL(fileURLWithPath: duplicate.path).lastPathComponent,
                    group: "Duplicates",
                    bucket: .review,
                    items: [duplicate],
                    evidence: [.duplicateOf(kept.path)],
                    lastUsed: LastUsed(date: duplicate.modified, source: .mtime),
                    action: .trash,
                    explanation: Explanation(
                        whatItIs: "This file is an exact copy of another file.",
                        ifRemoved: "The copy at \(kept.path) stays in place.",
                        whyStale: "Sweep compared both files and confirmed that their contents match."
                    ),
                    isDeveloper: false
                )
            }
        }.sorted { $0.id < $1.id }
    }

    private func isStrayCopy(_ item: ScannedItem) -> Bool {
        guard facts.gitState(repoContaining: item.path) == nil else { return false }
        let path = Self.cleanPath(item.path)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let loose = [("Downloads"), ("Desktop")].contains { parent == (home as NSString).appendingPathComponent($0) }
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let copyNamed = name.range(of: #"( \(\d+\)| copy( \d+)?| \d)$"#, options: .regularExpression) != nil
        return loose || copyNamed
    }

    /// Presentation state is kept separate so `Finding` remains the safety contract.
    public func presentation(for finding: Finding) -> FindingPresentation {
        let requiresSpotlight = rules.first { $0.rule.id == finding.ruleID }?
            .rule.conditions.requiresSpotlight == true
        let spotlightEvidenceComplete: Bool
        switch finding.ruleID {
        case "generic.downloads-never-opened":
            spotlightEvidenceComplete = facts.spotlightWorks && finding.items.allSatisfy {
                facts.dateAdded(path: $0.path) != nil && facts.lastOpened(path: $0.path) == nil
            }
        case "generic.unused-apps":
            spotlightEvidenceComplete = facts.spotlightWorks && finding.items.allSatisfy {
                facts.lastOpened(path: $0.path) != nil || facts.dateAdded(path: $0.path) != nil
            }
        default:
            spotlightEvidenceComplete = facts.spotlightWorks
                && finding.items.allSatisfy { facts.lastOpened(path: $0.path) != nil }
        }
        return FindingPresentation(
            finding: finding,
            evidenceComplete: !requiresSpotlight || spotlightEvidenceComplete
        )
    }

    private func matches(
        _ compiled: CompiledRule,
        item: ScannedItem,
        relative: String,
        owner: String?,
        context: ClassificationContext
    ) -> Bool {
        guard compiled.pathMatches(relative: relative, owner: owner) else { return false }

        if let marker = compiled.rule.match.parentMarker,
           !context.hasMarker(named: marker, above: item.path) {
            return false
        }
        if let ignored = compiled.rule.match.gitignored,
           isGitIgnored(item.path) != ignored {
            return false
        }

        if compiled.rule.id == "generic.compressed-copy",
           !context.hasExpandedCopy(for: item.path) {
            return false
        }
        if compiled.rule.id == "apps.claude-vm-compressed",
           !context.hasExpandedCopy(for: item.path) {
            return false
        }
        if compiled.rule.id == "dev.project-junk",
           !item.isDirectory {
            return false
        }
        // Only the user's own projects: a git checkout outside hidden folders and ~/Library.
        // Installed tools (Codex, cursor-agent, editor language servers) also ship
        // node_modules, and deleting those breaks the tool.
        if compiled.rule.id == "dev.project-junk",
           facts.gitState(repoContaining: item.path) == nil
            || relative.hasPrefix(".") || relative.hasPrefix("Library/") {
            return false
        }
        if compiled.rule.id == "yours.secret-looking-names",
           relative.hasPrefix("Library/") || relative.split(separator: "/").dropLast().contains(where: { $0.hasPrefix(".") || $0 == "site-packages" || $0 == "node_modules" })
            || ["jpg", "jpeg", "png", "gif", "heic", "webp", "mov", "mp4", "mp3",
                "swift", "ts", "tsx", "js", "jsx", "py", "go", "rs", "java", "kt", "rb", "md"]
                .contains((item.path as NSString).pathExtension.lowercased()) {
            return false
        }
        if compiled.rule.id == "yours.large-old-files",
           item.reclaimableSize < 500 * 1_024 * 1_024 {
            return false
        }
        if compiled.rule.id.hasPrefix("generic.orphan-"),
           owner?.lowercased().hasPrefix("com.apple.") == true {
            return false
        }
        if compiled.rule.id == "generic.unused-apps" {
            let bundleID = facts.bundleIdentifier(forApplicationAt: item.path)
            if bundleID?.lowercased().hasPrefix("com.apple.") == true { return false }
            if let bundleID, facts.isRunning(bundleID: bundleID) { return false }
            let name = URL(fileURLWithPath: item.path).deletingPathExtension().lastPathComponent
            if facts.isRunning(appNamed: name) { return false }
        }
        if compiled.rule.id == "generic.installers",
           matchedInstalledAppName(forInstallerAt: item.path) == nil {
            return false
        }
        return true
    }

    private func unitConditionsAllow(_ rule: Rule, owner: String?) -> Bool {
        if rule.match.parentMarker != nil || rule.match.gitignored != nil {
            return false
        }
        if rule.id.hasPrefix("generic.orphan-"),
           owner?.lowercased().hasPrefix("com.apple.") == true {
            return false
        }
        func bundleID(_ value: String) -> String? {
            value == "owner" ? owner : value
        }
        if let value = rule.conditions.appInstalled {
            guard let bundleID = bundleID(value), facts.isInstalled(bundleID: bundleID) else {
                return false
            }
        }
        if let value = rule.conditions.appNotInstalled {
            guard let bundleID = bundleID(value), !facts.isInstalled(bundleID: bundleID) else {
                return false
            }
        }
        if let value = rule.conditions.appNotRunning {
            guard let bundleID = bundleID(value), !facts.isRunning(bundleID: bundleID) else {
                return false
            }
        }
        return true
    }

    private func conditionResult(
        _ rule: Rule,
        item: ScannedItem,
        relative: String,
        owner: String?,
        context: ClassificationContext
    ) -> ConditionResult? {
        var evidence: [Evidence] = []
        let bundle = { (value: String) -> String? in
            value == "owner" ? owner : value
        }

        if rule.id == "generic.unused-apps" {
            let opened = facts.lastOpened(path: item.path)
            guard let relevantDate = opened ?? facts.dateAdded(path: item.path) else { return nil }
            let days = ageInDays(since: relevantDate)
            guard days >= (rule.conditions.minAgeDays ?? 180) else { return nil }
            if opened == nil { evidence.append(.neverOpened) }
            evidence.append(.staleDays(days))
            return ConditionResult(
                evidence: evidence,
                lastUsed: LastUsed(date: opened, source: .spotlight)
            )
        }

        if rule.id == "generic.downloads-never-opened" {
            guard facts.lastOpened(path: item.path) == nil,
                  let added = facts.dateAdded(path: item.path)
            else {
                return nil
            }
            let days = ageInDays(since: added)
            guard days >= (rule.conditions.minAgeDays ?? 60) else { return nil }
            return ConditionResult(
                evidence: [.neverOpened, .staleDays(days)],
                lastUsed: LastUsed(date: nil, source: .spotlight)
            )
        }

        if rule.id == "generic.installers" {
            guard let appName = matchedInstalledAppName(forInstallerAt: item.path) else {
                return nil
            }
            return ConditionResult(
                evidence: [.installerForInstalledApp(appName)],
                lastUsed: LastUsed(date: item.modified, source: .mtime)
            )
        }

        if let installed = rule.conditions.appInstalled {
            guard let bundleID = bundle(installed), facts.isInstalled(bundleID: bundleID) else {
                return nil
            }
            evidence.append(.installerForInstalledApp(bundleID))
        }
        if let notInstalled = rule.conditions.appNotInstalled {
            guard let bundleID = bundle(notInstalled), !facts.isInstalled(bundleID: bundleID) else {
                return nil
            }
            evidence.append(.bundleNotInstalled(bundleID))
        }
        if let notRunning = rule.conditions.appNotRunning {
            guard let bundleID = bundle(notRunning), !facts.isRunning(bundleID: bundleID) else {
                return nil
            }
        }

        let git = facts.gitState(repoContaining: item.path)
        if rule.conditions.cleanRepo == true, let git, git.isDirty {
            return nil
        }

        if rule.match.gitignored == true {
            evidence.append(.coveredByIgnore)
        }

        if rule.conditions.notSymlinkTarget == true {
            guard let active = context.oldVersionEvidence(for: item) else { return nil }
            evidence.append(.notSymlinkTarget(active: active))
        }

        let lastUsed: LastUsed
        if rule.id == "dev.project-junk", let projectDate = context.newestProjectSource(for: item) {
            lastUsed = LastUsed(date: projectDate, source: git?.lastCommit == nil ? .mtime : .git)
        } else if let git, rule.developer, let lastCommit = git.lastCommit {
            lastUsed = LastUsed(date: lastCommit, source: .git)
        } else if let opened = facts.lastOpened(path: item.path) {
            lastUsed = LastUsed(date: opened, source: .spotlight)
        } else {
            lastUsed = LastUsed(date: item.modified, source: .mtime)
        }

        if let minimum = rule.conditions.minAgeDays {
            guard let date = lastUsed.date else { return nil }
            let days = ageInDays(since: date)
            guard days >= minimum else { return nil }
            evidence.append(.staleDays(days))
        }

        return ConditionResult(evidence: evidence, lastUsed: lastUsed)
    }

    private func guardFinding(for item: ScannedItem) -> Finding? {
        guard let relative = relativePath(item.path) else {
            if isAllowedApplicationCandidate(item.path) { return nil }
            return makeGuardFinding(
                id: "guard.outside-home",
                title: "Outside your home folder",
                item: item,
                evidence: []
            )
        }

        if let git = facts.gitState(repoContaining: item.path) {
            if git.isDirty {
                return makeGuardFinding(
                    id: "guard.dirty-repository",
                    title: "Project with unsaved changes",
                    item: item,
                    evidence: [.gitDirty],
                    lastUsed: git.lastCommit.map { LastUsed(date: $0, source: .git) }
                )
            }
            if !git.hasRemote {
                return makeGuardFinding(
                    id: "guard.repository-without-remote",
                    title: "Project without a backup remote",
                    item: item,
                    evidence: [.noRemote],
                    lastUsed: git.lastCommit.map { LastUsed(date: $0, source: .git) }
                )
            }
        }

        let components = relative.split(separator: "/").map(String.init)
        if components.contains("Partitions") {
            return makeGuardFinding(
                id: "guard.chromium-partitions",
                title: "Browser partition data",
                item: item,
                evidence: []
            )
        }

        let name = URL(fileURLWithPath: item.path).lastPathComponent.lowercased()
        if name == "state.vscdb" || isLiveConversationDatabase(name) {
            return makeGuardFinding(
                id: "guard.live-database",
                title: "Live app information",
                item: item,
                evidence: []
            )
        }

        if isBrowserProfile(relative), let bundleID = browserBundleID(relative),
           facts.isRunning(bundleID: bundleID) {
            return makeGuardFinding(
                id: "guard.active-browser-profile",
                title: "Browser data in use",
                item: item,
                evidence: [.appRunning(bundleID)]
            )
        }

        return nil
    }

    private func makeFinding(
        rule: Rule,
        item: ScannedItem,
        owner: String?,
        evidence: [Evidence],
        lastUsed: LastUsed
    ) -> Finding {
        let values = templateValues(item: item, owner: owner, evidence: evidence)
        var title = render(rule.title, values: values)
        var whatItIs = render(rule.explain.whatItIs, values: values)
        // An app with the same name is still installed under a newer ID (e.g. the old
        // WhatsApp Desktop vs today's WhatsApp): say so, or it reads like the current app.
        if rule.id.hasPrefix("generic.orphan"), let app = values["app"],
           facts.installedApplicationNames.contains(where: { $0.caseInsensitiveCompare(app) == .orderedSame }) {
            title = "Leftovers from an older \(app)"
            whatItIs = "This belongs to an older version of \(app) that is no longer installed. The \(app) you use now keeps its data separately and isn't affected."
        }
        return Finding(
            id: "\(rule.id):\(item.path)",
            ruleID: rule.id,
            title: title,
            group: render(rule.group, values: values),
            bucket: rule.bucket,
            items: [item],
            evidence: evidence,
            lastUsed: lastUsed,
            action: rule.action.action,
            explanation: Explanation(
                whatItIs: whatItIs,
                ifRemoved: render(rule.explain.ifRemoved, values: values),
                whyStale: rule.conditions.requiresSpotlight == true
                    && lastUsed.source != .spotlight
                    ? "Sweep couldn't verify when this file was last opened."
                    : render(rule.explain.whyStale, values: values)
            ),
            isDeveloper: rule.developer
        )
    }

    private func makeGuardFinding(
        id: String,
        title: String,
        item: ScannedItem,
        evidence: [Evidence],
        lastUsed: LastUsed? = nil
    ) -> Finding {
        Finding(
            id: "\(id):\(item.path)",
            ruleID: id,
            title: title,
            group: "Protected items",
            bucket: .dontTouch,
            items: [item],
            evidence: evidence,
            lastUsed: lastUsed,
            action: .showOnly,
            explanation: Explanation(
                whatItIs: "This is information an app or project is using.",
                ifRemoved: "Sweep will not remove it.",
                whyStale: "A safety check says this item must be left alone."
            ),
            isDeveloper: id.contains("repository")
        )
    }

    private func groupMonthlyPersonalFiles(_ findings: [Finding]) -> [Finding] {
        let monthlyIDs: Set<String> = ["yours.screenshots-recordings"]
        var ordinary = findings.filter { !monthlyIDs.contains($0.ruleID) }
        let grouped = Dictionary(grouping: findings.filter { monthlyIDs.contains($0.ruleID) }) {
            finding -> String in
            let date = Self.captureDate(finding.items[0]) ?? finding.items[0].modified
            let components = Calendar(identifier: .gregorian).dateComponents([.year, .month], from: date)
            return String(format: "%04d-%02d", components.year ?? 0, components.month ?? 0)
        }

        for (month, values) in grouped {
            guard let first = values.first else { continue }
            let items = values.flatMap(\.items).sorted { $0.path < $1.path }
            let date = Self.captureDate(first.items[0]) ?? first.items[0].modified
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "MMMM yyyy"
            ordinary.append(Finding(
                id: "\(first.ruleID):\(month)",
                ruleID: first.ruleID,
                title: "Screenshots and recordings from \(formatter.string(from: date))",
                group: first.group,
                bucket: first.bucket,
                items: items,
                evidence: values.flatMap(\.evidence),
                lastUsed: values.compactMap(\.lastUsed).max {
                    ($0.date ?? .distantPast) < ($1.date ?? .distantPast)
                },
                action: first.action,
                explanation: first.explanation,
                isDeveloper: first.isDeveloper
            ))
        }
        return ordinary.sorted { $0.id < $1.id }
    }

    /// macOS names captures "Screenshot 2024-09-19 at …"; that date beats the file's mtime.
    static func captureDate(_ item: ScannedItem) -> Date? {
        let name = (item.path as NSString).lastPathComponent
        guard let range = name.range(of: #"\d{4}-\d{2}-\d{2}"#, options: .regularExpression) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(name[range]))
    }

    private func templateValues(
        item: ScannedItem,
        owner: String?,
        evidence: [Evidence]
    ) -> [String: String] {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        let days = evidence.compactMap { evidence -> Int? in
            if case .staleDays(let value) = evidence { return value }
            return nil
        }.first
        return [
            "app": appName(owner: owner, path: item.path),
            "age": days.map { "\($0) days" } ?? "a while",
            "size": formatter.string(fromByteCount: item.reclaimableSize),
        ]
    }

    private func render(_ template: String, values: [String: String]) -> String {
        values.reduce(template) { result, pair in
            result.replacingOccurrences(of: "{\(pair.key)}", with: pair.value)
        }
    }

    private func relativePath(_ path: String) -> String? {
        let clean = Self.cleanPath(path)
        if clean == home { return "" }
        if clean.hasPrefix(home + "/") {
            return String(clean.dropFirst(home.count + 1))
        }
        if isAllowedApplicationCandidate(clean) {
            return "Applications/\(URL(fileURLWithPath: clean).lastPathComponent)"
        }
        return nil
    }

    private func owner(for relative: String) -> String? {
        let parts = relative.split(separator: "/").map(String.init)
        if parts.count > 2, parts[0] == "Library", parts[1] == "Containers" {
            return parts[2]
        }
        if parts.count > 2, parts[0] == "Library", parts[1] == "Group Containers" {
            let knownGroups = [
                "group.com.tinyspeck.slackmacgap": "com.tinyspeck.slackmacgap",
                "group.com.microsoft.teams2": "com.microsoft.teams2",
            ]
            return knownGroups[parts[2]]
        }
        if parts.count > 2, parts[0] == "Library", parts[1] == "Caches" {
            return Self.looksLikeBundleID(parts[2]) ? parts[2] : nil
        }
        if parts.count > 2, parts[0] == "Library", parts[1] == "Preferences" {
            return URL(fileURLWithPath: parts[2]).deletingPathExtension().lastPathComponent
        }
        if parts.count > 2, parts[0] == "Library", parts[1] == "Saved Application State" {
            return parts[2].replacingOccurrences(of: ".savedState", with: "")
        }
        if parts.count > 2, parts[0] == "Library", parts[1] == "Application Support",
           Self.looksLikeBundleID(parts[2]) {
            return parts[2]
        }

        let knownComponents = [
            "cursor": "com.todesktop.230313mzl4w4u92",
            "slack": "com.tinyspeck.slackmacgap",
            "microsoft teams": "com.microsoft.teams2",
            "teams": "com.microsoft.teams2",
            "discord": "com.hnc.Discord",
            "zoom.us": "us.zoom.xos",
            "whatsapp": "net.whatsapp.WhatsApp",
            "telegram": "ru.keepcoder.Telegram",
            "spotify": "com.spotify.client",
            "google chrome": "com.google.Chrome",
            "arc": "company.thebrowser.Browser",
            "brave-browser": "com.brave.Browser",
            "microsoft edge": "com.microsoft.edgemac",
            "claude": "com.anthropic.claudefordesktop",
            "signal": "org.whispersystems.signal-desktop",
            "xcode": "com.apple.dt.Xcode",
        ]
        for part in parts {
            if let bundleID = knownComponents[part.lowercased()] { return bundleID }
        }
        if parts.indices.dropLast().contains(where: {
            parts[$0].caseInsensitiveCompare("Google") == .orderedSame
                && parts[$0 + 1].caseInsensitiveCompare("Chrome") == .orderedSame
        }) {
            return "com.google.Chrome"
        }
        return nil
    }

    private func appName(owner: String?, path: String) -> String {
        let names = [
            "com.todesktop.230313mzl4w4u92": "Cursor",
            "com.tinyspeck.slackmacgap": "Slack",
            "com.microsoft.teams2": "Microsoft Teams",
            "com.hnc.Discord": "Discord",
            "us.zoom.xos": "Zoom",
            "net.whatsapp.WhatsApp": "WhatsApp",
            "ru.keepcoder.Telegram": "Telegram",
            "com.spotify.client": "Spotify",
            "com.google.Chrome": "Chrome",
            "company.thebrowser.Browser": "Arc",
            "com.brave.Browser": "Brave",
            "com.microsoft.edgemac": "Edge",
            "com.anthropic.claudefordesktop": "Claude",
            "com.apple.dt.Xcode": "Xcode",
            "com.openai.chat": "ChatGPT",
            "com.raycast.macos": "Raycast",
            "desktop.WhatsApp": "WhatsApp",
            "company.thebrowser.dia": "Dia",
            "net.imput.helium": "Helium",
            "com.docker.docker": "Docker",
            "com.adguard.safari.AdGuard": "AdGuard",
        ]
        if let owner, let name = names[owner] ?? facts.appName(bundleID: owner) { return name }
        if let owner { return Self.readableName(bundleID: owner) }
        let url = URL(fileURLWithPath: path)
        return url.pathExtension.lowercased() == "app"
            ? url.deletingPathExtension().lastPathComponent
            : url.lastPathComponent
    }

    /// "com.raycast.macos" → "Raycast", "de.janbolz.silicio" → "Silicio": skip the reverse-DNS
    /// prefix and platform words, keep the product word.
    static func readableName(bundleID: String) -> String {
        let generic: Set<String> = ["com", "net", "org", "io", "co", "de", "ru", "us", "app", "apps", "desktop",
                                    "company", "macos", "mac", "osx", "client", "helper", "extension", "safari", "stable"]
        let parts = bundleID.split(separator: ".").map(String.init)
        let candidates = parts.dropFirst().filter { !generic.contains($0.lowercased()) }
        let word = candidates.last(where: { $0.count > 2 }) ?? candidates.last ?? parts.last ?? bundleID
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    private func ageInDays(since date: Date) -> Int {
        max(0, Calendar(identifier: .gregorian)
            .dateComponents([.day], from: date, to: facts.now).day ?? 0)
    }

    private func isInDownloads(_ path: String) -> Bool {
        let downloads = (home as NSString).appendingPathComponent("Downloads")
        let clean = Self.cleanPath(path)
        return clean == downloads || clean.hasPrefix(downloads + "/")
    }

    private func isAllowedApplicationCandidate(_ path: String) -> Bool {
        let clean = Self.cleanPath(path)
        let parent = URL(fileURLWithPath: clean).deletingLastPathComponent().path
        let name = URL(fileURLWithPath: clean).lastPathComponent
        guard name.lowercased().hasSuffix(".app"), !name.dropLast(4).isEmpty else {
            return false
        }
        return parent == "/Applications"
            || parent == (home as NSString).appendingPathComponent("Applications")
    }

    private func matchedInstalledAppName(forInstallerAt path: String) -> String? {
        let base = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let installerTokens = Self.nameTokens(base)
        guard !installerTokens.isEmpty else { return nil }
        return facts.installedApplicationNames
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .first { name in
                let appTokens = Self.nameTokens(name)
                return !appTokens.isEmpty && appTokens.allSatisfy(installerTokens.contains)
            }
    }

    private static func nameTokens(_ value: String) -> Set<String> {
        Set(value.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    private func isGitIgnored(_ path: String) -> Bool {
        guard let git = facts.gitState(repoContaining: path) else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", git.root, "check-ignore", "-q", "--", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func isLiveConversationDatabase(_ lowercasedName: String) -> Bool {
        let database = lowercasedName.hasSuffix(".db")
            || lowercasedName.hasSuffix(".sqlite")
            || lowercasedName.hasSuffix(".sqlite3")
        guard database else { return false }
        return ["chat", "conversation", "session"].contains {
            lowercasedName.contains($0)
        }
    }

    private func isBrowserProfile(_ relative: String) -> Bool {
        guard browserBundleID(relative) != nil else { return false }
        return relative.split(separator: "/").contains {
            $0 == "Default" || $0.hasPrefix("Profile ")
        }
    }

    private func browserBundleID(_ relative: String) -> String? {
        let browsers: [(String, String)] = [
            ("Google/Chrome", "com.google.Chrome"),
            ("Google Chrome", "com.google.Chrome"),
            ("Arc", "company.thebrowser.Browser"),
            ("BraveSoftware/Brave-Browser", "com.brave.Browser"),
            ("Microsoft Edge", "com.microsoft.edgemac"),
        ]
        return browsers.first { relative.localizedCaseInsensitiveContains($0.0) }?.1
    }

    private static func cleanPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private static func looksLikeBundleID(_ value: String) -> Bool {
        value.contains(".") && !value.contains(" ")
    }
}

private struct ConditionResult {
    var evidence: [Evidence]
    var lastUsed: LastUsed
}

private struct CompiledRule: Sendable {
    let rule: Rule
    let glob: CompiledPattern?
    let regex: CompiledPattern?
    let bundlePattern: CompiledPattern?

    init(_ rule: Rule) {
        self.rule = rule
        self.glob = rule.match.pathGlob.flatMap {
            CompiledPattern(pattern: GlobCompiler.regex(for: $0))
        }
        self.regex = rule.match.regex.flatMap(CompiledPattern.init)
        self.bundlePattern = rule.match.bundleIDPattern.flatMap {
            CompiledPattern(pattern: GlobCompiler.regex(for: $0))
        }
    }

    func pathMatches(relative: String, owner: String?) -> Bool {
        if rule.match.pathGlob != nil, glob?.matches(relative) != true { return false }
        if rule.match.regex != nil, regex?.matches(relative) != true { return false }
        if rule.match.bundleIDPattern != nil {
            guard let owner, bundlePattern?.matches(owner) == true else { return false }
        }
        return rule.match.pathGlob != nil
            || rule.match.regex != nil
            || rule.match.bundleIDPattern != nil
            || rule.match.parentMarker != nil
            || rule.match.gitignored != nil
    }
}

private final class CompiledPattern: @unchecked Sendable {
    private let expression: NSRegularExpression

    init?(pattern: String) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.expression = expression
    }

    func matches(_ value: String) -> Bool {
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range) != nil
    }
}

private enum GlobCompiler {
    static func regex(for glob: String) -> String {
        var output = "^"
        var index = glob.startIndex
        while index < glob.endIndex {
            let character = glob[index]
            if character == "*" {
                let next = glob.index(after: index)
                if next < glob.endIndex, glob[next] == "*" {
                    let afterDouble = glob.index(after: next)
                    if afterDouble < glob.endIndex, glob[afterDouble] == "/" {
                        output += "(?:.*/)?"
                        index = glob.index(after: afterDouble)
                    } else {
                        output += ".*"
                        index = afterDouble
                    }
                } else {
                    output += "[^/]*"
                    index = next
                }
            } else if character == "?" {
                output += "[^/]"
                index = glob.index(after: index)
            } else {
                output += NSRegularExpression.escapedPattern(for: String(character))
                index = glob.index(after: index)
            }
        }
        return output + "$"
    }
}

private struct ClassificationContext {
    let items: [ScannedItem]
    let home: String
    private let paths: Set<String>
    private let itemsByPath: [String: ScannedItem]

    init(items: [ScannedItem], home: String) {
        self.items = items
        self.home = home
        self.paths = Set(items.map(\.path))
        self.itemsByPath = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
    }

    func hasMarker(named marker: String, above path: String) -> Bool {
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        let homeURL = URL(fileURLWithPath: home)
        while directory.path.hasPrefix(homeURL.path) {
            let candidate = directory.appendingPathComponent(marker).path
            if paths.contains(candidate) || FileManager.default.fileExists(atPath: candidate) {
                return true
            }
            if directory.path == homeURL.path { break }
            directory.deleteLastPathComponent()
        }
        return false
    }

    func hasExpandedCopy(for compressedPath: String) -> Bool {
        guard compressedPath.hasSuffix(".zst") else { return false }
        let expanded = String(compressedPath.dropLast(4))
        if let item = itemsByPath[expanded] {
            return !item.isDirectory
        }
        guard let values = try? URL(fileURLWithPath: expanded).resourceValues(
            forKeys: [.isRegularFileKey]
        ) else {
            return false
        }
        return values.isRegularFile == true
    }

    func hasProjectMarker(above path: String) -> Bool {
        let markers = [
            "package.json", "pyproject.toml", "Package.swift", "Cargo.toml",
            "go.mod", "Podfile", "Gemfile", "composer.json",
        ]
        var directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        for _ in 0..<6 {
            guard directory.path != home, directory.path.hasPrefix(home + "/") else {
                return false
            }
            if markers.contains(where: {
                let candidate = directory.appendingPathComponent($0).path
                return paths.contains(candidate) || FileManager.default.fileExists(atPath: candidate)
            }) {
                return true
            }
            directory.deleteLastPathComponent()
        }
        return false
    }

    func oldVersionEvidence(for item: ScannedItem) -> String? {
        let itemURL = URL(fileURLWithPath: item.path)
        let versions = itemURL.deletingLastPathComponent()
        guard versions.lastPathComponent == "versions" else { return nil }

        let tool = versions.deletingLastPathComponent()
        let linkCandidates = [
            tool.appendingPathComponent("active"),
            tool.appendingPathComponent("current"),
            tool.appendingPathComponent("default"),
            versions.appendingPathComponent("active"),
            versions.appendingPathComponent("current"),
            versions.appendingPathComponent("default"),
        ]
        var activePath: String?
        for link in linkCandidates {
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else {
                continue
            }
            var resolved: URL
            if destination.hasPrefix("/") {
                resolved = URL(fileURLWithPath: destination).standardizedFileURL
            } else {
                resolved = link.deletingLastPathComponent()
                    .appendingPathComponent(destination)
                    .standardizedFileURL
            }
            for _ in 0..<8 {
                guard let next = try? FileManager.default.destinationOfSymbolicLink(
                    atPath: resolved.path
                ) else {
                    break
                }
                resolved = next.hasPrefix("/")
                    ? URL(fileURLWithPath: next).standardizedFileURL
                    : resolved.deletingLastPathComponent()
                        .appendingPathComponent(next)
                        .standardizedFileURL
            }
            activePath = resolved.path
            break
        }
        guard let activePath else { return nil }
        let versionsPath = versions.standardizedFileURL.path
        guard activePath.hasPrefix(versionsPath + "/") else { return nil }
        let activeRemainder = String(activePath.dropFirst(versionsPath.count + 1))
        guard let activeName = activeRemainder.split(separator: "/").first.map(String.init) else {
            return nil
        }
        let activeVersionPath = versions.appendingPathComponent(activeName).standardizedFileURL.path
        guard items.contains(where: {
            $0.isDirectory
                && URL(fileURLWithPath: $0.path).standardizedFileURL.path == activeVersionPath
        }) else {
            return nil
        }
        let itemPath = itemURL.standardizedFileURL.path
        if itemPath == activeVersionPath || activePath.hasPrefix(itemPath + "/") { return nil }

        let siblings = items.filter {
            $0.isDirectory
                && URL(fileURLWithPath: $0.path).deletingLastPathComponent().path == versions.path
                && URL(fileURLWithPath: $0.path).standardizedFileURL.path != activeVersionPath
        }.sorted {
            if $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.path > $1.path
        }
        guard siblings.dropFirst().contains(where: { $0.path == item.path }) else { return nil }
        return activeName
    }

    func newestProjectSource(for item: ScannedItem) -> Date? {
        let junkURL = URL(fileURLWithPath: item.path)
        let root = junkURL.deletingLastPathComponent().path
        let sourceExtensions: Set<String> = [
            "c", "cc", "cpp", "css", "go", "h", "hpp", "html", "java", "js", "jsx",
            "kt", "m", "mm", "php", "py", "rb", "rs", "swift", "ts", "tsx", "vue",
        ]
        let dates = items.compactMap { candidate -> Date? in
            guard candidate.path.hasPrefix(root + "/"), !candidate.isDirectory else { return nil }
            let relative = String(candidate.path.dropFirst(root.count + 1))
            let components = relative.split(separator: "/").map(String.init)
            if components.contains(where: Self.isJunkComponent) { return nil }
            let ext = URL(fileURLWithPath: candidate.path).pathExtension.lowercased()
            return sourceExtensions.contains(ext) ? candidate.modified : nil
        }
        return dates.max() ?? item.modified
    }

    private static func isJunkComponent(_ value: String) -> Bool {
        let exact: Set<String> = [
            "node_modules", ".venv", "venv", ".next", "__pycache__", ".turbo",
            ".pytest_cache", ".expo", "Pods", ".parcel-cache", ".svelte-kit", "build",
        ]
        return exact.contains(value) || value == "dist" || value.hasPrefix("dist-")
    }
}
