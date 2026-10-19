import Foundation

/// Bundled cleanup rules. Rules ship inside the app and are never fetched at runtime.
public enum RuleCatalog {
    public static var directory: URL? { Bundle.module.url(forResource: "rules", withExtension: nil) }
}
