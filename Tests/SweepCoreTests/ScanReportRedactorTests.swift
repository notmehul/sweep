import SweepCore
import Testing

@Test func scanReportRedactionKeepsOnlyLibraryAppFolder() {
    let home = "/Users/alice"

    #expect(ScanReportRedactor.redact(
        path: "/Users/alice/Library/Application Support/Cursor/User/workspace.json",
        home: home
    ) == "~/Library/Application Support/Cursor/<file>")
    #expect(ScanReportRedactor.redact(
        path: "~/Library/Caches/com.example.app",
        home: home
    ) == "~/Library/Caches/com.example.app")
    #expect(ScanReportRedactor.redact(
        path: "~/Library/Preferences/com.example.app.plist",
        isDirectory: false,
        home: home
    ) == "~/Library/Preferences/<file>")
}

@Test func scanReportRedactionRemovesPersonalFoldersAndFileNames() {
    let home = "/Users/alice"

    #expect(ScanReportRedactor.redact(
        path: "/Users/alice/Documents/Taxes 2026/return.pdf",
        home: home
    ) == "~/Documents/<file>")
    #expect(ScanReportRedactor.redact(
        path: "/Users/alice/Dev/secret-project/.build",
        home: home
    ) == "~/Dev/<file>")
    #expect(ScanReportRedactor.redact(
        path: "/Users/alice/Movies/Family.mov",
        home: home
    ) == "~/<file>")
    #expect(ScanReportRedactor.redact(path: "/Users/bob/private.txt", home: home) == "<file>")
}
