import AppKit
import Foundation
import SweepCore

/// One immutable machine snapshot for one scan. The adapters it owns cache metadata lookups
/// behind locks, while installed and running application sets never change during the scan.
public final class MacFacts: SystemFacts, CandidateCollectionFacts, @unchecked Sendable {
    public let homeDirectory: String
    public let now: Date
    public let installedApplications: [InstalledApplication]
    public let spotlightWorks: Bool
    public let persona: Persona

    private let installedBundleIDs: Set<String>
    private let applicationsByPath: [String: InstalledApplication]
    private let runningBundleIDs: Set<String>
    private let runningApplicationNames: Set<String>
    private let applicationURLResolver: (String) -> URL?
    private let spotlight: Spotlight
    private let gitProbe: GitProbe
    private let extensionRegistry = ExtensionRegistry()

    public var hasDeveloperTools: Bool { persona.isDeveloper }
    public var installedApplicationNames: [String] {
        installedApplications.map(\.displayName)
    }

    public func appName(bundleID: String) -> String? {
        if let app = installedApplications.first(where: { $0.bundleID == bundleID }) { return app.displayName }
        guard let url = applicationURLResolver(bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

    public init(
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date(),
        applicationRoots: [URL]? = nil,
        spotlight: Spotlight = Spotlight(),
        gitProbe: GitProbe = GitProbe(),
        runningBundleIDs: Set<String>? = nil,
        runningApplicationNames: Set<String>? = nil,
        applicationURLResolver: ((String) -> URL?)? = nil,
        measureApplicationSizes: Bool = true
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.spotlight = spotlight
        self.gitProbe = gitProbe

        let roots = applicationRoots ?? InstalledApps.defaultRoots(homeDirectory: homeDirectory)
        let applications = InstalledApps(roots: roots, spotlight: spotlight).scan(measureSizes: measureApplicationSizes)
        self.installedApplications = applications
        self.installedBundleIDs = Set(applications.compactMap(\.bundleID))
        self.applicationsByPath = Dictionary(
            applications.map {
                (URL(fileURLWithPath: $0.path).standardizedFileURL.path, $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        self.runningBundleIDs = runningBundleIDs ?? RunningApps.bundleIDs()
        self.runningApplicationNames = runningApplicationNames
            ?? (runningBundleIDs == nil ? RunningApps.localizedNames() : [])
        self.applicationURLResolver = applicationURLResolver ?? {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0)
        }
        self.spotlightWorks = spotlight.spotlightWorks
        self.persona = Persona(
            homeDirectory: homeDirectory,
            hasCommandLineTools: gitProbe.hasDeveloperTools
        )
    }

    public func isInstalled(bundleID: String) -> Bool {
        installedBundleIDs.contains(bundleID)
            || runningBundleIDs.contains(bundleID)
            || applicationURLResolver(bundleID) != nil
            || installedBundleIDs.contains { bundleID.hasPrefix($0 + ".") }
            || extensionRegistry.isRegistered(bundleID)
    }

    public func isRunning(bundleID: String) -> Bool {
        runningBundleIDs.contains(bundleID)
    }

    public func isRunning(appNamed name: String) -> Bool {
        runningApplicationNames.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    public func bundleIdentifier(forApplicationAt path: String) -> String? {
        applicationsByPath[URL(fileURLWithPath: path).standardizedFileURL.path]?.bundleID
    }

    public func lastOpened(path: String) -> Date? {
        spotlight.lastOpened(path: path)
    }

    public func dateAdded(path: String) -> Date? {
        spotlight.dateAdded(path: path)
    }

    public func downloadsNeverOpened(home: String) -> [String: Date?] {
        spotlight.downloadsNeverOpened(home: home)
    }

    public func screenshotCandidates(home: String) -> [String: Date?] {
        spotlight.screenshots(home: home)
    }

    public func bigStaleCandidates(
        home: String,
        minBytes: Int64,
        olderThanDays: Int
    ) -> [String: Date?] {
        spotlight.bigStaleFiles(
            home: home,
            minBytes: minBytes,
            olderThanDays: olderThanDays,
            now: now
        )
    }

    public func gitState(repoContaining path: String) -> GitState? {
        gitProbe.gitState(repoContaining: path)
    }
}

/// App extensions (Intents, Share, Safari extensions) keep their own data folders under their
/// own IDs. `pluginkit` knows which ones are installed, so their folders aren't "leftovers".
final class ExtensionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: Bool] = [:]

    func isRegistered(_ bundleID: String) -> Bool {
        lock.lock(); if let known = cache[bundleID] { lock.unlock(); return known }; lock.unlock()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        process.arguments = ["-m", "-i", bundleID]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        var found = false
        if (try? process.run()) != nil {
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            found = String(decoding: output, as: UTF8.self).contains(bundleID)
        }
        lock.lock(); cache[bundleID] = found; lock.unlock()
        return found
    }
}
