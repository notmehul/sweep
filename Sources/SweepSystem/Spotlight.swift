import CoreServices
import Foundation

/// Scoped access to Spotlight metadata. Every query has a fixed deadline and runs away
/// from the caller's thread because MDQuery's synchronous mode pumps its own run loop.
public final class Spotlight: @unchecked Sendable {
    private enum CachedDate {
        case value(Date?)
    }

    private let timeout: TimeInterval
    private let applicationScope: String
    private let lock = NSLock()
    private var probeResult: Bool?
    private var lastOpenedCache: [String: CachedDate] = [:]
    private var dateAddedCache: [String: CachedDate] = [:]

    public init(timeout: TimeInterval = 3, applicationScope: String = "/Applications") {
        self.timeout = timeout
        self.applicationScope = applicationScope
    }

    public var spotlightWorks: Bool {
        lock.lock()
        if let probeResult {
            lock.unlock()
            return probeResult
        }
        lock.unlock()

        let expression = "kMDItemContentTypeTree == 'com.apple.application-bundle'"
        let works = runQuery(expression: expression, scopes: [applicationScope], timeout: 3)?
            .isEmpty == false

        lock.lock()
        probeResult = works
        lock.unlock()
        return works
    }

    /// The actual last-used date. Date-added is intentionally not used as a fallback.
    public func lastOpened(path: String) -> Date? {
        cachedDate(path: path, cache: \.lastOpenedCache, attribute: kMDItemLastUsedDate)
    }

    public func dateAdded(path: String) -> Date? {
        cachedDate(path: path, cache: \.dateAddedCache, attribute: kMDItemDateAdded)
    }

    /// Files directly indexed under Downloads that have no recorded last-used date.
    public func downloadsNeverOpened(home: String = NSHomeDirectory()) -> [String: Date?] {
        let downloads = URL(fileURLWithPath: home).appendingPathComponent("Downloads").path
        guard let rows = runQuery(
            expression: "kMDItemFSName == '*'cd",
            scopes: [downloads],
            timeout: timeout
        ) else {
            return [:]
        }

        var result: [String: Date?] = [:]
        for row in rows where row.lastUsed == nil {
            result.updateValue(nil, forKey: row.path)
        }
        return result
    }

    /// Large files whose last-used date is older than the requested age.
    public func bigStaleFiles(
        home: String = NSHomeDirectory(),
        minBytes: Int64,
        olderThanDays: Int,
        now: Date = Date()
    ) -> [String: Date?] {
        let expression = "kMDItemFSSize >= \(max(0, minBytes))"
        guard let rows = runQuery(expression: expression, scopes: [home], timeout: timeout) else {
            return [:]
        }

        let cutoff = now.addingTimeInterval(-Double(max(0, olderThanDays)) * 86_400)
        var result: [String: Date?] = [:]
        for row in rows {
            guard let lastUsed = row.lastUsed, lastUsed < cutoff else { continue }
            result.updateValue(lastUsed, forKey: row.path)
        }
        return result
    }

    public func screenshots(home: String = NSHomeDirectory()) -> [String: Date?] {
        guard let rows = runQuery(
            expression: "kMDItemIsScreenCapture == 1",
            scopes: [home],
            timeout: timeout
        ) else {
            return [:]
        }

        var result: [String: Date?] = [:]
        for row in rows {
            result.updateValue(row.lastUsed, forKey: row.path)
        }
        return result
    }

    private func cachedDate(
        path: String,
        cache keyPath: ReferenceWritableKeyPath<Spotlight, [String: CachedDate]>,
        attribute: CFString
    ) -> Date? {
        lock.lock()
        if case let .value(value)? = self[keyPath: keyPath][path] {
            lock.unlock()
            return value
        }
        lock.unlock()

        let value = Self.itemDate(path: path, attribute: attribute)
        lock.lock()
        self[keyPath: keyPath][path] = .value(value)
        lock.unlock()
        return value
    }

    private static func itemDate(path: String, attribute: CFString) -> Date? {
        guard let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, attribute)
        else {
            return nil
        }
        return value as? Date
    }

    private struct QueryRow: Sendable {
        let path: String
        let lastUsed: Date?
    }

    private func runQuery(
        expression: String,
        scopes: [String],
        timeout: TimeInterval
    ) -> [QueryRow]? {
        Self.withTimeout(timeout) { () -> [QueryRow]? in
            guard let query = MDQueryCreate(
                kCFAllocatorDefault,
                expression as CFString,
                nil,
                nil
            ) else {
                return nil
            }
            MDQuerySetSearchScope(query, scopes as CFArray, 0)
            guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else {
                return nil
            }
            defer { MDQueryStop(query) }

            var rows: [QueryRow] = []
            rows.reserveCapacity(MDQueryGetResultCount(query))
            for index in 0..<MDQueryGetResultCount(query) {
                guard let pointer = MDQueryGetResultAtIndex(query, index) else { continue }
                let item = Unmanaged<MDItem>.fromOpaque(pointer).takeUnretainedValue()
                guard let pathValue = MDItemCopyAttribute(item, kMDItemPath),
                      let path = pathValue as? String
                else {
                    continue
                }
                let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
                rows.append(QueryRow(path: path, lastUsed: lastUsed))
            }
            return rows
        } ?? nil
    }

    private final class ResultBox<Value: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value?

        func store(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }

        func load() -> Value? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static func withTimeout<Value: Sendable>(
        _ timeout: TimeInterval,
        operation: @escaping @Sendable () -> Value
    ) -> Value? {
        let box = ResultBox<Value>()
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.store(operation())
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        return box.load()
    }
}
