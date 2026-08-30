import Foundation
import SQLite3

// FocusCore — the pure data layer (no AppKit), split out from main.swift so it can
// be compiled and exercised headlessly by the test runner in tests/. Contains the
// SQLite `DB` wrapper, the row structs it returns, and the small pure helpers those
// depend on. main.swift compiles this file alongside it; the tests compile it alone.

// SQLite wants to know whether the bound string outlives the call; TRANSIENT
// tells it to copy, so passing a temporary Swift string is safe.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// Timestamps are stored as ISO8601 UTC.
let isoParser = ISO8601DateFormatter()

func mmss(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

// Given a focus name, produce the name for its continuation: "Foo" -> "Foo (continued)",
// "Foo (continued)" -> "Foo (continued 2)", "Foo (continued 2)" -> "Foo (continued 3)".
func continuedName(_ focus: String) -> String {
    let pattern = "^(.*?)\\s*\\(continued(?: (\\d+))?\\)$"
    let ns = focus as NSString
    if let re = try? NSRegularExpression(pattern: pattern),
       let m = re.firstMatch(in: focus, range: NSRange(location: 0, length: ns.length)) {
        let base = ns.substring(with: m.range(at: 1))
        let current = m.range(at: 2).location != NSNotFound
            ? (Int(ns.substring(with: m.range(at: 2))) ?? 1) : 1
        return "\(base) (continued \(current + 1))"
    }
    return "\(focus) (continued)"
}

// MARK: - Storage

final class DB {
    private var db: OpaquePointer?

    /// Open the database. Pass an explicit `path` (e.g. a temp file) for tests;
    /// the default is the live ~/focus/focus.db.
    deinit { if db != nil { sqlite3_close(db) } }

    init(path: String? = nil) {
        let dbPath: String
        if let path = path {
            dbPath = path
        } else {
            let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("focus")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            dbPath = dir.appendingPathComponent("focus.db").path
        }
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            FileHandle.standardError.write("focus: cannot open db at \(dbPath)\n".data(using: .utf8)!)
        }
        exec("""
        CREATE TABLE IF NOT EXISTS sessions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            started_at TEXT NOT NULL,
            ended_at   TEXT,
            reason     TEXT,          -- what triggered the prompt: launch/wake/unlock/session/manual
            seconds    INTEGER,       -- planned duration in seconds (input is minutes, stored ×60); bumped by "Add time"
            original_seconds INTEGER, -- planned duration stamped at creation; never changes when time is added
            focus      TEXT,
            rating     INTEGER,       -- 1..10, only for completed sessions
            status     TEXT,          -- completed / interrupted (NULL while active)
            note       TEXT,          -- optional note written when rating
            original_session_id INTEGER, -- root of a pre-empt→continued chain (NULL if this is the original)
            open_seconds_start INTEGER, -- seconds the session-start popup stayed open
            open_seconds_end   INTEGER  -- seconds the ending/rating popup stayed open
        );
        """)
        // Migrations for older DBs (each errors harmlessly if already applied).
        exec("ALTER TABLE sessions ADD COLUMN note TEXT;")
        exec("ALTER TABLE sessions RENAME COLUMN outcome TO status;")
        exec("ALTER TABLE sessions ADD COLUMN original_session_id INTEGER;")
        exec("ALTER TABLE sessions ADD COLUMN open_seconds_start INTEGER;")
        exec("ALTER TABLE sessions ADD COLUMN open_seconds_end INTEGER;")
        // Popup-open durations were first stored as rounded minutes; convert any such
        // columns to integer seconds (×60), then drop the old minute columns. Each
        // statement no-ops harmlessly once the minute columns are gone.
        exec("UPDATE sessions SET open_seconds_start = open_minutes_start * 60 WHERE open_seconds_start IS NULL AND open_minutes_start IS NOT NULL;")
        exec("UPDATE sessions SET open_seconds_end = open_minutes_end * 60 WHERE open_seconds_end IS NULL AND open_minutes_end IS NOT NULL;")
        exec("ALTER TABLE sessions DROP COLUMN open_minutes_start;")
        exec("ALTER TABLE sessions DROP COLUMN open_minutes_end;")
        // FIFO queue of upcoming sessions. Front = lowest id; "add to end" is a
        // plain insert; "pop off" deletes the lowest id.
        exec("""
        CREATE TABLE IF NOT EXISTS queue (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            seconds    INTEGER,
            focus      TEXT,
            original_session_id INTEGER, -- carries the chain root onto the resumed session
            position   INTEGER           -- explicit sort order (lower = nearer the front)
        );
        """)
        exec("ALTER TABLE queue ADD COLUMN original_session_id INTEGER;")
        // Explicit ordering column (was implicitly id ASC). Seed it from id so the
        // current order is preserved, then order by it everywhere.
        exec("ALTER TABLE queue ADD COLUMN position INTEGER;")
        exec("UPDATE queue SET position = id WHERE position IS NULL;")
        // One row per "Add time" event, so a session extended N times has N rows
        // (sessions.seconds is also bumped to the running total).
        exec("""
        CREATE TABLE IF NOT EXISTS time_additions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            added_at   TEXT NOT NULL,
            seconds    INTEGER
        );
        """)
        // One row per pre-empt. preempted_session_id is the interrupted session
        // (NULL if nothing was underway); new_session_id is the one that barged in.
        exec("""
        CREATE TABLE IF NOT EXISTS preempts (
            id                   INTEGER PRIMARY KEY AUTOINCREMENT,
            at                   TEXT NOT NULL,
            preempted_session_id INTEGER,
            new_session_id       INTEGER
        );
        """)
        // One row per pause. `ended_at` is NULL while paused (that open row is the
        // persisted "currently paused" state); `seconds` is stamped on resume.
        exec("""
        CREATE TABLE IF NOT EXISTS pauses (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            started_at TEXT NOT NULL,
            ended_at   TEXT,
            seconds    INTEGER
        );
        """)
        // Duration columns switched from minutes to integer seconds (×60), for
        // consistency with the open_seconds_* columns. Add the new column, back-fill
        // once from the old minute column, then drop it. Each statement no-ops
        // harmlessly once the minute column is gone (errors are ignored by exec).
        for table in ["sessions", "queue", "time_additions"] {
            exec("ALTER TABLE \(table) ADD COLUMN seconds INTEGER;")
            exec("UPDATE \(table) SET seconds = minutes * 60 WHERE seconds IS NULL AND minutes IS NOT NULL;")
            exec("ALTER TABLE \(table) DROP COLUMN minutes;")
        }
        // Duration a session was created with, unaffected by "Add time". New rows
        // stamp it directly. Back-fill only completed/active rows, where `seconds`
        // still holds the planned total, as (current seconds − time added). For
        // interrupted/deferred rows `seconds` was overwritten with elapsed time, so
        // the original is unrecoverable — leave it NULL (shown as "—" in history).
        exec("ALTER TABLE sessions ADD COLUMN original_seconds INTEGER;")
        exec("""
        UPDATE sessions SET original_seconds =
            seconds - COALESCE((SELECT SUM(seconds) FROM time_additions WHERE session_id = sessions.id), 0)
        WHERE original_seconds IS NULL AND (status IS NULL OR status = 'completed');
        """)
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// Insert a new in-progress session; returns its row id. `seconds` is stamped
    /// into both `seconds` (the running planned total) and `original_seconds` (fixed).
    func startSession(reason: String, seconds: Int, focus: String, originalSessionId: Int64?) -> Int64? {
        let sql = "INSERT INTO sessions (started_at, reason, seconds, original_seconds, focus, original_session_id) VALUES (?,?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, reason, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(seconds))
        sqlite3_bind_int(stmt, 4, Int32(seconds))
        sqlite3_bind_text(stmt, 5, focus, -1, SQLITE_TRANSIENT)
        if let o = originalSessionId { sqlite3_bind_int64(stmt, 6, o) } else { sqlite3_bind_null(stmt, 6) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// Add to a session's accumulated popup-open seconds. COALESCE means the first
    /// write counts from 0 (so a session closed without any popup stays NULL — the
    /// column is only ever touched when there's time to add). Multiple openings of
    /// the same popup (e.g. time's-up → "Add time" → later rate) sum together.
    private func addOpenSeconds(_ column: String, id: Int64, seconds: Int) {
        let sql = "UPDATE sessions SET \(column) = COALESCE(\(column), 0) + ? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(seconds))
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }
    func addOpenSecondsStart(id: Int64, seconds: Int) { addOpenSeconds("open_seconds_start", id: id, seconds: seconds) }
    func addOpenSecondsEnd(id: Int64, seconds: Int)   { addOpenSeconds("open_seconds_end", id: id, seconds: seconds) }

    // Bind an optional note (empty → NULL) at the given parameter index.
    private func bindNote(_ stmt: OpaquePointer?, _ idx: Int32, _ note: String) {
        if note.isEmpty { sqlite3_bind_null(stmt, idx) }
        else { sqlite3_bind_text(stmt, idx, note, -1, SQLITE_TRANSIENT) }
    }

    /// Close out a session with a status, (optionally) a rating, and a note.
    /// `openSecondsEnd` is how long the ending/rating popup stayed open (nil when
    /// closed without a popup, e.g. auto-proceed or a launch-time sweep).
    /// `elapsedSeconds`, when given, overwrites the planned `seconds` with the time
    /// actually used (e.g. completing a task early) — `original_seconds` is untouched.
    func endSession(id: Int64, status: String, rating: Int?, note: String = "",
                    openSecondsEnd: Int? = nil, elapsedSeconds: Int? = nil) {
        let sql = "UPDATE sessions SET ended_at=?, status=?, rating=?, note=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, status, -1, SQLITE_TRANSIENT)
        if let r = rating { sqlite3_bind_int(stmt, 3, Int32(r)) } else { sqlite3_bind_null(stmt, 3) }
        bindNote(stmt, 4, note)
        sqlite3_bind_int64(stmt, 5, id)
        sqlite3_step(stmt)
        if let sec = elapsedSeconds { updatePlannedSeconds(id: id, seconds: sec) }
        if let e = openSecondsEnd { addOpenSecondsEnd(id: id, seconds: e) }
    }

    /// Overwrite a session's `seconds` (the actual/planned duration). Leaves
    /// `original_seconds` alone.
    private func updatePlannedSeconds(id: Int64, seconds: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET seconds=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(seconds))
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// "Apply this time to the previous focus session": add a popup span to the
    /// session's duration (without touching end-popup-open time).
    func addToDuration(id: Int64, seconds: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET seconds = seconds + ? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(seconds))
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// Close a session as "interrupted", recording how many seconds it actually
    /// ran (overwriting the planned seconds), with an optional rating/note.
    func markInterrupted(id: Int64, elapsedSeconds: Int, rating: Int? = nil, note: String = "",
                         openSecondsEnd: Int? = nil) {
        let sql = "UPDATE sessions SET ended_at=?, status='interrupted', seconds=?, rating=?, note=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(elapsedSeconds))
        if let r = rating { sqlite3_bind_int(stmt, 3, Int32(r)) } else { sqlite3_bind_null(stmt, 3) }
        bindNote(stmt, 4, note)
        sqlite3_bind_int64(stmt, 5, id)
        sqlite3_step(stmt)
        if let e = openSecondsEnd { addOpenSecondsEnd(id: id, seconds: e) }
    }

    /// Close a session as "deferred" (to be continued later), recording how many
    /// seconds it actually ran. No rating — the work isn't finished, it's paused.
    func markDeferred(id: Int64, elapsedSeconds: Int) {
        let sql = "UPDATE sessions SET ended_at=?, status='deferred', seconds=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(elapsedSeconds))
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    /// The planned duration a session *started* with (the stamped `original_seconds`,
    /// unaffected by "Add time"). Used to re-queue a deferred task with its full
    /// original duration.
    func plannedSecondsAtStart(id: Int64) -> Int {
        let sql = "SELECT COALESCE(original_seconds, seconds) FROM sessions WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Rename a session's focus (inline edit from the pill).
    func renameSession(id: Int64, focus: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET focus=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, focus, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    /// Log an "Add time" event and bump the session's total seconds.
    func addTime(sessionId: Int64, seconds: Int) {
        var ins: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO time_additions (session_id, added_at, seconds) VALUES (?,?,?);",
                              -1, &ins, nil) == SQLITE_OK {
            sqlite3_bind_int64(ins, 1, sessionId)
            sqlite3_bind_text(ins, 2, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(ins, 3, Int32(seconds))
            sqlite3_step(ins)
        }
        sqlite3_finalize(ins)

        var upd: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE sessions SET seconds = seconds + ? WHERE id = ?;",
                              -1, &upd, nil) == SQLITE_OK {
            sqlite3_bind_int(upd, 1, Int32(seconds))
            sqlite3_bind_int64(upd, 2, sessionId)
            sqlite3_step(upd)
        }
        sqlite3_finalize(upd)
    }

    /// Open a pause (row with NULL ended_at) for a session.
    func startPause(sessionId: Int64, at: Date) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO pauses (session_id, started_at) VALUES (?,?);", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sessionId)
        sqlite3_bind_text(stmt, 2, isoParser.string(from: at), -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Close the open pause for a session (resume), stamping its duration in seconds.
    func endPause(sessionId: Int64, seconds: Int) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE pauses SET ended_at=?, seconds=? WHERE session_id=? AND ended_at IS NULL;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(seconds))
        sqlite3_bind_int64(stmt, 3, sessionId)
        sqlite3_step(stmt)
    }

    /// Close any open pause for a session at launch (the process died mid-pause),
    /// computing its duration from the timestamps — the downtime counts as pause.
    func closeOpenPause(sessionId: Int64) {
        let sql = "UPDATE pauses SET ended_at=?, seconds=CAST(ROUND((julianday(?) - julianday(started_at)) * 86400) AS INTEGER) WHERE session_id=? AND ended_at IS NULL;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let now = isoNow()
        sqlite3_bind_text(stmt, 1, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, now, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 3, sessionId)
        sqlite3_step(stmt)
    }

    /// Total seconds a session has spent paused (closed pauses only).
    func totalPausedSeconds(sessionId: Int64) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(seconds), 0) FROM pauses WHERE session_id=? AND ended_at IS NOT NULL;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sessionId)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Record a pre-empt: `preemptedSessionId` = the interrupted session (nil if
    /// none was underway), `newSessionId` = the session that started in its place.
    func recordPreempt(preemptedSessionId: Int64?, newSessionId: Int64?) {
        let sql = "INSERT INTO preempts (at, preempted_session_id, new_session_id) VALUES (?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        if let p = preemptedSessionId { sqlite3_bind_int64(stmt, 2, p) } else { sqlite3_bind_null(stmt, 2) }
        if let n = newSessionId { sqlite3_bind_int64(stmt, 3, n) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_step(stmt)
    }

    /// Sessions never closed out (ended_at IS NULL), newest first — i.e. a
    /// session that was live when the process died (uninstall/crash/reboot).
    func openSessions() -> [ActiveSession] {
        let sql = "SELECT id, started_at, seconds, focus, original_session_id FROM sessions WHERE ended_at IS NULL ORDER BY id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ActiveSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let orig = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(ActiveSession(id: sqlite3_column_int64(stmt, 0),
                                      startedAt: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                                      seconds: Int(sqlite3_column_int(stmt, 2)),
                                      focus: focus, originalSessionId: orig))
        }
        return rows
    }

    /// Completed sessions with no rating yet (deferred), oldest first.
    func unratedCompleted() -> [ActiveSession] {
        let sql = """
        SELECT id, started_at, seconds, focus, original_session_id FROM sessions
        WHERE status = 'completed' AND rating IS NULL
        ORDER BY started_at ASC, id ASC;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ActiveSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let orig = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(ActiveSession(id: sqlite3_column_int64(stmt, 0),
                                      startedAt: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                                      seconds: Int(sqlite3_column_int(stmt, 2)),
                                      focus: focus, originalSessionId: orig))
        }
        return rows
    }

    func unratedCount() -> Int {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM sessions WHERE status = 'completed' AND rating IS NULL;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Set a rating and note on an already-completed session ("Rate unrated
    /// sessions"). `openSecondsEnd` accumulates how long that (deferred) rating
    /// popup stayed open, on top of anything already recorded for the session.
    func setRating(id: Int64, rating: Int, note: String = "", openSecondsEnd: Int? = nil) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET rating=?, note=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(rating))
        bindNote(stmt, 2, note)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
        if let e = openSecondsEnd { addOpenSecondsEnd(id: id, seconds: e) }
    }

    /// Most recent sessions, newest first, for the history window.
    func recent(limit: Int = 500) -> [SessionRow] {
        let sql = """
        SELECT id, started_at, ended_at, seconds, focus, rating, status, note,
               open_seconds_start, open_seconds_end, original_seconds
        FROM sessions ORDER BY id DESC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        func text(_ col: Int32) -> String? {
            guard let c = sqlite3_column_text(stmt, col) else { return nil }
            return String(cString: c)
        }

        func intOrNil(_ col: Int32) -> Int? {
            sqlite3_column_type(stmt, col) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, col))
        }
        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(SessionRow(
                id: sqlite3_column_int64(stmt, 0),
                startedAt: text(1) ?? "",
                endedAt: text(2),
                seconds: Int(sqlite3_column_int(stmt, 3)),
                focus: text(4) ?? "",
                rating: intOrNil(5),
                status: text(6),
                note: text(7),
                openSecondsStart: intOrNil(8),
                openSecondsEnd: intOrNil(9),
                originalSeconds: intOrNil(10)))
        }
        return rows
    }

    /// Permanently delete the given sessions from history.
    func deleteSessions(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let placeholders = ids.map { _ in "?" }.joined(separator: ",")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM sessions WHERE id IN (\(placeholders));", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (i, id) in ids.enumerated() { sqlite3_bind_int64(stmt, Int32(i + 1), id) }
        sqlite3_step(stmt)
    }

    /// Total number of recorded sessions (for the history menu label).
    func sessionCount() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sessions;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    // MARK: - Queue

    /// Number of focuses currently waiting in the queue.
    func queueCount() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM queue;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// All queued focuses, front (next up) first.
    func queueItems() -> [QueueItem] {
        let sql = "SELECT id, seconds, focus, original_session_id FROM queue ORDER BY position ASC, id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [QueueItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let orig = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            rows.append(QueueItem(id: sqlite3_column_int64(stmt, 0),
                                  seconds: Int(sqlite3_column_int(stmt, 1)),
                                  focus: focus, originalSessionId: orig))
        }
        return rows
    }

    /// Append a focus to the end of the queue (position = current max + 1).
    /// `originalSessionId` carries the chain root when appending a deferred task's
    /// continuation (nil for a plain new "Add to queue").
    func enqueue(focus: String, seconds: Int, originalSessionId: Int64? = nil) {
        let sql = "INSERT INTO queue (created_at, seconds, focus, original_session_id, position) VALUES (?,?,?,?, (SELECT COALESCE(MAX(position), 0) + 1 FROM queue));"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(seconds))
        sqlite3_bind_text(stmt, 3, focus, -1, SQLITE_TRANSIENT)
        if let o = originalSessionId { sqlite3_bind_int64(stmt, 4, o) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_step(stmt)
    }

    /// Insert at the FRONT of the queue (used when pre-empting the current focus):
    /// position = current min - 1. `originalSessionId` carries the chain root onto
    /// the eventual resumed session.
    func enqueueFront(focus: String, seconds: Int, originalSessionId: Int64?) {
        let sql = """
        INSERT INTO queue (created_at, seconds, focus, original_session_id, position)
        VALUES (?, ?, ?, ?, (SELECT COALESCE(MIN(position), 0) - 1 FROM queue));
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(seconds))
        sqlite3_bind_text(stmt, 3, focus, -1, SQLITE_TRANSIENT)
        if let o = originalSessionId { sqlite3_bind_int64(stmt, 4, o) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_step(stmt)
    }

    /// Persist a new front-to-back order: `ids` in the desired order get
    /// position 0, 1, 2, … in one transaction.
    func reorderQueue(ids: [Int64]) {
        exec("BEGIN;")
        let sql = "UPDATE queue SET position = ? WHERE id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            for (index, id) in ids.enumerated() {
                sqlite3_bind_int(stmt, 1, Int32(index))
                sqlite3_bind_int64(stmt, 2, id)
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        }
        sqlite3_finalize(stmt)
        exec("COMMIT;")
    }

    /// The next queued focus (front of the FIFO), or nil if the queue is empty.
    func frontOfQueue() -> QueueItem? {
        let sql = "SELECT id, seconds, focus, original_session_id FROM queue ORDER BY position ASC, id ASC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let orig = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
        return QueueItem(id: sqlite3_column_int64(stmt, 0),
                         seconds: Int(sqlite3_column_int(stmt, 1)),
                         focus: focus, originalSessionId: orig)
    }

    func removeFromQueue(id: Int64) {
        let sql = "DELETE FROM queue WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }

    func clearQueue() { sqlite3_exec(db, "DELETE FROM queue;", nil, nil, nil) }
}

struct QueueItem {
    let id: Int64
    let seconds: Int
    let focus: String
    let originalSessionId: Int64?
}

struct ActiveSession {
    let id: Int64
    let startedAt: String
    let seconds: Int
    let focus: String
    let originalSessionId: Int64?
}

struct SessionRow {
    let id: Int64
    let startedAt: String
    let endedAt: String?
    let seconds: Int
    let focus: String
    let rating: Int?
    let status: String?
    let note: String?
    let openSecondsStart: Int?
    let openSecondsEnd: Int?
    let originalSeconds: Int?   // nil for old interrupted/deferred rows (unrecoverable)
}
