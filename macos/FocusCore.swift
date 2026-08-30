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

/// Parse the session-setup duration field. A plain number is whole minutes
/// ("25" -> 1500). If a colon is present it's MINUTES:SECONDS ("2:30" -> 150,
/// "0:45" -> 45, ":30" -> 30, "2:" -> 120). Returns total seconds, or nil if it
/// can't be parsed. Non-negative only.
func parseDurationSeconds(_ text: String) -> Int? {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.isEmpty { return nil }
    guard let colon = t.firstIndex(of: ":") else {
        guard let m = Int(t), m >= 0 else { return nil }
        return m * 60
    }
    let minStr = String(t[..<colon]).trimmingCharacters(in: .whitespaces)
    let secStr = String(t[t.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    let minutes = minStr.isEmpty ? 0 : Int(minStr)
    let seconds = secStr.isEmpty ? 0 : Int(secStr)
    guard let m = minutes, let s = seconds, m >= 0, s >= 0 else { return nil }
    return m * 60 + s
}

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

/// Example focuses — one is picked at random for the session-setup field's
/// placeholder. A deliberate mix of everyday "get it done" tasks and self-care /
/// mindfulness / health prompts, so the nudge cuts both ways.
let focusSuggestions: [String] = [
    // Work & everyday tasks
    "Reply to overdue emails",
    "Write the weekly status update",
    "Review the open pull request",
    "Draft the project proposal",
    "Pay the bills",
    "Plan tomorrow's schedule",
    "Reach inbox zero",
    "Outline the presentation",
    "Fix the failing test",
    "Book the dentist appointment",
    "Do the laundry",
    "Tidy the kitchen",
    "Update the budget",
    "Prep for the 1:1",
    "Read a chapter",
    "Declutter the desk",
    // Self-care, mindfulness & health
    "Meditate for 10 minutes",
    "Take a mindful walk",
    "Stretch and loosen up",
    "Do some deep breathing",
    "Drink a glass of water",
    "Step away from the screen",
    "Do a slow body scan",
    "Journal three gratitudes",
    "Go for a run",
    "Do a little yoga",
    "Rest your eyes (20-20-20)",
    "Make tea and pause",
    "Sit quietly, no phone",
    "Get some sunlight",
    "Call a friend",
    "Take a short nap",
]

/// A random example focus for the placeholder text.
func randomFocusSuggestion() -> String {
    focusSuggestions.randomElement() ?? "Ship the focus pill"
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

        // --- tasks + intervals (the new model) ---------------------------------
        // A `task` is the unit of identity/estimate/rating/hierarchy; an `interval`
        // is one timed chunk of work on a task (today's `sessions` row). These are
        // created here (empty on a fresh or not-yet-migrated DB); migrateSessions-
        // ToTasks() populates them from legacy `sessions`. Ids are preserved across
        // the migration (interval.id == old session.id, task.id == chain-root id),
        // so the pauses/time_additions/preempts tables keep referring by the same
        // ids without a repoint.
        exec("""
        CREATE TABLE IF NOT EXISTS tasks (
            id             INTEGER PRIMARY KEY,   -- migrated: = chain-root session id
            parent_task_id INTEGER,               -- for future subtasks (NULL for now)
            created_at     TEXT,
            focus          TEXT,
            estimate_seconds INTEGER,             -- original planned duration
            status         TEXT,                  -- completed/interrupted/deferred (NULL while active)
            rating         INTEGER,               -- 1..10 (one per task)
            note           TEXT
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS intervals (
            id           INTEGER PRIMARY KEY,      -- migrated: = old session id
            task_id      INTEGER NOT NULL,
            started_at   TEXT,
            ended_at     TEXT,
            seconds      INTEGER,                  -- ACTUAL elapsed for this chunk
            reason       TEXT,
            open_seconds_start INTEGER,
            open_seconds_end   INTEGER,
            rating       INTEGER                   -- optional per-interval rating (unused
                                                   -- in the UI for now; kept so the split
                                                   -- migration is lossless and the option
                                                   -- stays open — headline rating is on tasks)
        );
        """)
        exec("ALTER TABLE intervals ADD COLUMN rating INTEGER;")  // for any DB that made `intervals` before this column
        // A queued item may reference an existing task to RESUME (deferred/pre-empted)
        // — task_id set — or be a fresh focus that mints a task when started (NULL).
        exec("ALTER TABLE queue ADD COLUMN task_id INTEGER;")

        // Populate tasks/intervals from legacy `sessions` (once, guarded, INSERT-only —
        // the sessions table is left intact as an in-DB fallback).
        migrateSessionsToTasks()
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
        let sql = "SELECT id, seconds, focus, original_session_id, task_id FROM queue ORDER BY position ASC, id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [QueueItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let orig = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            let taskId = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(QueueItem(id: sqlite3_column_int64(stmt, 0),
                                  seconds: Int(sqlite3_column_int(stmt, 1)),
                                  focus: focus, originalSessionId: orig, taskId: taskId))
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
        let sql = "SELECT id, seconds, focus, original_session_id, task_id FROM queue ORDER BY position ASC, id ASC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let orig = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
        let taskId = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
        return QueueItem(id: sqlite3_column_int64(stmt, 0),
                         seconds: Int(sqlite3_column_int(stmt, 1)),
                         focus: focus, originalSessionId: orig, taskId: taskId)
    }

    /// Remove any queue rows referencing a task (used when giving up on it).
    func removeQueuedTask(taskId: Int64) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "DELETE FROM queue WHERE task_id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, taskId)
        sqlite3_step(s)
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

    // MARK: - Tasks + intervals (new model)

    /// Number of intervals — used to detect whether the split migration has run.
    func intervalCount() -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM intervals;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }

    /// Whether a legacy `sessions` table exists (a pre-refactor DB).
    private func hasSessionsTable() -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM sqlite_master WHERE type='table' AND name='sessions';", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// One-time transform of legacy `sessions` rows into `tasks` + `intervals`.
    /// - Each pre-empt→continued chain (grouped by COALESCE(original_session_id, id))
    ///   becomes ONE task; every session in it becomes an interval of that task.
    /// - task.focus/estimate come from the EARLIEST fragment (the clean original name
    ///   and the duration it was created with); task.status/rating/note come from the
    ///   LAST fragment — the intentional "collapse per-fragment ratings to one" step.
    /// - Ids are preserved (task.id = chain-root id, interval.id = old session id),
    ///   so pauses/time_additions/preempts keep referring by the same ids.
    /// Idempotent: no-ops if intervals are already populated or there's no `sessions`.
    func migrateSessionsToTasks() {
        guard hasSessionsTable(), intervalCount() == 0 else { return }
        exec("BEGIN;")
        exec("""
        INSERT INTO tasks (id, parent_task_id, created_at, focus, estimate_seconds, status, rating, note)
        SELECT grp.root_id, NULL, first.started_at, first.focus,
               COALESCE(first.original_seconds, first.seconds),
               last.status, last.rating, last.note
        FROM (SELECT COALESCE(original_session_id, id) AS root_id,
                     MIN(id) AS first_id, MAX(id) AS last_id
              FROM sessions GROUP BY COALESCE(original_session_id, id)) grp
        JOIN sessions first ON first.id = grp.first_id
        JOIN sessions last  ON last.id  = grp.last_id;
        """)
        exec("""
        INSERT INTO intervals (id, task_id, started_at, ended_at, seconds, reason, open_seconds_start, open_seconds_end, rating)
        SELECT id, COALESCE(original_session_id, id), started_at, ended_at, seconds, reason, open_seconds_start, open_seconds_end, rating
        FROM sessions;
        """)
        // Point any in-flight queued continuations at their migrated task (the chain
        // root id == the new task id), so resuming them attaches to the same task.
        exec("UPDATE queue SET task_id = original_session_id WHERE task_id IS NULL AND original_session_id IS NOT NULL;")
        exec("COMMIT;")
    }

    /// All tasks, newest first.
    func allTasks() -> [TaskRow] {
        let sql = "SELECT id, parent_task_id, created_at, focus, estimate_seconds, status, rating, note FROM tasks ORDER BY id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, c)) }
        func int64OrNil(_ c: Int32) -> Int64? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, c) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(stmt, c).map { String(cString: $0) } }
        var rows: [TaskRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(TaskRow(id: sqlite3_column_int64(stmt, 0),
                                parentTaskId: int64OrNil(1),
                                createdAt: text(2),
                                focus: text(3) ?? "",
                                estimateSeconds: intOrNil(4),
                                status: text(5),
                                rating: intOrNil(6),
                                note: text(7)))
        }
        return rows
    }

    /// Intervals for a task, earliest first.
    func intervals(forTask taskId: Int64) -> [Interval] {
        let sql = "SELECT id, task_id, started_at, ended_at, seconds, reason, open_seconds_start, open_seconds_end, rating FROM intervals WHERE task_id=? ORDER BY id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, taskId)
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(stmt, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, c)) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(stmt, c).map { String(cString: $0) } }
        var rows: [Interval] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(Interval(id: sqlite3_column_int64(stmt, 0),
                                 taskId: sqlite3_column_int64(stmt, 1),
                                 startedAt: text(2) ?? "",
                                 endedAt: text(3),
                                 seconds: Int(sqlite3_column_int(stmt, 4)),
                                 reason: text(5),
                                 openSecondsStart: intOrNil(6),
                                 openSecondsEnd: intOrNil(7),
                                 rating: intOrNil(8)))
        }
        return rows
    }

    // MARK: - Tasks + intervals: write API (Stage 1b)
    // Mirrors the old session flows in task/interval terms. Not yet called by the
    // app (that's 1c) — built and tested first. A "task" is worked in one or more
    // "intervals"; the active work is a task with an open (unfinished) interval.

    /// Create a task and open its first interval. Returns both ids.
    func startTask(reason: String, estimateSeconds: Int, focus: String,
                   parentTaskId: Int64? = nil) -> (taskId: Int64, intervalId: Int64)? {
        var t: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO tasks (parent_task_id, created_at, focus, estimate_seconds) VALUES (?,?,?,?);", -1, &t, nil) == SQLITE_OK else { return nil }
        if let p = parentTaskId { sqlite3_bind_int64(t, 1, p) } else { sqlite3_bind_null(t, 1) }
        sqlite3_bind_text(t, 2, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(t, 3, focus, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(t, 4, Int32(estimateSeconds))
        let done = sqlite3_step(t) == SQLITE_DONE
        sqlite3_finalize(t)
        guard done else { return nil }
        let taskId = sqlite3_last_insert_rowid(db)
        guard let intervalId = startInterval(taskId: taskId, reason: reason) else { return nil }
        return (taskId, intervalId)
    }

    /// Open a new interval (work chunk) on an existing task — the resume/continue
    /// path. Attaching to the SAME task (instead of spawning a "(continued)" row)
    /// is what makes a task cohesive. Returns the new interval id.
    func startInterval(taskId: Int64, reason: String) -> Int64? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO intervals (task_id, started_at, reason) VALUES (?,?,?);", -1, &s, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, taskId)
        sqlite3_bind_text(s, 2, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(s, 3, reason, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(s) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// Accumulate popup-open seconds on an interval (COALESCE from 0, like sessions).
    private func addIntervalOpenSeconds(_ column: String, id: Int64, seconds: Int) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE intervals SET \(column)=COALESCE(\(column),0)+? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(seconds)); sqlite3_bind_int64(s, 2, id); sqlite3_step(s)
    }
    func addIntervalOpenSecondsStart(id: Int64, seconds: Int) { addIntervalOpenSeconds("open_seconds_start", id: id, seconds: seconds) }
    func addIntervalOpenSecondsEnd(id: Int64, seconds: Int)   { addIntervalOpenSeconds("open_seconds_end", id: id, seconds: seconds) }

    /// Close an interval, stamping its ACTUAL elapsed seconds (+ optional end popup-open).
    func endInterval(id: Int64, elapsedSeconds: Int, openSecondsEnd: Int? = nil) {
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE intervals SET ended_at=?, seconds=? WHERE id=?;", -1, &s, nil) == SQLITE_OK {
            sqlite3_bind_text(s, 1, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(s, 2, Int32(elapsedSeconds))
            sqlite3_bind_int64(s, 3, id)
            sqlite3_step(s)
        }
        sqlite3_finalize(s)
        if let e = openSecondsEnd { addIntervalOpenSecondsEnd(id: id, seconds: e) }
    }

    /// "Apply this popup time": credit seconds to an interval's actual elapsed
    /// (the new-model equivalent of addToDuration).
    func addToInterval(id: Int64, seconds: Int) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE intervals SET seconds = COALESCE(seconds,0) + ? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(seconds)); sqlite3_bind_int64(s, 2, id); sqlite3_step(s)
    }

    /// Mark a task finished. `status` ∈ {completed, interrupted, deferred}. Optional
    /// rating/note (rating stays nil for deferred). Does NOT close the interval —
    /// call endInterval first for the chunk being closed.
    func finishTask(id: Int64, status: String, rating: Int? = nil, note: String = "") {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET status=?, rating=?, note=? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, status, -1, SQLITE_TRANSIENT)
        if let r = rating { sqlite3_bind_int(s, 2, Int32(r)) } else { sqlite3_bind_null(s, 2) }
        bindNote(s, 3, note)
        sqlite3_bind_int64(s, 4, id)
        sqlite3_step(s)
    }

    /// Add time to a task's estimate (the countdown target grows). The estimate is
    /// now the source of truth, so no separate log is kept (unlike old add-time,
    /// which existed to reconstruct original_seconds).
    func addTimeToTask(id: Int64, seconds: Int) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET estimate_seconds = COALESCE(estimate_seconds,0) + ? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(seconds)); sqlite3_bind_int64(s, 2, id); sqlite3_step(s)
    }

    /// Rename a task's focus.
    func renameTask(id: Int64, focus: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET focus=? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, focus, -1, SQLITE_TRANSIENT); sqlite3_bind_int64(s, 2, id); sqlite3_step(s)
    }

    /// One task by id.
    func task(id: Int64) -> TaskRow? {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id, parent_task_id, created_at, focus, estimate_seconds, status, rating, note FROM tasks WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, id)
        guard sqlite3_step(s) == SQLITE_ROW else { return nil }
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c)) }
        func int64OrNil(_ c: Int32) -> Int64? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
        return TaskRow(id: sqlite3_column_int64(s, 0), parentTaskId: int64OrNil(1), createdAt: text(2),
                       focus: text(3) ?? "", estimateSeconds: intOrNil(4), status: text(5),
                       rating: intOrNil(6), note: text(7))
    }

    /// Total ACTUAL seconds worked on a task (sum of its CLOSED intervals).
    func spentSeconds(taskId: Int64) -> Int {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COALESCE(SUM(seconds),0) FROM intervals WHERE task_id=? AND ended_at IS NOT NULL;", -1, &s, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, taskId)
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }

    /// Remaining seconds on a task's estimate: estimate − spent.
    func remainingSeconds(taskId: Int64) -> Int {
        guard let t = task(id: taskId) else { return 0 }
        return (t.estimateSeconds ?? 0) - spentSeconds(taskId: taskId)
    }

    /// The open (unfinished) interval on a task, if any — the chunk currently underway.
    func openInterval(taskId: Int64) -> Interval? {
        intervals(forTask: taskId).first { $0.endedAt == nil }
    }

    /// All open (unfinished) intervals across tasks, newest first — work that was
    /// underway when the process died (restart reconstruction).
    func openIntervals() -> [Interval] {
        let sql = "SELECT id, task_id, started_at, ended_at, seconds, reason, open_seconds_start, open_seconds_end, rating FROM intervals WHERE ended_at IS NULL ORDER BY id DESC;"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c)) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
        var rows: [Interval] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(Interval(id: sqlite3_column_int64(s, 0), taskId: sqlite3_column_int64(s, 1),
                                 startedAt: text(2) ?? "", endedAt: text(3),
                                 seconds: Int(sqlite3_column_int(s, 4)), reason: text(5),
                                 openSecondsStart: intOrNil(6), openSecondsEnd: intOrNil(7), rating: intOrNil(8)))
        }
        return rows
    }

    /// Every interval joined to its task's focus, newest first — the global
    /// chronological timeline for the History "Intervals" view.
    func intervalHistory(limit: Int = 2000) -> [IntervalHistoryRow] {
        let sql = """
        SELECT iv.id, iv.task_id, t.focus, iv.started_at, iv.ended_at, iv.seconds, iv.reason, iv.rating
        FROM intervals iv LEFT JOIN tasks t ON t.id = iv.task_id
        ORDER BY iv.started_at DESC, iv.id DESC LIMIT ?;
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(limit))
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c)) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
        var rows: [IntervalHistoryRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(IntervalHistoryRow(
                id: sqlite3_column_int64(s, 0), taskId: sqlite3_column_int64(s, 1),
                taskFocus: text(2) ?? "", startedAt: text(3) ?? "", endedAt: text(4),
                seconds: Int(sqlite3_column_int(s, 5)), reason: text(6), rating: intOrNil(7)))
        }
        return rows
    }

    /// Delete individual intervals by id (Intervals-view delete — e.g. a bogus
    /// left-running chunk). The parent task's rollup shrinks accordingly.
    func deleteIntervals(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        var s: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM intervals WHERE id IN (\(ph));", -1, &s, nil) == SQLITE_OK {
            for (i, id) in ids.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), id) }
            sqlite3_step(s)
        }
        sqlite3_finalize(s)
    }

    /// Delete tasks and their intervals by task id (history view delete).
    func deleteTasks(ids: [Int64]) {
        guard !ids.isEmpty else { return }
        let ph = ids.map { _ in "?" }.joined(separator: ",")
        for sql in ["DELETE FROM intervals WHERE task_id IN (\(ph));", "DELETE FROM tasks WHERE id IN (\(ph));"] {
            var s: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK {
                for (i, id) in ids.enumerated() { sqlite3_bind_int64(s, Int32(i + 1), id) }
                sqlite3_step(s)
            }
            sqlite3_finalize(s)
        }
    }

    /// Total number of tasks (for the history menu label).
    func taskCount() -> Int {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tasks;", -1, &s, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }

    /// Completed tasks that were never rated, newest first (for "Rate unrated").
    func unratedCompletedTasks() -> [TaskRow] {
        let sql = "SELECT id, parent_task_id, created_at, focus, estimate_seconds, status, rating, note FROM tasks WHERE status='completed' AND rating IS NULL ORDER BY id DESC;"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c)) }
        func int64OrNil(_ c: Int32) -> Int64? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
        var rows: [TaskRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(TaskRow(id: sqlite3_column_int64(s, 0), parentTaskId: int64OrNil(1), createdAt: text(2),
                                focus: text(3) ?? "", estimateSeconds: intOrNil(4), status: text(5),
                                rating: intOrNil(6), note: text(7)))
        }
        return rows
    }

    /// Count of completed-but-unrated tasks (menu label).
    func unratedTaskCount() -> Int {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM tasks WHERE status='completed' AND rating IS NULL;", -1, &s, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(s) }
        return sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int(s, 0)) : 0
    }

    /// Set a task's rating/note (retroactive rating from "Rate unrated").
    func setTaskRating(id: Int64, rating: Int, note: String = "") {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET rating=?, note=? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(rating))
        bindNote(s, 2, note)
        sqlite3_bind_int64(s, 3, id)
        sqlite3_step(s)
    }

    /// Enqueue a focus. `taskId` set = resume that existing task (deferred/pre-empted);
    /// nil = a fresh focus that mints a task when started. `front` inserts at the head.
    func enqueueTask(focus: String, estimateSeconds: Int, taskId: Int64? = nil, front: Bool = false) {
        let pos = front ? "(SELECT COALESCE(MIN(position), 0) - 1 FROM queue)"
                        : "(SELECT COALESCE(MAX(position), 0) + 1 FROM queue)"
        let sql = "INSERT INTO queue (created_at, seconds, focus, task_id, position) VALUES (?,?,?,?, \(pos));"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(s, 2, Int32(estimateSeconds))
        sqlite3_bind_text(s, 3, focus, -1, SQLITE_TRANSIENT)
        if let t = taskId { sqlite3_bind_int64(s, 4, t) } else { sqlite3_bind_null(s, 4) }
        sqlite3_step(s)
    }

    /// History rolled up to one row per task, newest first: each task with its
    /// aggregate actual time, interval count, and start/end span. This is what the
    /// tasks-based See History view renders (one row per task, not per fragment).
    func taskHistory(limit: Int = 500) -> [TaskHistoryRow] {
        // `endedAt` is the task's FINISH time — non-null only when the task reached a
        // terminal status (completed/interrupted). A task that merely has closed
        // intervals but is still in progress (deferred / paused-in-queue / running)
        // has ended=NULL → shows "—". `lastActivity` (the most recent interval
        // moment, open interval included) is a hidden value for recency sorting.
        let sql = """
        SELECT t.id, t.focus, t.estimate_seconds, t.status, t.rating, t.note,
               COALESCE(SUM(iv.seconds), 0), COUNT(iv.id),
               MIN(iv.started_at),
               CASE WHEN t.status IN ('completed','interrupted','abandoned') THEN MAX(iv.ended_at) END,
               MAX(COALESCE(iv.ended_at, iv.started_at))
        FROM tasks t LEFT JOIN intervals iv ON iv.task_id = t.id
        GROUP BY t.id ORDER BY t.id DESC LIMIT ?;
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(limit))
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c)) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
        var rows: [TaskHistoryRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(TaskHistoryRow(
                id: sqlite3_column_int64(s, 0),
                focus: text(1) ?? "",
                estimateSeconds: intOrNil(2),
                status: text(3),
                rating: intOrNil(4),
                note: text(5),
                actualSeconds: Int(sqlite3_column_int(s, 6)),
                intervalCount: Int(sqlite3_column_int(s, 7)),
                startedAt: text(8),
                endedAt: text(9),
                lastActivity: text(10)))
        }
        return rows
    }
}

struct QueueItem {
    let id: Int64
    let seconds: Int
    let focus: String
    let originalSessionId: Int64?
    let taskId: Int64?           // new model: the task to resume (nil = mint a fresh task)
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

// New model. `TaskRow` (not `Task`, to avoid shadowing Swift's concurrency type)
// is the unit of identity/estimate/rating; `Interval` is one timed chunk of work.
struct TaskRow {
    let id: Int64
    let parentTaskId: Int64?
    let createdAt: String?
    let focus: String
    let estimateSeconds: Int?
    let status: String?
    let rating: Int?
    let note: String?
}

struct Interval {
    let id: Int64
    let taskId: Int64
    let startedAt: String
    let endedAt: String?
    let seconds: Int          // actual elapsed for this chunk
    let reason: String?
    let openSecondsStart: Int?
    let openSecondsEnd: Int?
    let rating: Int?          // optional per-interval rating (unused in the UI for now)
}

// One row per interval for the History "Intervals" timeline (interval + its task's focus).
struct IntervalHistoryRow {
    let id: Int64
    let taskId: Int64
    let taskFocus: String
    let startedAt: String
    let endedAt: String?
    let seconds: Int
    let reason: String?
    let rating: Int?
}

// One row per task for the See History view: the task plus its rolled-up totals.
struct TaskHistoryRow {
    let id: Int64
    let focus: String
    let estimateSeconds: Int?
    let status: String?
    let rating: Int?
    let note: String?
    let actualSeconds: Int    // Σ of the task's interval seconds
    let intervalCount: Int
    let startedAt: String?    // first interval start
    let endedAt: String?      // FINISH time (nil unless completed/interrupted)
    let lastActivity: String? // most recent interval moment (open included) — recency sort
}
