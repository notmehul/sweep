import Foundation
import SweepCore

public final class GitProbe: @unchecked Sendable {
    public let hasDeveloperTools: Bool

    private let lock = NSLock()
    private var statesByRoot: [String: GitState] = [:]

    public init() {
        self.hasDeveloperTools = Self.detectDeveloperTools()
    }

    public func gitState(repoContaining path: String) -> GitState? {
        guard hasDeveloperTools, let root = Self.repositoryRoot(containing: path) else {
            return nil
        }

        lock.lock()
        if let cached = statesByRoot[root] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let status = Self.runGit(["-C", root, "status", "--porcelain"]),
              let remotes = Self.runGit(["-C", root, "remote"])
        else {
            return nil
        }
        let timestamp = Self.runGit(["-C", root, "log", "-1", "--format=%ct"])
            .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map(Date.init(timeIntervalSince1970:))
        let state = GitState(
            root: root,
            isDirty: !status.isEmpty,
            hasRemote: !remotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            lastCommit: timestamp
        )

        lock.lock()
        statesByRoot[root] = state
        lock.unlock()
        return state
    }

    private static func detectDeveloperTools() -> Bool {
        guard let selected = run(
            executable: "/usr/bin/xcode-select",
            arguments: ["-p"]
        ), selected.status == 0 else {
            return false
        }
        let developerDirectory = selected.output.trimmingCharacters(in: .whitespacesAndNewlines)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: developerDirectory,
            isDirectory: &isDirectory
        ), isDirectory.boolValue,
            FileManager.default.isExecutableFile(atPath: "/usr/bin/git")
        else {
            return false
        }

        // This is safe only after a real selected developer directory was verified. Without
        // that guard, /usr/bin/git can display macOS's Command Line Tools installer dialog.
        return run(executable: "/usr/bin/git", arguments: ["--version"])?.status == 0
    }

    private static func repositoryRoot(containing path: String) -> String? {
        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        var current = URL(fileURLWithPath: path).standardizedFileURL
        if fileManager.fileExists(atPath: current.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            current.deleteLastPathComponent()
        }

        while true {
            if fileManager.fileExists(atPath: current.appendingPathComponent(".git").path) {
                return current.path
            }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { return nil }
            current = parent
        }
    }

    private static func runGit(_ arguments: [String]) -> String? {
        guard let result = run(executable: "/usr/bin/git", arguments: arguments),
              result.status == 0
        else {
            return nil
        }
        return result.output
    }

    private struct ProcessResult {
        let status: Int32
        let output: String
    }

    private static func run(executable: String, arguments: [String]) -> ProcessResult? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = Pipe()
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return ProcessResult(
                status: process.terminationStatus,
                output: String(decoding: data, as: UTF8.self)
            )
        } catch {
            return nil
        }
    }
}
