import Foundation
import Testing
@testable import SweepSystem

@Test func installedAppsReadBundlesFromInjectedRoots() throws {
    let fixture = try FactsFixture()
    defer { fixture.remove() }
    let applications = fixture.root.appendingPathComponent("Applications", isDirectory: true)
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    try fixture.makeApplication(
        named: "Example",
        in: applications,
        bundleID: "com.example.fixture",
        displayName: "Fixture App"
    )

    let spotlight = Spotlight(timeout: 0.1, applicationScope: applications.path)
    let apps = InstalledApps(roots: [applications], spotlight: spotlight).scan()

    let app = try #require(apps.first)
    #expect(apps.count == 1)
    #expect(app.bundleID == "com.example.fixture")
    #expect(app.displayName == "Fixture App")
    #expect(app.path.hasSuffix("Example.app"))
    #expect(app.allocatedSize > 0)
}

@Test func macFactsSnapshotsInstalledAndRunningApplications() throws {
    let fixture = try FactsFixture()
    defer { fixture.remove() }
    let applications = fixture.root.appendingPathComponent("Applications", isDirectory: true)
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    try fixture.makeApplication(
        named: "Snapshot",
        in: applications,
        bundleID: "com.example.snapshot",
        displayName: "Snapshot"
    )

    let facts = MacFacts(
        homeDirectory: fixture.root.path,
        applicationRoots: [applications],
        spotlight: Spotlight(timeout: 0.1, applicationScope: applications.path),
        runningBundleIDs: ["com.example.running"]
    )

    #expect(facts.isInstalled(bundleID: "com.example.snapshot"))
    #expect(!facts.isInstalled(bundleID: "com.example.missing"))
    #expect(facts.isRunning(bundleID: "com.example.running"))
    #expect(!facts.isRunning(bundleID: "com.example.snapshot"))
}

@Test func personaFindsNodeOnlyInPathDirectories() throws {
    let fixture = try FactsFixture()
    defer { fixture.remove() }
    let bin = fixture.root.appendingPathComponent("bin", isDirectory: true)
    try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
    let node = bin.appendingPathComponent("node")
    try Data("#!/bin/sh\n".utf8).write(to: node)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: node.path
    )

    let persona = Persona(
        homeDirectory: fixture.root.path,
        path: bin.path,
        xcodePath: fixture.root.appendingPathComponent("missing-xcode").path,
        homebrewPath: fixture.root.appendingPathComponent("missing-brew").path,
        hasCommandLineTools: false
    )

    #expect(persona.hasNode)
    #expect(persona.isDeveloper)
}

private struct FactsFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SweepFacts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    func makeApplication(
        named name: String,
        in root: URL,
        bundleID: String,
        displayName: String
    ) throws {
        let contents = root.appendingPathComponent("\(name).app/Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleDisplayName": displayName,
            "CFBundleName": name,
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 0x41, count: 8_192).write(
            to: resources.appendingPathComponent("payload")
        )
    }
}
