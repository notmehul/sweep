import Foundation

public struct Persona: Sendable, Hashable, Codable {
    public let hasXcode: Bool
    public let hasHomebrew: Bool
    public let hasNode: Bool
    public let hasNPMDirectory: Bool
    public let hasCommandLineTools: Bool

    public var isDeveloper: Bool {
        hasXcode || hasHomebrew || hasNode || hasNPMDirectory || hasCommandLineTools
    }

    public init(
        homeDirectory: String = NSHomeDirectory(),
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "",
        xcodePath: String = "/Applications/Xcode.app",
        homebrewPath: String = "/opt/homebrew",
        hasCommandLineTools: Bool
    ) {
        let fileManager = FileManager.default
        self.hasXcode = fileManager.fileExists(atPath: xcodePath)
        self.hasHomebrew = fileManager.fileExists(atPath: homebrewPath)
        self.hasNode = path.split(separator: ":").contains { directory in
            let root = String(directory)
            return fileManager.isExecutableFile(
                atPath: URL(fileURLWithPath: root).appendingPathComponent("node").path
            ) || fileManager.isExecutableFile(
                atPath: URL(fileURLWithPath: root).appendingPathComponent("npm").path
            )
        }
        self.hasNPMDirectory = fileManager.fileExists(
            atPath: URL(fileURLWithPath: homeDirectory).appendingPathComponent(".npm").path
        )
        self.hasCommandLineTools = hasCommandLineTools
    }
}
