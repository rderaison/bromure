import Foundation
import SQLite3

private let traceDebug = ProcessInfo.processInfo.environment["BROMURE_DEBUG_TRACE"] != nil

// MARK: - Filter

public struct TraceFilter: Sendable {
    public var searchText: String?
    public var hostnames: Set<String>
    public var methods: Set<String>
    public var statusCategories: Set<Int>
    public var bodyContent: String?
    public var timeStart: Double?
    public var timeEnd: Double?
    public var tabId: Int?
    public var documentUrl: String?

    public static var all: TraceFilter { TraceFilter() }

    public init(
        searchText: String? = nil,
        hostnames: Set<String> = [],
        methods: Set<String> = [],
        statusCategories: Set<Int> = [],
        bodyContent: String? = nil,
        timeStart: Double? = nil,
        timeEnd: Double? = nil,
        tabId: Int? = nil,
        documentUrl: String? = nil
    ) {
        self.searchText = searchText
        self.hostnames = hostnames
        self.methods = methods
        self.statusCategories = statusCategories
        self.bodyContent = bodyContent
        self.timeStart = timeStart
        self.timeEnd = timeEnd
        self.tabId = tabId
        self.documentUrl = documentUrl
    }
}

// MARK: - TraceStore

@MainActor
public final class TraceStore {
    private var db: OpaquePointer?
    public let databaseURL: URL
    private let sessionID: String
    private let inMemory: Bool

    // Prepared statements for hot paths
    private var insertEventStmt: OpaquePointer?
    private var insertHeaderStmt: OpaquePointer?
    private var insertBodyStmt: OpaquePointer?
    private var insertFormStmt: OpaquePointer?

    public init(sessionID: String, inMemory: Bool = false) {
        self.sessionID = sessionID
        self.inMemory = inMemory
        self.databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bromure-trace-\(sessionID).sqlite")

        openDatabase()
        createSchema()
        prepareStatements()
    }

    deinit {
        // Release SQLite resources directly — deinit runs outside actor context
        for stmt in [insertEventStmt, insertHeaderStmt, insertBodyStmt, insertFormStmt] {
            if let stmt = stmt { sqlite3_finalize(stmt) }
        }
        if let db = db {
            sqlite3_close_v2(db)
        }
    }

    // MARK: - Database setup

    private func openDatabase() {
        let path = inMemory ? ":memory:" : databaseURL.path
        let rc = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        guard rc == SQLITE_OK else {
            if traceDebug { print("[Trace-Store] failed to open database: \(rc)") }
            return
        }

        // Performance pragmas for write-heavy workload
        exec("PRAGMA journal_mode = WAL")
        exec("PRAGMA synchronous = NORMAL")
        exec("PRAGMA cache_size = -8000") // 8 MB
        exec("PRAGMA temp_store = MEMORY")
        exec("PRAGMA mmap_size = 67108864") // 64 MB
    }

    private func createSchema() {
        exec("""
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                method TEXT NOT NULL,
                url TEXT NOT NULL,
                hostname TEXT,
                status_code INTEGER,
                duration REAL,
                mime_type TEXT,
                initiator TEXT,
                tab_id INTEGER,
                error_text TEXT,
                document_url TEXT,
                frame_url TEXT,
                nav_type TEXT,
                redirect_from TEXT
            );
            CREATE TABLE IF NOT EXISTS headers (
                event_id TEXT NOT NULL,
                direction TEXT NOT NULL,
                name TEXT NOT NULL,
                value TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS bodies (
                event_id TEXT PRIMARY KEY,
                direction TEXT NOT NULL,
                content TEXT,
                truncated INTEGER DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS form_snapshots (
                event_id TEXT NOT NULL,
                field_name TEXT NOT NULL,
                field_type TEXT,
                field_value TEXT
            );
            CREATE INDEX IF NOT EXISTS idx_events_timestamp ON events(timestamp);
            CREATE INDEX IF NOT EXISTS idx_events_hostname ON events(hostname);
            CREATE INDEX IF NOT EXISTS idx_events_tab_id ON events(tab_id);
            CREATE INDEX IF NOT EXISTS idx_events_document_url ON events(document_url);
            CREATE INDEX IF NOT EXISTS idx_headers_event_id ON headers(event_id);
            CREATE INDEX IF NOT EXISTS idx_bodies_event_id ON bodies(event_id);
            CREATE INDEX IF NOT EXISTS idx_form_event_id ON form_snapshots(event_id);
            """)
    }

    private func prepareStatements() {
        insertEventStmt = prepare("""
            INSERT OR REPLACE INTO events
            (id, timestamp, method, url, hostname, status_code, duration, mime_type,
             initiator, tab_id, error_text, document_url, frame_url, nav_type, redirect_from)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """)
        insertHeaderStmt = prepare(
            "INSERT INTO headers (event_id, direction, name, value) VALUES (?,?,?,?)"
        )
        insertBodyStmt = prepare(
            "INSERT OR REPLACE INTO bodies (event_id, direction, content, truncated) VALUES (?,?,?,?)"
        )
        insertFormStmt = prepare(
            "INSERT INTO form_snapshots (event_id, field_name, field_type, field_value) VALUES (?,?,?,?)"
        )
    }

    private func finalizeStatements() {
        for stmt in [insertEventStmt, insertHeaderStmt, insertBodyStmt, insertFormStmt] {
            if let stmt = stmt { sqlite3_finalize(stmt) }
        }
        insertEventStmt = nil
        insertHeaderStmt = nil
        insertBodyStmt = nil
        insertFormStmt = nil
    }

    // MARK: - Insert

    public func insert(event: TraceEvent) {
        guard let db = db else { return }

        let hostname = event.hostname ?? URLComponents(string: event.url)?.host

        exec("BEGIN TRANSACTION")

        // Insert event row
        if let stmt = insertEventStmt {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, event.id)
            sqlite3_bind_double(stmt, 2, event.timestamp)
            bindText(stmt, 3, event.method)
            bindText(stmt, 4, event.url)
            bindTextOrNull(stmt, 5, hostname)
            bindIntOrNull(stmt, 6, event.statusCode)
            bindDoubleOrNull(stmt, 7, event.duration)
            bindTextOrNull(stmt, 8, event.mimeType)
            bindTextOrNull(stmt, 9, event.initiator)
            bindIntOrNull(stmt, 10, event.tabId)
            bindTextOrNull(stmt, 11, event.errorText)
            bindTextOrNull(stmt, 12, event.documentUrl)
            bindTextOrNull(stmt, 13, event.frameUrl)
            bindTextOrNull(stmt, 14, event.navType)
            bindTextOrNull(stmt, 15, event.redirectFrom)

            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && traceDebug {
                print("[Trace-Store] insert event failed: \(rc) - \(String(cString: sqlite3_errmsg(db)))")
            }
        }

        // Insert request headers
        if let headers = event.requestHeaders {
            insertHeaders(eventId: event.id, direction: "request", headers: headers)
        }

        // Insert response headers
        if let headers = event.responseHeaders {
            insertHeaders(eventId: event.id, direction: "response", headers: headers)
        }

        // Insert post data (request body)
        if let postData = event.postData {
            insertBody(eventId: event.id, direction: "request", content: postData, truncated: false)
        }

        // Insert response body
        if let body = event.responseBody {
            insertBody(eventId: event.id, direction: "response", content: body, truncated: event.responseBodyTruncated ?? false)
        }

        // Insert form field snapshots
        if let fields = event.formFields {
            for field in fields {
                if let stmt = insertFormStmt {
                    sqlite3_reset(stmt)
                    sqlite3_clear_bindings(stmt)
                    bindText(stmt, 1, event.id)
                    bindText(stmt, 2, field.name)
                    bindTextOrNull(stmt, 3, field.type)
                    bindTextOrNull(stmt, 4, field.value)
                    sqlite3_step(stmt)
                }
            }
        }

        exec("COMMIT")
    }

    private func insertHeaders(eventId: String, direction: String, headers: [String: String]) {
        guard let stmt = insertHeaderStmt else { return }
        for (name, value) in headers {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)
            bindText(stmt, 1, eventId)
            bindText(stmt, 2, direction)
            bindText(stmt, 3, name)
            bindText(stmt, 4, value)
            sqlite3_step(stmt)
        }
    }

    private func insertBody(eventId: String, direction: String, content: String, truncated: Bool) {
        guard let stmt = insertBodyStmt else { return }
        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        bindText(stmt, 1, eventId)
        bindText(stmt, 2, direction)
        bindTextOrNull(stmt, 3, content)
        sqlite3_bind_int(stmt, 4, truncated ? 1 : 0)
        sqlite3_step(stmt)
    }

    // MARK: - Query

    public func queryEvents(filter: TraceFilter) -> [TraceEvent] {
        guard db != nil else { return [] }

        var whereClauses: [String] = []
        var bindings: [Any] = []

        buildWhereClauses(filter: filter, clauses: &whereClauses, bindings: &bindings)

        let whereSQL = whereClauses.isEmpty ? "" : " WHERE " + whereClauses.joined(separator: " AND ")

        var needsBodyJoin = false
        if filter.bodyContent != nil {
            needsBodyJoin = true
        }

        let fromSQL: String
        if needsBodyJoin {
            fromSQL = "FROM events e LEFT JOIN bodies b ON b.event_id = e.id"
        } else {
            fromSQL = "FROM events e"
        }

        let sql = "SELECT e.id, e.timestamp, e.method, e.url, e.hostname, e.status_code, " +
                  "e.duration, e.mime_type, e.initiator, e.tab_id, e.error_text, " +
                  "e.document_url, e.frame_url, e.nav_type, e.redirect_from " +
                  "\(fromSQL)\(whereSQL) ORDER BY e.timestamp ASC"

        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        bindParameters(stmt: stmt, bindings: bindings)

        var events: [TraceEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let event = readEventRow(stmt)
            events.append(event)
        }

        // Hydrate headers, bodies, and form fields
        for i in events.indices {
            events[i].requestHeaders = loadHeaders(eventId: events[i].id, direction: "request")
            events[i].responseHeaders = loadHeaders(eventId: events[i].id, direction: "response")
            loadBodies(event: &events[i])
            events[i].formFields = loadFormFields(eventId: events[i].id)
        }

        return events
    }

    public func eventCount(filter: TraceFilter) -> Int {
        guard db != nil else { return 0 }

        var whereClauses: [String] = []
        var bindings: [Any] = []
        buildWhereClauses(filter: filter, clauses: &whereClauses, bindings: &bindings)

        let whereSQL = whereClauses.isEmpty ? "" : " WHERE " + whereClauses.joined(separator: " AND ")

        var needsBodyJoin = false
        if filter.bodyContent != nil {
            needsBodyJoin = true
        }

        let fromSQL: String
        if needsBodyJoin {
            fromSQL = "FROM events e LEFT JOIN bodies b ON b.event_id = e.id"
        } else {
            fromSQL = "FROM events e"
        }

        let sql = "SELECT COUNT(*) \(fromSQL)\(whereSQL)"
        guard let stmt = prepare(sql) else { return 0 }
        defer { sqlite3_finalize(stmt) }

        bindParameters(stmt: stmt, bindings: bindings)

        if sqlite3_step(stmt) == SQLITE_ROW {
            return Int(sqlite3_column_int64(stmt, 0))
        }
        return 0
    }

    public func distinctHostnames() -> [String] {
        guard db != nil else { return [] }

        let sql = "SELECT DISTINCT hostname FROM events WHERE hostname IS NOT NULL ORDER BY hostname"
        guard let stmt = prepare(sql) else { return [] }
        defer { sqlite3_finalize(stmt) }

        var hostnames: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cStr = sqlite3_column_text(stmt, 0) {
                hostnames.append(String(cString: cStr))
            }
        }
        return hostnames
    }

    // MARK: - Export

    public func exportAsJSON() -> Data {
        let events = queryEvents(filter: .all)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(events)) ?? Data("[]".utf8)
    }

    public func exportDatabase(to url: URL) throws {
        // No on-disk file exists for in-memory stores — export is meaningless.
        // (Policy-enforced managed recording runs in this mode.)
        if inMemory {
            throw CocoaError(.fileWriteNoPermission)
        }
        // Checkpoint WAL to ensure all data is in the main db file
        if let db = db {
            sqlite3_wal_checkpoint_v2(db, nil, SQLITE_CHECKPOINT_FULL, nil, nil)
        }
        try FileManager.default.copyItem(at: databaseURL, to: url)
    }

    public func destroy() {
        finalizeStatements()
        if let db = db {
            sqlite3_close_v2(db)
            self.db = nil
        }

        if !inMemory {
            let fm = FileManager.default
            try? fm.removeItem(at: databaseURL)

            // Also remove WAL and SHM files
            let walURL = databaseURL.appendingPathExtension("wal")
            let shmURL = databaseURL.appendingPathExtension("shm")
            try? fm.removeItem(at: walURL)
            try? fm.removeItem(at: shmURL)
        }

        // Reopen fresh
        openDatabase()
        createSchema()
        prepareStatements()
    }

    // MARK: - WHERE clause builder

    private func buildWhereClauses(filter: TraceFilter, clauses: inout [String], bindings: inout [Any]) {
        if let text = filter.searchText, !text.isEmpty {
            clauses.append("e.url LIKE ?")
            bindings.append("%\(text)%")
        }

        if !filter.hostnames.isEmpty {
            let placeholders = filter.hostnames.map { _ in "?" }.joined(separator: ",")
            clauses.append("e.hostname IN (\(placeholders))")
            for h in filter.hostnames.sorted() { bindings.append(h) }
        }

        if !filter.methods.isEmpty {
            let placeholders = filter.methods.map { _ in "?" }.joined(separator: ",")
            clauses.append("e.method IN (\(placeholders))")
            for m in filter.methods.sorted() { bindings.append(m) }
        }

        if !filter.statusCategories.isEmpty {
            // Match status_code / 100 against the categories
            let conditions = filter.statusCategories.sorted().map { _ in "(e.status_code / 100 = ?)" }
            clauses.append("(" + conditions.joined(separator: " OR ") + ")")
            for cat in filter.statusCategories.sorted() { bindings.append(cat) }
        }

        if let bodyContent = filter.bodyContent, !bodyContent.isEmpty {
            clauses.append("b.content LIKE ?")
            bindings.append("%\(bodyContent)%")
        }

        if let start = filter.timeStart {
            clauses.append("e.timestamp >= ?")
            bindings.append(start)
        }

        if let end = filter.timeEnd {
            clauses.append("e.timestamp <= ?")
            bindings.append(end)
        }

        if let tabId = filter.tabId {
            clauses.append("e.tab_id = ?")
            bindings.append(tabId)
        }

        if let docUrl = filter.documentUrl, !docUrl.isEmpty {
            clauses.append("e.document_url = ?")
            bindings.append(docUrl)
        }
    }

    private func bindParameters(stmt: OpaquePointer, bindings: [Any]) {
        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case let s as String:
                sqlite3_bind_text(stmt, idx, (s as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            case let d as Double:
                sqlite3_bind_double(stmt, idx, d)
            case let n as Int:
                sqlite3_bind_int64(stmt, idx, Int64(n))
            default:
                sqlite3_bind_null(stmt, idx)
            }
        }
    }

    // MARK: - Row readers

    private func readEventRow(_ stmt: OpaquePointer?) -> TraceEvent {
        let id = columnText(stmt, 0) ?? ""
        let timestamp = sqlite3_column_double(stmt, 1)
        let method = columnText(stmt, 2) ?? ""
        let url = columnText(stmt, 3) ?? ""
        let hostname = columnText(stmt, 4)
        let statusCode = columnIntOrNil(stmt, 5)
        let duration = columnDoubleOrNil(stmt, 6)
        let mimeType = columnText(stmt, 7)
        let initiator = columnText(stmt, 8)
        let tabId = columnIntOrNil(stmt, 9)
        let errorText = columnText(stmt, 10)
        let documentUrl = columnText(stmt, 11)
        let frameUrl = columnText(stmt, 12)
        let navType = columnText(stmt, 13)
        let redirectFrom = columnText(stmt, 14)

        return TraceEvent(
            id: id, timestamp: timestamp, method: method, url: url,
            statusCode: statusCode, duration: duration,
            mimeType: mimeType, initiator: initiator,
            tabId: tabId, errorText: errorText,
            hostname: hostname, documentUrl: documentUrl,
            frameUrl: frameUrl, navType: navType,
            redirectFrom: redirectFrom
        )
    }

    private func loadHeaders(eventId: String, direction: String) -> [String: String]? {
        let sql = "SELECT name, value FROM headers WHERE event_id = ? AND direction = ?"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, eventId)
        bindText(stmt, 2, direction)

        var headers: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let name = columnText(stmt, 0), let value = columnText(stmt, 1) {
                headers[name] = value
            }
        }
        return headers.isEmpty ? nil : headers
    }

    private func loadBodies(event: inout TraceEvent) {
        let sql = "SELECT direction, content, truncated FROM bodies WHERE event_id = ?"
        guard let stmt = prepare(sql) else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, event.id)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let direction = columnText(stmt, 0) ?? ""
            let content = columnText(stmt, 1)
            let truncated = sqlite3_column_int(stmt, 2) != 0

            if direction == "request" {
                event.postData = content
            } else if direction == "response" {
                event.responseBody = content
                event.responseBodyTruncated = truncated
            }
        }
    }

    private func loadFormFields(eventId: String) -> [TraceEvent.FormFieldSnapshot]? {
        let sql = "SELECT field_name, field_type, field_value FROM form_snapshots WHERE event_id = ?"
        guard let stmt = prepare(sql) else { return nil }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, eventId)

        var fields: [TraceEvent.FormFieldSnapshot] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let name = columnText(stmt, 0) ?? ""
            let type = columnText(stmt, 1) ?? ""
            let value = columnText(stmt, 2) ?? ""
            fields.append(TraceEvent.FormFieldSnapshot(name: name, type: type, value: value))
        }
        return fields.isEmpty ? nil : fields
    }

    // MARK: - SQLite helpers

    private func exec(_ sql: String) {
        guard let db = db else { return }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK && traceDebug {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            print("[Trace-Store] exec error (\(rc)): \(msg)")
            sqlite3_free(errMsg)
        }
    }

    private func prepare(_ sql: String) -> OpaquePointer? {
        guard let db = db else { return nil }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        if rc != SQLITE_OK && traceDebug {
            print("[Trace-Store] prepare error (\(rc)): \(String(cString: sqlite3_errmsg(db)))")
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, (value as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bindTextOrNull(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value = value {
            bindText(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindIntOrNull(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Int?) {
        if let value = value {
            sqlite3_bind_int64(stmt, idx, Int64(value))
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func bindDoubleOrNull(_ stmt: OpaquePointer?, _ idx: Int32, _ value: Double?) {
        if let value = value {
            sqlite3_bind_double(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func columnText(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard let cStr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: cStr)
    }

    private func columnIntOrNil(_ stmt: OpaquePointer?, _ idx: Int32) -> Int? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, idx))
    }

    private func columnDoubleOrNil(_ stmt: OpaquePointer?, _ idx: Int32) -> Double? {
        if sqlite3_column_type(stmt, idx) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, idx)
    }
}
