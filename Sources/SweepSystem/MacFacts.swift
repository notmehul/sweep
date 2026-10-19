import Foundation
import SweepCore

/// One immutable machine snapshot for one scan. The adapters it owns cache metadata lookups
/// behind locks, while installed and running application sets never change during the scan.
public final class MacFacts: SystemFacts, @unchecked Sendable {
    public let homeDirectory: String
    public let now: Date
    public let installedApplications: [InstalledApplication]
    public let spotlightWorks: Bool
    public let persona: Persona

    private let installedBundleIDs: Set<String>
    private let runningBundleIDs: Set<String>
    private let spotlight: Spotlight
    private let gitProbe: GitProbe

    public var hasDeveloperTools: Bool { persona.isDeveloper }

    public init(
        homeDirectory: String = NSHomeDirectory(),
        now: Date = Date(),
        applicationRoots: [URL]? = nil,
        spotlight: Spotlight = Spotlight(),
        gitProbe: GitProbe = GitProbe(),
        runningBundleIDs: Set<String>? = nil
    ) {
        self.homeDirectory = homeDirectory
        self.now = now
        self.spotlight = spotlight
        self.gitProbe = gitProbe

        let roots = applicationRoots ?? InstalledApps.defaultRoots(homeDirectory: homeDirectory)
        let applications = InstalledApps(roots: roots, spotlight: spotlight).scan()
        self.installedApplications = applications
        self.installedBundleIDs = Set(applications.compactMap(\.bundleID))
        self.runningBundleIDs = runningBundleIDs ?? RunningApps.bundleIDs()
        self.spotlightWorks = spotlight.spotlightWorks
        self.persona = Persona(
            homeDirectory: homeDirectory,
            hasCommandLineTools: gitProbe.hasDeveloperTools
        )
    }

    public func isInstalled(bundleID: String) -> Bool {
        installedBundleIDs.contains(bundleID)
    }

    public func isRunning(bundleID: String) -> Bool {
        runningBundleIDs.contains(bundleID)
    }

    public func lastOpened(path: String) -> Date? {
        spotlight.lastOpened(path: path)
    }

    public func gitState(repoContaining path: String) -> GitState? {
        gitProbe.gitState(repoContaining: path)
    }
}
