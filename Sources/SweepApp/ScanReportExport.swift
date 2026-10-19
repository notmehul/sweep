import Foundation
import SweepCore

private struct ExportedScanReport: Encodable {
    var appVersion: String
    var date: Date
    var macOSVersion: String
    var persona: Persona
    var fullDiskAccess: Bool
    var totalsPerBucket: [String: Int64]
    var findings: [ExportedFinding]

    struct Persona: Encodable {
        var developer: Bool
    }
}

private struct ExportedFinding: Encodable {
    var ruleID: String
    var bucket: String
    var group: String
    var reclaimableBytes: Int64
    var path: String
}

enum ScanReportExportError: Error {
    case noScan
}

extension AppModel {
    func scanReportData() throws -> Data {
        guard let report else { throw ScanReportExportError.noScan }
        let totals = Dictionary(uniqueKeysWithValues: Bucket.allCases.map { bucket in
            (bucket.rawValue, report.findings.filter { $0.bucket == bucket }.reduce(0) { $0 + $1.reclaimableSize })
        })
        let exported = ExportedScanReport(
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development",
            date: report.date,
            macOSVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            persona: .init(developer: report.isDeveloper),
            fullDiskAccess: hasFullDiskAccess,
            totalsPerBucket: totals,
            findings: report.findings.map {
                let item = $0.items.first
                return ExportedFinding(
                    ruleID: $0.ruleID,
                    bucket: $0.bucket.rawValue,
                    group: $0.group,
                    reclaimableBytes: $0.reclaimableSize,
                    path: ScanReportRedactor.redact(
                        path: item?.path ?? "",
                        isDirectory: item?.isDirectory
                    )
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(exported)
    }
}
