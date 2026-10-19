import Foundation

public struct VolumeInfo: Sendable, Hashable {
    public var usedBytes: Int64
    public var freeBytes: Int64
    public var purgeableBytes: Int64
    public var localSnapshotNames: [String]

    public init(
        usedBytes: Int64,
        freeBytes: Int64,
        purgeableBytes: Int64,
        localSnapshotNames: [String]
    ) {
        self.usedBytes = usedBytes
        self.freeBytes = freeBytes
        self.purgeableBytes = purgeableBytes
        self.localSnapshotNames = localSnapshotNames
    }

    public static func home(url: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> VolumeInfo {
        let values = try url.resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = Int64(values.volumeAvailableCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage ?? free
        return VolumeInfo(
            usedBytes: max(0, total - free),
            freeBytes: max(0, free),
            purgeableBytes: max(0, important - free),
            localSnapshotNames: localSnapshots()
        )
    }

    private static func localSnapshots() -> [String] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", "/"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            return text.split(whereSeparator: \.isNewline).compactMap { line in
                let value = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                if let colon = value.firstIndex(of: ":") {
                    let name = value[value.index(after: colon)...]
                        .trimmingCharacters(in: .whitespaces)
                    return name.isEmpty ? nil : name
                }
                return value.hasPrefix("com.apple.") ? value : nil
            }
        } catch {
            return []
        }
    }
}
