import Darwin
import Foundation
import SweepCore

public struct ToolCommandResult: Sendable, Hashable {
    public var succeeded: Bool
    public var reason: String?

    public init(succeeded: Bool, reason: String? = nil) {
        self.succeeded = succeeded
        self.reason = reason
    }
}

public struct ToolCommandInvocation: Sendable, Hashable {
    public var executable: URL
    public var arguments: [String]

    public init(executable: URL, arguments: [String]) {
        self.executable = executable
        self.arguments = arguments
    }
}

public struct ToolCommands: Sendable {
    private let executables: [ToolCommand: URL]

    /// Passing a dictionary, including an empty one, disables automatic discovery.
    public init(availableExecutables: [ToolCommand: URL]? = nil) {
        executables = availableExecutables ?? Self.discoverExecutables()
    }

    public func invocation(
        for command: ToolCommand,
        itemPaths: [String]
    ) -> Result<ToolCommandInvocation, ToolCommandResult> {
        guard let executable = executables[command] else {
            return .failure(ToolCommandResult(
                succeeded: false,
                reason: "\(displayName(for: command)) isn't installed, so Sweep skipped this item."
            ))
        }

        let arguments: [String]
        switch command {
        case .simctlRuntimeDelete:
            guard !itemPaths.isEmpty else {
                return .failure(ToolCommandResult(
                    succeeded: false,
                    reason: "Sweep couldn't identify the Simulator runtime to remove."
                ))
            }
            if executable.lastPathComponent == "xcrun" {
                arguments = ["simctl", "runtime", "delete"] + itemPaths
            } else {
                arguments = ["runtime", "delete"] + itemPaths
            }
        case .brewCleanup:
            arguments = ["cleanup"]
        case .npmCacheClean:
            arguments = ["cache", "clean", "--force"]
        case .uvCacheClean:
            arguments = ["cache", "clean"]
        case .bunCacheRm:
            arguments = ["pm", "cache", "rm"]
        }
        return .success(ToolCommandInvocation(executable: executable, arguments: arguments))
    }

    public func run(
        _ command: ToolCommand,
        itemPaths: [String],
        timeout: TimeInterval = 120
    ) async -> ToolCommandResult {
        switch invocation(for: command, itemPaths: itemPaths) {
        case .failure(let result):
            return result
        case .success(let invocation):
            return await Task.detached(priority: .utility) {
                runProcess(invocation, timeout: timeout)
            }.value
        }
    }

    private func displayName(for command: ToolCommand) -> String {
        switch command {
        case .simctlRuntimeDelete: "Simulator tools"
        case .brewCleanup: "Homebrew"
        case .npmCacheClean: "npm"
        case .uvCacheClean: "uv"
        case .bunCacheRm: "Bun"
        }
    }

    private static func discoverExecutables() -> [ToolCommand: URL] {
        var found: [ToolCommand: URL] = [:]
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let pathDirectories = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":").map(String.init) ?? []

        func firstExecutable(_ paths: [String]) -> URL? {
            for path in paths where FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
            return nil
        }

        found[.simctlRuntimeDelete] = firstExecutable([
            "/Library/Developer/PrivateFrameworks/CoreSimulator.framework/Versions/A/Resources/bin/simctl",
            "/usr/bin/xcrun",
        ])
        found[.brewCleanup] = firstExecutable([
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
        ])
        found[.npmCacheClean] = firstExecutable(
            ["/opt/homebrew/bin/npm", "/usr/local/bin/npm", "/usr/bin/npm"]
                + pathDirectories.map { ($0 as NSString).appendingPathComponent("npm") }
        )
        found[.uvCacheClean] = firstExecutable(
            [home + "/.local/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
                + pathDirectories.map { ($0 as NSString).appendingPathComponent("uv") }
        )
        found[.bunCacheRm] = firstExecutable(
            [home + "/.bun/bin/bun", "/opt/homebrew/bin/bun", "/usr/local/bin/bun"]
                + pathDirectories.map { ($0 as NSString).appendingPathComponent("bun") }
        )
        return found
    }
}

private func runProcess(
    _ invocation: ToolCommandInvocation,
    timeout: TimeInterval
) -> ToolCommandResult {
    let process = Process()
    process.executableURL = invocation.executable
    process.arguments = invocation.arguments
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    let finished = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in finished.signal() }
    do {
        try process.run()
    } catch {
        return ToolCommandResult(
            succeeded: false,
            reason: "Sweep couldn't start \(invocation.executable.lastPathComponent): \(error.localizedDescription)"
        )
    }

    if finished.wait(timeout: .now() + max(0, timeout)) == .timedOut {
        process.terminate()
        if finished.wait(timeout: .now() + 2) == .timedOut, process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
        return ToolCommandResult(succeeded: false, reason: "The cleanup command took too long, so Sweep stopped it.")
    }
    guard process.terminationStatus == 0 else {
        return ToolCommandResult(
            succeeded: false,
            reason: "The cleanup command couldn't finish safely (exit \(process.terminationStatus))."
        )
    }
    return ToolCommandResult(succeeded: true)
}

extension ToolCommandResult: Error {}
