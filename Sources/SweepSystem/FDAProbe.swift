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
