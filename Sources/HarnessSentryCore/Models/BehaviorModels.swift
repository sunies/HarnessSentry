import Foundation

public enum BehaviorType: String, Codable, CaseIterable, Sendable {
    case processLaunch = "进程启动"
    case processExit = "进程退出"
    case fileOpen = "文件打开"
    case directoryTraversal = "目录遍历"
    case fileCreate = "文件创建"
    case fileWrite = "文件写入"
    case fileRename = "文件重命名"
    case fileDelete = "文件删除"
    case archiveCreate = "归档创建"
    case networkConnect = "网络连接"
    case networkUpload = "网络发送"
    case hookEvent = "工具事件"
    case monitorGap = "监控缺口"
}

public enum EvidenceLevel: Int, Codable, Comparable, Sendable {
    case inferred = 1
    case correlated = 2
    case operatingSystem = 3
    case operatingSystemAndNetwork = 4

    public static func < (lhs: EvidenceLevel, rhs: EvidenceLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct BehaviorEvent: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let sessionID: String?
    public let toolID: String
    public let processID: Int32?
    public let processPath: String?
    public let type: BehaviorType
    public let target: String?
    public let byteCount: Int64?
    public let evidence: EvidenceLevel
    public let isRaw: Bool
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: String? = nil,
        toolID: String,
        processID: Int32? = nil,
        processPath: String? = nil,
        type: BehaviorType,
        target: String? = nil,
        byteCount: Int64? = nil,
        evidence: EvidenceLevel,
        isRaw: Bool = true,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.toolID = toolID
        self.processID = processID
        self.processPath = processPath
        self.type = type
        self.target = target
        self.byteCount = byteCount
        self.evidence = evidence
        self.isRaw = isRaw
        self.metadata = metadata
    }
}

public enum IncidentDisposition: String, Codable, Sendable {
    case open
    case safe
    case resolved
}

public struct Incident: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public var updatedAt: Date
    public let toolID: String
    public let sessionID: String?
    public let title: String
    public let summary: String
    public let severity: Int
    public let evidence: EvidenceLevel
    public var disposition: IncidentDisposition
    public var isPinned: Bool

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        toolID: String,
        sessionID: String? = nil,
        title: String,
        summary: String,
        severity: Int,
        evidence: EvidenceLevel,
        disposition: IncidentDisposition = .open,
        isPinned: Bool = false
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.toolID = toolID
        self.sessionID = sessionID
        self.title = title
        self.summary = summary
        self.severity = min(max(severity, 0), 100)
        self.evidence = evidence
        self.disposition = disposition
        self.isPinned = isPinned
    }
}

public struct StoreStatistics: Sendable, Equatable {
    public let eventCount: Int
    public let openIncidentCount: Int
    public let databaseBytes: Int64

    public init(eventCount: Int, openIncidentCount: Int, databaseBytes: Int64) {
        self.eventCount = eventCount
        self.openIncidentCount = openIncidentCount
        self.databaseBytes = databaseBytes
    }
}

public struct EvidenceExport: Codable, Sendable {
    public let exportedAt: Date
    public let schemaVersion: Int
    public let events: [BehaviorEvent]
    public let incidents: [Incident]

    public init(exportedAt: Date = Date(), schemaVersion: Int = 1, events: [BehaviorEvent], incidents: [Incident]) {
        self.exportedAt = exportedAt
        self.schemaVersion = schemaVersion
        self.events = events
        self.incidents = incidents
    }
}

public struct AllowRule: Identifiable, Codable, Hashable, Sendable {
    public let id: UUID
    public let createdAt: Date
    public let toolID: String?
    public let behaviorType: BehaviorType?
    public let target: String?
    public let note: String

    public init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        toolID: String? = nil,
        behaviorType: BehaviorType? = nil,
        target: String? = nil,
        note: String
    ) {
        self.id = id
        self.createdAt = createdAt
        self.toolID = toolID
        self.behaviorType = behaviorType
        self.target = target
        self.note = note
    }

    public func matches(_ event: BehaviorEvent) -> Bool {
        let scopedUploadClassMatches: Bool
        if target?.hasPrefix("git:") == true {
            scopedUploadClassMatches = event.metadata["commandClass"] == "git-push"
        } else if target?.hasPrefix("s3://") == true || target?.hasPrefix("oss://") == true {
            scopedUploadClassMatches = event.metadata["commandClass"] == "object-storage-upload"
        } else {
            scopedUploadClassMatches = true
        }
        return scopedUploadClassMatches &&
        (toolID == nil || toolID == event.toolID) &&
        (behaviorType == nil || behaviorType == event.type) &&
        (target == nil || target == event.target)
    }
}
