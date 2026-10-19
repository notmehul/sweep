import AppKit
import Foundation

public struct InstalledApplication: Sendable, Hashable, Codable {
    public let path: String
    public let bundleID: String?
    public let displayName: String
    public let allocatedSize: Int64
    public let lastUsed: Date?
    public let dateAdded: Date?

    public init(
        path: String,
        bundleID: String?,
        displayName: String,
        allocatedSize: Int64,
        lastUsed: Date?,
        dateAdded: Date?
    ) {
        self.path = path
        self.bundleID = bundleID
        self.displayName = displayName
        self.allocatedSize = allocatedSize
        self.lastUsed = lastUsed
        self.dateAdded = dateAdded
    }
}

/// Reads application bundles as files. It never asks Launch Services to open or register one.
public struct InstalledApps: Sendable {
    public let roots: [URL]
    private let spotlight: Spotlight

    public init(roots: [URL], spotlight: Spotlight = Spotlight()) {
        self.roots = roots
        self.spotlight = spotlight
    }

    public init(homeDirectory: String = NSHomeDirectory(), spotlight: Spotlight = Spotlight()) {
        self.init(roots: Self.defaultRoots(homeDirectory: homeDirectory), spotlight: spotlight)
    }

    public static func defaultRoots(homeDirectory: String = NSHomeDirectory()) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/Applications/Utilities", isDirectory: true),
            URL(fileURLWithPath: homeDirectory, isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        ]
    }

    public func scan() -> [InstalledApplication] {
        let fileManager = FileManager.default
        var seen = Set<String>()
        var applications: [InstalledApplication] = []

        for root in roots {
            guard let children = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            // Some installers wrap the app in a localized folder (/Applications/WhatsApp.localized/).
            let wrapped = children.filter { $0.pathExtension.lowercased() == "localized" }.flatMap {
                (try? fileManager.contentsOfDirectory(at: $0, includingPropertiesForKeys: [.isDirectoryKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            }
            for child in children + wrapped where child.pathExtension.lowercased() == "app" {
                let path = child.standardizedFileURL.path
                guard seen.insert(path).inserted,
                      let values = try? child.resourceValues(forKeys: [.isDirectoryKey]),
                      values.isDirectory == true
                else {
                    continue
                }

                let info = Self.infoPlist(at: child)
                let bundleID = info?["CFBundleIdentifier"] as? String
                let displayName = Self.cleanName((info?["CFBundleDisplayName"] as? String)
                    ?? (info?["CFBundleName"] as? String)
                    ?? child.deletingPathExtension().lastPathComponent)
                applications.append(
                    InstalledApplication(
                        path: path,
                        bundleID: bundleID,
                        displayName: displayName,
                        allocatedSize: Self.allocatedSize(of: child),
                        lastUsed: spotlight.lastOpened(path: path),
                        dateAdded: spotlight.dateAdded(path: path)
                    )
                )
            }
        }

        return applications.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }
    }

    /// Some apps ship names with invisible direction marks (WhatsApp's is "\u{200E}WhatsApp").
    static func cleanName(_ name: String) -> String {
        String(String.UnicodeScalarView(name.unicodeScalars.filter { $0.properties.generalCategory != .format }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func infoPlist(at application: URL) -> [String: Any]? {
        let url = application.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: url),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        else {
            return nil
        }
        return plist as? [String: Any]
    }

    private static func allocatedSize(of application: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .totalFileAllocatedSizeKey,
            .fileAllocatedSizeKey,
        ]
        guard let enumerator = FileManager.default.enumerator(
            at: application,
            includingPropertiesForKeys: Array(keys),
            options: [],
            errorHandler: { _, _ in true }
        ) else {
            return 0
        }

        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true
            else {
                continue
            }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

public enum RunningApps {
    public static func bundleIDs() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    public static func localizedNames() -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.localizedName))
    }
}
