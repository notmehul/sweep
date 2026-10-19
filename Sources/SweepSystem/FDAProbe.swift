import Foundation

/// Detects Full Disk Access by trying to list a folder only FDA can read.
public enum FDAProbe {
    public static func hasFullDiskAccess(home: String = NSHomeDirectory()) -> Bool {
        for protected in ["Library/Safari", "Library/Mail", "Library/Messages"] {
            let path = (home as NSString).appendingPathComponent(protected)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            return (try? FileManager.default.contentsOfDirectory(atPath: path)) != nil
        }
        // None of the probe folders exist; TCC.db is readable only with FDA.
        return FileManager.default.isReadableFile(atPath: (home as NSString)
            .appendingPathComponent("Library/Application Support/com.apple.TCC/TCC.db"))
    }
}

extension FDAProbe {
    /// Folders that macOS guards with privacy prompts. Without Full Disk Access the scan leaves
    /// them closed, so a friend never sees a wall of "Sweep would like to access…" dialogs.
    public static func protectedFolders(home: String = NSHomeDirectory()) -> Set<String> {
        let relative = [
            "Library/Containers", "Library/Group Containers", "Library/Mail", "Library/Messages",
            "Library/Safari", "Library/Cookies", "Library/HomeKit", "Library/IdentityServices",
            "Library/Calendars", "Library/Suggestions", "Library/Metadata/CoreSpotlight",
            "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
            "Library/Application Support/com.apple.TCC", "Library/Biome", "Library/Accounts",
            "Library/Autosave Information", "Library/Daemon Containers",
            "Pictures/Photos Library.photoslibrary",
        ]
        return Set(relative.map { (home as NSString).appendingPathComponent($0) })
    }
}
