import CSQLite
import Foundation

public enum EventStoreError: Error, CustomStringConvertible, Sendable {
    case openDatabase(String)
    case prepare(String)
    case execute(String)
    case encode(String)

    public var description: String {
        switch self {
        case .openDatabase(let message): "无法打开数据库：\(message)"
        case .prepare(let message): "无法准备 SQL：\(message)"
        case .execute(let message): "无法执行 SQL：\(message)"
        case .encode(let message): "无法编码数据：\(message)"
        }
    }
}

public actor SQLiteEventStore {
    private let handle: SQLiteHandle
    private let databaseURL: URL
    private let encoder = JSONEncoder()

    public static func defaultDatabaseURL(fileManager: FileManager = .default) throws -> URL {
        let baseURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = baseURL.appendingPathComponent("HarnessSentry", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("HarnessSentry.sqlite")
    }

    public init(url: URL) throws {
        databaseURL = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let handle { sqlite3_close(handle) }
            throw EventStoreError.openDatabase(message)
        }
        self.handle = SQLiteHandle(handle)

        do {
            try Self.configure(handle)
        } catch {
            throw error
        }
    }

    public func insert(event: BehaviorEvent) throws {
        try insertEvent(event)
    }

    /// Returns the monitoring switch persisted in the shared SQLite database.
    /// A missing row (for example after migration from an older build) defaults
    /// to active monitoring.
    public func monitoringState() throws -> MonitoringState {
        let statement = try prepare("SELECT is_paused, updated_at, source FROM monitoring_state WHERE id = 1;")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            return MonitoringState(isPaused: false, updatedAt: .distantPast, source: nil)
        }
        return MonitoringState(
            isPaused: sqlite3_column_int(statement, 0) != 0,
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
            source: optionalText(statement, column: 2)
        )
    }

    public func isMonitoringPaused() throws -> Bool {
        try monitoringState().isPaused
    }

    @discardableResult
    public func setMonitoringPaused(
        _ isPaused: Bool,
        source: String? = nil,
        at updatedAt: Date = Date()
    ) throws -> MonitoringState {
        let statement = try prepare("""
            INSERT INTO monitoring_state(id, is_paused, updated_at, source)
            VALUES (1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                is_paused = excluded.is_paused,
                updated_at = excluded.updated_at,
                source = excluded.source;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, isPaused ? 1 : 0)
        sqlite3_bind_double(statement, 2, updatedAt.timeIntervalSince1970)
        bindOptional(source, to: 3, in: statement)
        try step(statement)
        return MonitoringState(isPaused: isPaused, updatedAt: updatedAt, source: source)
    }

    public func record(event: BehaviorEvent, evaluation: RuleEvaluation?) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try insertEvent(event)
            if let evaluation {
                try insertIncident(evaluation.incident)
                for eventID in evaluation.evidenceEventIDs {
                    let statement = try prepare("INSERT OR IGNORE INTO incident_events(incident_id, event_id) VALUES (?, ?);")
                    bind(evaluation.incident.id.uuidString, to: 1, in: statement)
                    bind(eventID.uuidString, to: 2, in: statement)
                    do { try step(statement) } catch {
                        sqlite3_finalize(statement)
                        throw error
                    }
                    sqlite3_finalize(statement)
                }
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func insertEvent(_ event: BehaviorEvent) throws {
        let metadata: String
        do {
            metadata = String(data: try encoder.encode(event.metadata), encoding: .utf8) ?? "{}"
        } catch {
            throw EventStoreError.encode(error.localizedDescription)
        }

        let sql = """
        INSERT INTO events(
            id, timestamp, session_id, tool_id, process_id, process_path,
            behavior_type, target, byte_count, evidence_level, is_raw, metadata_json
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            timestamp = excluded.timestamp,
            session_id = excluded.session_id,
            tool_id = excluded.tool_id,
            process_id = excluded.process_id,
            process_path = excluded.process_path,
            behavior_type = excluded.behavior_type,
            target = excluded.target,
            byte_count = excluded.byte_count,
            evidence_level = excluded.evidence_level,
            is_raw = excluded.is_raw,
            metadata_json = excluded.metadata_json;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bind(event.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, event.timestamp.timeIntervalSince1970)
        bindOptional(event.sessionID, to: 3, in: statement)
        bind(event.toolID, to: 4, in: statement)
        if let processID = event.processID {
            sqlite3_bind_int(statement, 5, processID)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bindOptional(event.processPath, to: 6, in: statement)
        bind(event.type.rawValue, to: 7, in: statement)
        bindOptional(event.target, to: 8, in: statement)
        if let byteCount = event.byteCount {
            sqlite3_bind_int64(statement, 9, byteCount)
        } else {
            sqlite3_bind_null(statement, 9)
        }
        sqlite3_bind_int(statement, 10, Int32(event.evidence.rawValue))
        sqlite3_bind_int(statement, 11, event.isRaw ? 1 : 0)
        bind(metadata, to: 12, in: statement)
        try step(statement)
    }

    public func insert(incident: Incident) throws {
        try insertIncident(incident)
    }

    private func insertIncident(_ incident: Incident) throws {
        let sql = """
        INSERT INTO incidents(
            id, created_at, updated_at, tool_id, session_id, title, summary,
            severity, evidence_level, disposition, is_pinned
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(id) DO UPDATE SET
            created_at = excluded.created_at,
            updated_at = excluded.updated_at,
            tool_id = excluded.tool_id,
            session_id = excluded.session_id,
            title = excluded.title,
            summary = excluded.summary,
            severity = excluded.severity,
            evidence_level = excluded.evidence_level,
            disposition = excluded.disposition,
            is_pinned = excluded.is_pinned;
        """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bind(incident.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, incident.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 3, incident.updatedAt.timeIntervalSince1970)
        bind(incident.toolID, to: 4, in: statement)
        bindOptional(incident.sessionID, to: 5, in: statement)
        bind(incident.title, to: 6, in: statement)
        bind(incident.summary, to: 7, in: statement)
        sqlite3_bind_int(statement, 8, Int32(incident.severity))
        sqlite3_bind_int(statement, 9, Int32(incident.evidence.rawValue))
        bind(incident.disposition.rawValue, to: 10, in: statement)
        sqlite3_bind_int(statement, 11, incident.isPinned ? 1 : 0)
        try step(statement)
    }

    public func fetchIncidents(limit: Int = 100) throws -> [Incident] {
        let statement = try prepare("""
            SELECT id, created_at, updated_at, tool_id, session_id, title, summary,
                   severity, evidence_level, disposition, is_pinned
            FROM incidents
            ORDER BY created_at DESC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))

        var incidents: [Incident] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = UUID(uuidString: text(statement, column: 0)),
                let disposition = IncidentDisposition(rawValue: text(statement, column: 9))
            else { continue }

            incidents.append(Incident(
                id: id,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 2)),
                toolID: text(statement, column: 3),
                sessionID: optionalText(statement, column: 4),
                title: text(statement, column: 5),
                summary: text(statement, column: 6),
                severity: Int(sqlite3_column_int(statement, 7)),
                evidence: EvidenceLevel(rawValue: Int(sqlite3_column_int(statement, 8))) ?? .inferred,
                disposition: disposition,
                isPinned: sqlite3_column_int(statement, 10) != 0
            ))
        }
        return incidents
    }

    public func fetchEvents(limit: Int = 200, since: Date? = nil, toolID: String? = nil) throws -> [BehaviorEvent] {
        var conditions: [String] = []
        if since != nil { conditions.append("timestamp >= ?") }
        if toolID != nil { conditions.append("tool_id = ?") }
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let statement = try prepare("""
            SELECT id, timestamp, session_id, tool_id, process_id, process_path,
                   behavior_type, target, byte_count, evidence_level, is_raw, metadata_json
            FROM events
            \(whereClause)
            ORDER BY timestamp DESC
            LIMIT ?;
            """)
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if let since {
            sqlite3_bind_double(statement, bindIndex, since.timeIntervalSince1970)
            bindIndex += 1
        }
        if let toolID {
            bind(toolID, to: bindIndex, in: statement)
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(max(1, limit)))

        let decoder = JSONDecoder()
        var events: [BehaviorEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = UUID(uuidString: text(statement, column: 0)),
                let type = BehaviorType(rawValue: text(statement, column: 6))
            else { continue }
            let metadataData = Data(text(statement, column: 11).utf8)
            let metadata = (try? decoder.decode([String: String].self, from: metadataData)) ?? [:]
            events.append(BehaviorEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                sessionID: optionalText(statement, column: 2),
                toolID: text(statement, column: 3),
                processID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 4),
                processPath: optionalText(statement, column: 5),
                type: type,
                target: optionalText(statement, column: 7),
                byteCount: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 8),
                evidence: EvidenceLevel(rawValue: Int(sqlite3_column_int(statement, 9))) ?? .inferred,
                isRaw: sqlite3_column_int(statement, 10) != 0,
                metadata: metadata
            ))
        }
        return events
    }

    public func fetchEvents(forIncidentID incidentID: UUID) throws -> [BehaviorEvent] {
        let statement = try prepare("""
            SELECT e.id, e.timestamp, e.session_id, e.tool_id, e.process_id, e.process_path,
                   e.behavior_type, e.target, e.byte_count, e.evidence_level, e.is_raw, e.metadata_json
            FROM events e
            INNER JOIN incident_events ie ON ie.event_id = e.id
            WHERE ie.incident_id = ?
            ORDER BY e.timestamp ASC;
            """)
        defer { sqlite3_finalize(statement) }
        bind(incidentID.uuidString, to: 1, in: statement)
        return try decodeEvents(statement)
    }

    public func insert(allowRule: AllowRule) throws {
        let statement = try prepare("""
            INSERT OR REPLACE INTO allow_rules(id, created_at, tool_id, behavior_type, target, note)
            VALUES (?, ?, ?, ?, ?, ?);
            """)
        defer { sqlite3_finalize(statement) }
        bind(allowRule.id.uuidString, to: 1, in: statement)
        sqlite3_bind_double(statement, 2, allowRule.createdAt.timeIntervalSince1970)
        bindOptional(allowRule.toolID, to: 3, in: statement)
        bindOptional(allowRule.behaviorType?.rawValue, to: 4, in: statement)
        bindOptional(allowRule.target, to: 5, in: statement)
        bind(allowRule.note, to: 6, in: statement)
        try step(statement)
    }

    public func fetchAllowRules() throws -> [AllowRule] {
        let statement = try prepare("SELECT id, created_at, tool_id, behavior_type, target, note FROM allow_rules ORDER BY created_at DESC;")
        defer { sqlite3_finalize(statement) }
        var rules: [AllowRule] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let id = UUID(uuidString: text(statement, column: 0)) else { continue }
            rules.append(AllowRule(
                id: id,
                createdAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                toolID: optionalText(statement, column: 2),
                behaviorType: optionalText(statement, column: 3).flatMap(BehaviorType.init(rawValue:)),
                target: optionalText(statement, column: 4),
                note: text(statement, column: 5)
            ))
        }
        return rules
    }

    public func deleteAllowRule(id: UUID) throws {
        let statement = try prepare("DELETE FROM allow_rules WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    public func isAllowed(_ event: BehaviorEvent) throws -> Bool {
        try fetchAllowRules().contains { $0.matches(event) }
    }

    public func exportEvidence(eventLimit: Int = 10_000, incidentLimit: Int = 2_000) throws -> EvidenceExport {
        EvidenceExport(
            events: try fetchEvents(limit: eventLimit),
            incidents: try fetchIncidents(limit: incidentLimit)
        )
    }

    public func markIncidentSafe(id: UUID) throws {
        let statement = try prepare("""
            UPDATE incidents
            SET disposition = 'safe', updated_at = ?
            WHERE id = ?;
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        bind(id.uuidString, to: 2, in: statement)
        try step(statement)
    }

    public func markAllOpenIncidentsSafe() throws {
        let statement = try prepare("UPDATE incidents SET disposition = 'safe', updated_at = ? WHERE disposition = 'open';")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
        try step(statement)
    }

    /// Removes incident summaries and their evidence links, leaving the
    /// independent behavior log and user settings untouched.
    public func clearIncidents() throws {
        try execute("DELETE FROM incidents;")
        try reclaimFreeSpace(aggressively: true)
    }

    public func deleteIncident(id: UUID) throws {
        let statement = try prepare("DELETE FROM incidents WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    public func deleteEvent(id: UUID) throws {
        let statement = try prepare("DELETE FROM events WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        bind(id.uuidString, to: 1, in: statement)
        try step(statement)
    }

    /// Clears behavior events and their incident-evidence links. Incident
    /// records and user settings remain intact.
    public func clearEvents() throws {
        try execute("DELETE FROM events;")
        try reclaimFreeSpace(aggressively: true)
    }

    /// Clears all local behavior and incident records. When settings are not
    /// preserved, allow rules are removed and monitoring returns to active.
    /// Retention preferences stored by the app outside SQLite remain the upper
    /// layer's responsibility.
    public func clearAllRecords(preservingSettings: Bool = true) throws {
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("DELETE FROM incidents;")
            try execute("DELETE FROM events;")
            if !preservingSettings {
                try execute("DELETE FROM allow_rules;")
                let statement = try prepare("""
                    INSERT INTO monitoring_state(id, is_paused, updated_at, source)
                    VALUES (1, 0, ?, 'reset')
                    ON CONFLICT(id) DO UPDATE SET
                        is_paused = 0,
                        updated_at = excluded.updated_at,
                        source = excluded.source;
                    """)
                sqlite3_bind_double(statement, 1, Date().timeIntervalSince1970)
                do { try step(statement) } catch {
                    sqlite3_finalize(statement)
                    throw error
                }
                sqlite3_finalize(statement)
            }
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
        try reclaimFreeSpace(aggressively: true)
    }

    public func statistics() throws -> StoreStatistics {
        let startOfToday = Calendar.current.startOfDay(for: Date()).timeIntervalSince1970
        return StoreStatistics(
            eventCount: try scalarInt("SELECT COUNT(*) FROM events WHERE timestamp >= \(startOfToday);"),
            openIncidentCount: try scalarInt("SELECT COUNT(*) FROM incidents WHERE disposition = 'open';"),
            databaseBytes: databaseFootprint()
        )
    }

    @discardableResult
    public func enforceRetention(
        _ policy: RetentionPolicy,
        now: Date = Date()
    ) throws -> StoreStatistics {
        let rawCutoff = now.addingTimeInterval(-Double(policy.rawEventHours) * 3_600).timeIntervalSince1970
        let behaviorCutoff = now.addingTimeInterval(-Double(policy.behaviorDays) * 86_400).timeIntervalSince1970
        let incidentCutoff = now.addingTimeInterval(-Double(policy.incidentDays) * 86_400).timeIntervalSince1970

        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("""
                DELETE FROM incidents
                WHERE created_at < \(incidentCutoff)
                  AND disposition != 'open'
                  AND is_pinned = 0;
                """)
            try execute("""
                DELETE FROM events
                WHERE is_raw = 1 AND timestamp < \(rawCutoff)
                  AND id NOT IN (SELECT event_id FROM incident_events);
                """)
            try execute("""
                DELETE FROM events
                WHERE timestamp < \(behaviorCutoff)
                  AND id NOT IN (SELECT event_id FROM incident_events);
                """)
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }

        try reclaimFreeSpace()

        // Proactively return below the 80% cleanup threshold. The loop has no
        // arbitrary pass limit: it ends only after meeting the target or after
        // every permitted deletion tier has been exhausted.
        let targetBytes = policy.cleanupThresholdBytes
        while databaseFootprint() >= targetBytes {
            if try deleteOldestUnlinkedEvents(limit: 2_500) > 0 {
                try reclaimFreeSpace(aggressively: true)
                continue
            }
            if try deleteOldestIncidentBatch(dispositions: [.safe, .resolved], limit: 250) > 0 {
                try reclaimFreeSpace(aggressively: true)
                continue
            }
            if try deleteOldestIncidentBatch(dispositions: [.open], limit: 250) > 0 {
                try reclaimFreeSpace(aggressively: true)
                continue
            }
            break
        }
        return try statistics()
    }

    private func deleteOldestUnlinkedEvents(limit: Int) throws -> Int {
        let statement = try prepare("""
            DELETE FROM events
            WHERE id IN (
                SELECT e.id
                FROM events e
                LEFT JOIN incident_events ie ON ie.event_id = e.id
                WHERE ie.event_id IS NULL
                ORDER BY e.timestamp ASC
                LIMIT ?
            );
            """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, limit)))
        try step(statement)
        return Int(sqlite3_changes(handle.pointer))
    }

    /// Deletes incidents and only those evidence events that are not shared by
    /// another incident. Temporary tables preserve the candidate evidence IDs
    /// across the foreign-key cascade.
    private func deleteOldestIncidentBatch(
        dispositions: [IncidentDisposition],
        limit: Int
    ) throws -> Int {
        guard !dispositions.isEmpty else { return 0 }
        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("CREATE TEMP TABLE IF NOT EXISTS cleanup_incident_ids(id TEXT PRIMARY KEY);")
            try execute("CREATE TEMP TABLE IF NOT EXISTS cleanup_event_ids(id TEXT PRIMARY KEY);")
            try execute("DELETE FROM cleanup_incident_ids;")
            try execute("DELETE FROM cleanup_event_ids;")

            let placeholders = Array(repeating: "?", count: dispositions.count).joined(separator: ",")
            let selectStatement = try prepare("""
                INSERT OR IGNORE INTO cleanup_incident_ids(id)
                SELECT id FROM incidents
                WHERE disposition IN (\(placeholders))
                  AND is_pinned = 0
                ORDER BY created_at ASC
                LIMIT ?;
                """)
            for (offset, disposition) in dispositions.enumerated() {
                bind(disposition.rawValue, to: Int32(offset + 1), in: selectStatement)
            }
            sqlite3_bind_int(selectStatement, Int32(dispositions.count + 1), Int32(max(1, limit)))
            do { try step(selectStatement) } catch {
                sqlite3_finalize(selectStatement)
                throw error
            }
            sqlite3_finalize(selectStatement)

            let candidateCount = try scalarInt("SELECT COUNT(*) FROM cleanup_incident_ids;")
            guard candidateCount > 0 else {
                try execute("COMMIT;")
                return 0
            }

            try execute("""
                INSERT OR IGNORE INTO cleanup_event_ids(id)
                SELECT event_id FROM incident_events
                WHERE incident_id IN (SELECT id FROM cleanup_incident_ids);
                """)
            try execute("DELETE FROM incidents WHERE id IN (SELECT id FROM cleanup_incident_ids);")
            try execute("""
                DELETE FROM events
                WHERE id IN (SELECT id FROM cleanup_event_ids)
                  AND NOT EXISTS (
                      SELECT 1 FROM incident_events ie WHERE ie.event_id = events.id
                  );
                """)
            try execute("COMMIT;")
            return candidateCount
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func reclaimFreeSpace(aggressively: Bool = false) throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
        if aggressively {
            if try scalarInt("PRAGMA auto_vacuum;") == 2 {
                try execute("PRAGMA incremental_vacuum;")
            } else {
                // Databases made by early Community builds set auto_vacuum too
                // late for SQLite to activate it. Apply the mode during this
                // already-required compaction instead of slowing every launch.
                try execute("PRAGMA auto_vacuum=INCREMENTAL;")
                try execute("VACUUM;")
            }
        }
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private static func configure(_ database: OpaquePointer) throws {
        try execute("PRAGMA busy_timeout=3000;", on: database)
        try execute("PRAGMA foreign_keys=ON;", on: database)
        // This must precede WAL setup and the first table creation for a new
        // database. Existing databases are converted lazily during aggressive
        // cleanup, where the cost is justified by an explicit clear/cap breach.
        try execute("PRAGMA auto_vacuum=INCREMENTAL;", on: database)
        try execute("PRAGMA journal_mode=WAL;", on: database)
        try execute("PRAGMA synchronous=NORMAL;", on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS events(
            id TEXT PRIMARY KEY NOT NULL,
            timestamp REAL NOT NULL,
            session_id TEXT,
            tool_id TEXT NOT NULL,
            process_id INTEGER,
            process_path TEXT,
            behavior_type TEXT NOT NULL,
            target TEXT,
            byte_count INTEGER,
            evidence_level INTEGER NOT NULL,
            is_raw INTEGER NOT NULL DEFAULT 1,
            metadata_json TEXT NOT NULL DEFAULT '{}'
        );
        """, on: database)
        try execute("CREATE INDEX IF NOT EXISTS events_timestamp_idx ON events(timestamp);", on: database)
        try execute("CREATE INDEX IF NOT EXISTS events_tool_idx ON events(tool_id, timestamp);", on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS incidents(
            id TEXT PRIMARY KEY NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL,
            tool_id TEXT NOT NULL,
            session_id TEXT,
            title TEXT NOT NULL,
            summary TEXT NOT NULL,
            severity INTEGER NOT NULL,
            evidence_level INTEGER NOT NULL,
            disposition TEXT NOT NULL,
            is_pinned INTEGER NOT NULL DEFAULT 0
        );
        """, on: database)
        try execute("CREATE INDEX IF NOT EXISTS incidents_created_idx ON incidents(created_at);", on: database)
        try execute("CREATE INDEX IF NOT EXISTS incidents_status_idx ON incidents(disposition, created_at);", on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS incident_events(
            incident_id TEXT NOT NULL REFERENCES incidents(id) ON DELETE CASCADE,
            event_id TEXT NOT NULL REFERENCES events(id) ON DELETE CASCADE,
            PRIMARY KEY(incident_id, event_id)
        );
        """, on: database)
        try execute("CREATE INDEX IF NOT EXISTS incident_events_event_idx ON incident_events(event_id);", on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS allow_rules(
            id TEXT PRIMARY KEY NOT NULL,
            created_at REAL NOT NULL,
            tool_id TEXT,
            behavior_type TEXT,
            target TEXT,
            note TEXT NOT NULL
        );
        """, on: database)
        try execute("""
        CREATE TABLE IF NOT EXISTS monitoring_state(
            id INTEGER PRIMARY KEY CHECK(id = 1),
            is_paused INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL,
            source TEXT
        );
        """, on: database)
        try execute("""
        INSERT OR IGNORE INTO monitoring_state(id, is_paused, updated_at, source)
        VALUES (1, 0, 0, 'migration-default');
        """, on: database)
        try execute("PRAGMA user_version=4;", on: database)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        let database = handle.pointer
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw EventStoreError.prepare(String(cString: sqlite3_errmsg(database)))
        }
        return statement
    }

    private func execute(_ sql: String) throws {
        try Self.execute(sql, on: handle.pointer)
    }

    private static func execute(_ sql: String, on database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw EventStoreError.execute(message)
        }
    }

    private func step(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            let message = String(cString: sqlite3_errmsg(handle.pointer))
            throw EventStoreError.execute(message)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func bind(_ value: String, to index: Int32, in statement: OpaquePointer) {
        value.withCString { pointer in
            _ = hs_sqlite_bind_text(statement, index, pointer)
        }
    }

    private func bindOptional(_ value: String?, to index: Int32, in statement: OpaquePointer) {
        if let value {
            bind(value, to: index, in: statement)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func text(_ statement: OpaquePointer, column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    private func optionalText(_ statement: OpaquePointer, column: Int32) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    private func databaseFootprint() -> Int64 {
        let paths = [databaseURL.path, databaseURL.path + "-wal", databaseURL.path + "-shm"]
        return paths.reduce(into: Int64(0)) { total, path in
            guard
                let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                let size = attributes[.size] as? NSNumber
            else { return }
            total += size.int64Value
        }
    }

    private func decodeEvents(_ statement: OpaquePointer) throws -> [BehaviorEvent] {
        let decoder = JSONDecoder()
        var events: [BehaviorEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard
                let id = UUID(uuidString: text(statement, column: 0)),
                let type = BehaviorType(rawValue: text(statement, column: 6))
            else { continue }
            let metadata = (try? decoder.decode([String: String].self, from: Data(text(statement, column: 11).utf8))) ?? [:]
            events.append(BehaviorEvent(
                id: id,
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                sessionID: optionalText(statement, column: 2),
                toolID: text(statement, column: 3),
                processID: sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int(statement, 4),
                processPath: optionalText(statement, column: 5),
                type: type,
                target: optionalText(statement, column: 7),
                byteCount: sqlite3_column_type(statement, 8) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 8),
                evidence: EvidenceLevel(rawValue: Int(sqlite3_column_int(statement, 9))) ?? .inferred,
                isRaw: sqlite3_column_int(statement, 10) != 0,
                metadata: metadata
            ))
        }
        return events
    }
}

private final class SQLiteHandle: @unchecked Sendable {
    let pointer: OpaquePointer

    init(_ pointer: OpaquePointer) {
        self.pointer = pointer
    }

    deinit {
        sqlite3_close(pointer)
    }
}
