import Foundation

public enum ScanReportRedactor {
    /// Keeps recognizable Library locations while removing names that can identify a person
    /// or one of their files.
    public static func redact(
        path: String,
        isDirectory: Bool? = nil,
        home: String = NSHomeDirectory()
    ) -> String {
        guard let components = componentsInsideHome(path: path, home: home) else {
            return "<file>"
        }
        guard let first = components.first else { return "~" }

        if ["Desktop", "Documents", "Downloads", "Dev"].contains(first) {
            return "~/\(first)/<file>"
        }
        guard first == "Library" else { return "~/<file>" }
        guard components.count > 1 else { return "~/Library" }

        let category = components[1]
        let appCategories = [
            "Application Scripts", "Application Support", "Caches", "Containers",
            "Group Containers", "HTTPStorages", "Logs", "Preferences",
            "Saved Application State", "WebKit",
        ]
        guard appCategories.contains(category) else { return "~/Library/<file>" }
        guard components.count > 2 else { return "~/Library/\(category)" }
        if components.count == 3 && isDirectory == false {
            return "~/Library/\(category)/<file>"
        }

        let prefix = "~/Library/\(category)/\(components[2])"
        return components.count > 3 ? prefix + "/<file>" : prefix
    }

    private static func componentsInsideHome(path: String, home: String) -> [String]? {
        if path == "~" { return [] }
        if path.hasPrefix("~/") {
            return String(path.dropFirst(2)).split(separator: "/").map(String.init)
        }

        let normalizedHome = URL(fileURLWithPath: home).standardizedFileURL.path
        let normalizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        guard normalizedPath == normalizedHome || normalizedPath.hasPrefix(normalizedHome + "/") else {
            return nil
        }
        let relative = normalizedPath.dropFirst(normalizedHome.count).drop(while: { $0 == "/" })
        return relative.split(separator: "/").map(String.init)
    }
}
