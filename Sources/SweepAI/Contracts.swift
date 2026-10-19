import Foundation

public protocol Explaining: Sendable {
    func explainFolder(_ facts: FolderFacts) async -> FolderExplanation?
    func summarize(_ facts: ScanSummaryFacts) async -> String
    func narrate(_ changes: [ChangeFact]) async -> String?
}

public struct FolderFacts: Sendable, Equatable {
    public struct Child: Sendable, Equatable {
        public var name: String
        public var allocatedBytes: Int64

        public init(name: String, allocatedBytes: Int64) {
            self.name = name
            self.allocatedBytes = allocatedBytes
        }
    }

    public var path: String
    public var allocatedBytes: Int64
    public var itemCount: Int
    public var topChildren: [Child]
    public var owningBundleID: String?
    public var newestModificationDate: Date?
    public var fileTypeHistogram: [String: Int]

    public init(
        path: String,
        allocatedBytes: Int64,
        itemCount: Int,
        topChildren: [Child],
        owningBundleID: String? = nil,
        newestModificationDate: Date? = nil,
        fileTypeHistogram: [String: Int] = [:]
    ) {
        self.path = path
        self.allocatedBytes = allocatedBytes
        self.itemCount = itemCount
        self.topChildren = Array(topChildren.prefix(10))
        self.owningBundleID = owningBundleID
        self.newestModificationDate = newestModificationDate
        self.fileTypeHistogram = fileTypeHistogram
    }
}

public struct FolderExplanation: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        case cache
        case appData
        case userContent
        case developer
        case unknown
    }

    public var title: String
    /// One paragraph of two or three sentences: what the folder is and what's inside it,
    /// then what removing it would mean. One flowing thought, no repetition.
    public var summary: String
    public var kind: Kind

    public init(title: String, summary: String, kind: Kind) {
        self.title = title
        self.summary = summary
        self.kind = kind
    }
}

public struct ScanSummaryFacts: Sendable, Equatable {
    public struct BucketBytes: Sendable, Equatable {
        public var rebuilds: Int64
        public var review: Int64
        public var yours: Int64
        public var dontTouch: Int64

        public init(rebuilds: Int64, review: Int64, yours: Int64, dontTouch: Int64 = 0) {
            self.rebuilds = rebuilds
            self.review = review
            self.yours = yours
            self.dontTouch = dontTouch
        }
    }

    public struct Finding: Sendable, Equatable {
        public var title: String
        public var allocatedBytes: Int64

        public init(title: String, allocatedBytes: Int64) {
            self.title = title
            self.allocatedBytes = allocatedBytes
        }
    }

    public var freeableBytes: Int64
    public var perBucketBytes: BucketBytes
    public var topFindings: [Finding]
    public var coverage: Double

    public init(
        freeableBytes: Int64,
        perBucketBytes: BucketBytes,
        topFindings: [Finding],
        coverage: Double
    ) {
        self.freeableBytes = freeableBytes
        self.perBucketBytes = perBucketBytes
        self.topFindings = Array(topFindings.prefix(3))
        self.coverage = min(max(coverage, 0), 1)
    }
}

public struct ChangeFact: Sendable, Equatable {
    public var name: String
    public var deltaBytes: Int64
    public var period: String

    public init(name: String, deltaBytes: Int64, period: String) {
        self.name = name
        self.deltaBytes = deltaBytes
        self.period = period
    }
}
