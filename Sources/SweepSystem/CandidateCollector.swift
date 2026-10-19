import Darwin
import Foundation
import SweepCore

/// Machine facts used by candidate sources that sit outside the main walker.
public protocol CandidateCollectionFacts: SystemFacts {
    var installedApplications: [InstalledApplication] { get }
    func downloadsNeverOpened(home: String) -> [String: Date?]
    func screenshotCandidates(home: String) -> [String: Date?]
    func bigStaleCandidates(home: String, minBytes: Int64, olderThanDays: Int) -> [String: Date?]
}

public extension CandidateCollectionFacts {
    var installedApplications: [InstalledApplication] { [] }
    func downloadsNeverOpened(home: String) -> [String: Date?] { [:] }
    func screenshotCandidates(home: String) -> [String: Date?] { [:] }
    func bigStaleCandidates(home: String, minBytes: Int64, olderThanDays: Int) -> [String: Date?] {
        [:]
    }
}

public struct Candidates: Sendable {
    public var extraItems: [ScannedItem]
    public var duplicateGroups: [[ScannedItem]]

    public init(extraItems: [ScannedItem], duplicateGroups: [[ScannedItem]]) {
        self.extraItems = extraItems
        self.duplicateGroups = duplicateGroups
    }
}

/// Collects bounded, metadata-only candidates that the size walker intentionally omits.
public struct CandidateCollector: Sendable {
    private static let duplicateMinimumSize: Int64 = 1_048_576
    private static let bigFileMinimumSize: Int64 = 500 * 1_024 * 1_024
    private static let maximumDuplicateFiles = 20_000
    private static let maximumDepth = 4

    public init() {}

    public func collect(
        home: String,
        facts: any CandidateCollectionFacts,
        walkerItems: [ScannedItem]
    ) async -> Candidates {
        let homePath = canonical(home)
        let walkerPaths = Set(walkerItems.map { canonical($0.path) })
        var extraByPath: [String: ScannedItem] = [:]

        for application in facts.installedApplications {
            guard isAllowedApplication(application.path, home: homePath),
                  let item = applicationItem(application, facts: facts)
            else {
                continue
            }
            insert(item, excluding: walkerPaths, into: &extraByPath)
        }

        let downloads = canonical((homePath as NSString).appendingPathComponent("Downloads"))
        for path in facts.downloadsNeverOpened(home: homePath).keys
        where isInside(canonical(path), directory: downloads) {
            if let item = fileItem(at: path) {
                insert(item, excluding: walkerPaths, into: &extraByPath)
            }
        }

        for path in facts.screenshotCandidates(home: homePath).keys
        where isInsideHome(canonical(path), home: homePath) {
            if let item = fileItem(at: path) {
                insert(item, excluding: walkerPaths, into: &extraByPath)
            }
        }

        for path in facts.bigStaleCandidates(
            home: homePath,
            minBytes: Self.bigFileMinimumSize,
            olderThanDays: 365
        ).keys where isInsideHome(canonical(path), home: homePath) {
            if let item = fileItem(at: path),
               item.logicalSize >= Self.bigFileMinimumSize {
                insert(item, excluding: walkerPaths, into: &extraByPath)
            }
        }

        let bounded = boundedPersonalScan(home: homePath)
        for item in bounded.secretItems + bounded.screenshotItems {
            insert(item, excluding: walkerPaths, into: &extraByPath)
        }

        let duplicateGroups = await findDuplicates(bounded.duplicateItems)
        return Candidates(
            extraItems: extraByPath.values.sorted { $0.path < $1.path },
            duplicateGroups: duplicateGroups
        )
    }

    private func boundedPersonalScan(home: String) -> PersonalScan {
        let names = ["Desktop", "Documents", "Downloads", "Pictures", "Movies"]
        let duplicateRoots = Set(["Desktop", "Documents", "Downloads"])
        var secrets: [ScannedItem] = []
        var screenshots: [ScannedItem] = []
        var duplicates: [ScannedItem] = []

        for rootName in names {
            guard !Task.isCancelled else { break }
            let root = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(rootName, isDirectory: true)
            let keys: [URLResourceKey] = [
                .isDirectoryKey, .isRegularFileKey, .isPackageKey, .fileSizeKey,
                .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
            ]
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: keys,
                options: [],
                errorHandler: { _, _ in true }
            ) else {
                continue
            }

            while let url = enumerator.nextObject() as? URL {
                guard !Task.isCancelled else { break }
                let depth = url.pathComponents.count - root.pathComponents.count
                guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                    if depth <= Self.maximumDepth { enumerator.skipDescendants() }
                    continue
                }
                if values.isDirectory == true {
                    if values.isPackage == true || Self.isDeveloperJunk(url.lastPathComponent) {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                guard values.isRegularFile == true, let item = fileItem(at: url.path) else {
                    continue
                }

                if depth <= Self.maximumDepth,
                   ["Desktop", "Documents", "Downloads"].contains(rootName),
                   Self.isSecretLooking(url.lastPathComponent) {
                    secrets.append(item)
                }
                if Self.isScreenshotOrRecording(url.lastPathComponent) {
                    screenshots.append(item)
                }
                if duplicateRoots.contains(rootName),
                   item.logicalSize >= Self.duplicateMinimumSize,
                   duplicates.count < Self.maximumDuplicateFiles {
                    duplicates.append(item)
                }
            }
        }
        return PersonalScan(
            secretItems: secrets,
            screenshotItems: screenshots,
            duplicateItems: duplicates
        )
    }

    private func applicationItem(
        _ application: InstalledApplication,
        facts: any CandidateCollectionFacts
    ) -> ScannedItem? {
        guard var item = fileItem(at: application.path, directorySize: application.allocatedSize) else {
            return nil
        }
        item.modified = application.lastUsed
            ?? facts.lastOpened(path: application.path)
            ?? application.dateAdded
            ?? facts.dateAdded(path: application.path)
            ?? item.modified
        return item
    }

    private func fileItem(at path: String, directorySize: Int64? = nil) -> ScannedItem? {
        var status = stat()
        guard lstat(path, &status) == 0,
              status.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK),
              status.st_flags & UInt32(SF_DATALESS) == 0
        else {
            return nil
        }
        let isDirectory = status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
        let url = URL(fileURLWithPath: path)
        let values = try? url.resourceValues(forKeys: [
            .fileSizeKey, .fileAllocatedSizeKey, .totalFileAllocatedSizeKey,
        ])
        let logical = directorySize ?? Int64(values?.fileSize ?? Int(status.st_size))
        let allocated = directorySize
            ?? Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? Int(status.st_blocks * 512))
        return ScannedItem(
            path: canonical(path),
            isDirectory: isDirectory,
            logicalSize: max(0, logical),
            allocatedSize: max(0, allocated),
            reclaimableSize: max(0, allocated),
            fileCount: 1,
            fileID: UInt64(status.st_ino),
            device: Int32(status.st_dev),
            modified: Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
        )
    }

    private func insert(
        _ item: ScannedItem,
        excluding walkerPaths: Set<String>,
        into items: inout [String: ScannedItem]
    ) {
        let path = canonical(item.path)
        guard !walkerPaths.contains(path) else { return }
        items[path] = item
    }

    private func isAllowedApplication(_ path: String, home: String) -> Bool {
        let clean = canonical(path)
        let url = URL(fileURLWithPath: clean)
        guard url.pathExtension.lowercased() == "app" else { return false }
        let parent = url.deletingLastPathComponent().path
        return parent == "/Applications"
            || parent == (home as NSString).appendingPathComponent("Applications")
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }

    private func isInsideHome(_ path: String, home: String) -> Bool {
        path == home || isInside(path, directory: home)
    }

    private func isInside(_ path: String, directory: String) -> Bool {
        path.hasPrefix(directory + "/")
    }

    private static func isDeveloperJunk(_ name: String) -> Bool {
        let exact: Set<String> = [
            ".git", "node_modules", ".venv", "venv", ".next", "__pycache__",
            ".turbo", ".pytest_cache", ".expo", "Pods", ".parcel-cache",
            ".svelte-kit", "build",
        ]
        return exact.contains(name) || name == "dist" || name.hasPrefix("dist-")
    }

    private static func isScreenshotOrRecording(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasPrefix("screenshot")
            || lower.hasPrefix("screen shot")
            || lower.hasPrefix("screen recording")
    }

    private static func isSecretLooking(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == "id_rsa" || lower == "id_ed25519" || lower == ".env" {
            return true
        }
        if lower.hasSuffix(".pem") || lower.hasSuffix(".p12") {
            return true
        }
        let recovery = lower.replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        if recovery.hasPrefix("recovery-code") || recovery.hasPrefix("recovery-codes") {
            return true
        }
        return lower.contains("apikey")
            || lower.contains("api-key")
            || lower.contains("api_keys")
            || lower.contains("secret")
    }
}

private struct PersonalScan {
    var secretItems: [ScannedItem]
    var screenshotItems: [ScannedItem]
    var duplicateItems: [ScannedItem]
}
