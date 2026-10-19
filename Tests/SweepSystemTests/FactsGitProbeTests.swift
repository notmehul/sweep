import Foundation
import Testing
@testable import SweepSystem

@Test(.enabled(if: GitProbe().hasDeveloperTools, "Command Line Tools are not installed"))
func gitProbeReportsCleanDirtyAndRemoteState() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SweepGit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let clean = root.appendingPathComponent("clean", isDirectory: true)
    let dirty = root.appendingPathComponent("dirty", isDirectory: true)
    let noRemote = root.appendingPathComponent("no-remote", isDirectory: true)
    try makeRepository(at: clean, addRemote: true)
    try makeRepository(at: dirty, addRemote: true)
    try makeRepository(at: noRemote, addRemote: false)
    try Data("changed".utf8).write(to: dirty.appendingPathComponent("untracked.txt"))

    let probe = GitProbe()
    let cleanState = try #require(probe.gitState(repoContaining: clean.path))
    let dirtyState = try #require(
        probe.gitState(repoContaining: dirty.appendingPathComponent("nested/file").path)
    )
    let noRemoteState = try #require(probe.gitState(repoContaining: noRemote.path))

    #expect(!cleanState.isDirty)
    #expect(cleanState.hasRemote)
    #expect(cleanState.lastCommit != nil)
    #expect(dirtyState.isDirty)
    #expect(dirtyState.hasRemote)
    #expect(!noRemoteState.isDirty)
    #expect(!noRemoteState.hasRemote)
}

private func makeRepository(at url: URL, addRemote: Bool) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try runGit(["init", url.path])
    try Data("fixture".utf8).write(to: url.appendingPathComponent("tracked.txt"))
    try runGit(["-C", url.path, "add", "tracked.txt"])
    try runGit([
        "-C", url.path,
        "-c", "user.name=Sweep Tests",
        "-c", "user.email=sweep@example.invalid",
        "commit", "-m", "fixture",
    ])
    if addRemote {
        try runGit([
            "-C", url.path,
            "remote", "add", "origin", "https://example.invalid/sweep.git",
        ])
    }
}

private func runGit(_ arguments: [String]) throws {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitFixtureError.failed(String(decoding: data, as: UTF8.self))
    }
}

private enum GitFixtureError: Error {
    case failed(String)
}
