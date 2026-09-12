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

// Column readers — nil-aware wrappers over the sqlite3_column_* family, shared by the
// row-building queries instead of re-declaring these as nested closures in each method.
func colInt(_ s: OpaquePointer?, _ c: Int32) -> Int? {
    sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c))
}
func colInt64(_ s: OpaquePointer?, _ c: Int32) -> Int64? {
    sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c)
}
func colText(_ s: OpaquePointer?, _ c: Int32) -> String? {
    sqlite3_column_text(s, c).map { String(cString: $0) }
}

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
        // Schema baseline v1. Tables are created at their final shape — the old
        // incremental CREATE+ALTER chain and the one-time sessions→tasks migration were
        // squashed here once the live DB reached this shape. To upgrade an older-format
        // DB, check out the `pre-squash-migrations` git tag (its migration chain), open
        // the DB once, then switch back. Future changes: bump `PRAGMA user_version` and
        // guard a migration block on it. Legacy `sessions` is intentionally not
        // recreated — any existing DB keeps its copy as a harmless leftover.
        exec("""
        CREATE TABLE IF NOT EXISTS queue (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            seconds    INTEGER,           -- remaining-time snapshot for display (focus lives on the task)
            original_session_id INTEGER, -- vestigial legacy chain-root carrier (unused; kept nullable)
            position   INTEGER,          -- explicit sort order (lower = nearer the front)
            task_id    INTEGER           -- the task this row plans/resumes (always set)
        );
        """)
        // One row per "Add time" event; `session_id` is the interval id it extends.
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
        // --- tasks + intervals (the core model) --------------------------------
        // A `task` is the unit of identity/estimate/rating/hierarchy; an `interval`
        // is one timed chunk of work on a task. The aux tables (time_additions,
        // preempts, pauses) key off interval ids.
        exec("""
        CREATE TABLE IF NOT EXISTS tasks (
            id             INTEGER PRIMARY KEY,
            parent_task_id INTEGER,               -- subtask link (NULL = top-level)
            created_at     TEXT,
            focus          TEXT,
            estimate_seconds INTEGER,             -- WORKING estimate (grown by Add time / auto-extend); drives the countdown
            original_estimate_seconds INTEGER,    -- first guess, stamped at creation, never changed — for calibration
            status         TEXT,                  -- completed/interrupted/deferred (NULL while active)
            rating         INTEGER,               -- 1..10 (one per task)
            note           TEXT
        );
        """)
        exec("""
        CREATE TABLE IF NOT EXISTS intervals (
            id           INTEGER PRIMARY KEY,
            task_id      INTEGER NOT NULL,
            started_at   TEXT,
            ended_at     TEXT,
            seconds      INTEGER,                  -- ACTUAL elapsed for this chunk
            reason       TEXT,
            open_seconds_start INTEGER,
            open_seconds_end   INTEGER,
            rating       INTEGER                   -- optional per-interval rating (headline rating is on tasks)
        );
        """)
        exec("PRAGMA user_version = 1;")   // schema baseline; future migrations guard on this
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }



    // Bind an optional note (empty → NULL) at the given parameter index.
    private func bindNote(_ stmt: OpaquePointer?, _ idx: Int32, _ note: String) {
        if note.isEmpty { sqlite3_bind_null(stmt, idx) }
        else { sqlite3_bind_text(stmt, idx, note, -1, SQLITE_TRANSIENT) }
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

    /// The start time of a session's currently-open pause (process quit mid-pause), or
    /// nil if it isn't paused. Lets restart preserve the paused state instead of
    /// auto-resuming (folding the downtime into pause via closeOpenPause).
    func openPauseStart(sessionId: Int64) -> Date? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT started_at FROM pauses WHERE session_id=? AND ended_at IS NULL ORDER BY id DESC LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, sessionId)
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return isoParser.date(from: String(cString: c))
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
        let sql = "SELECT q.id, q.seconds, t.focus, q.original_session_id, q.task_id FROM queue q LEFT JOIN tasks t ON t.id = q.task_id ORDER BY q.position ASC, q.id ASC;"
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
        let sql = "SELECT q.id, q.seconds, t.focus, q.original_session_id, q.task_id FROM queue q LEFT JOIN tasks t ON t.id = q.task_id ORDER BY q.position ASC, q.id ASC LIMIT 1;"
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

    func clearQueue() {
        // Never-started plans are kept as abandoned records (durable identity); started
        // set-aside tasks are just unqueued. Then drop every queue row.
        exec("UPDATE tasks SET status='abandoned' WHERE status='queued' AND id IN (SELECT task_id FROM queue WHERE task_id IS NOT NULL);")
        exec("DELETE FROM queue;")
    }

    // MARK: - Tasks + intervals (new model)

    /// All tasks, newest first.
    /// Run a standard task-columns SELECT (`TaskRow.columns`) and build the rows. `bind`
    /// binds any `?` parameters. All the single-table task reads share this.
    private func queryTasks(_ sql: String, bind: (OpaquePointer?) -> Void = { _ in }) -> [TaskRow] {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        bind(s)
        var rows: [TaskRow] = []
        while sqlite3_step(s) == SQLITE_ROW { rows.append(TaskRow(row: s)) }
        return rows
    }

    func allTasks() -> [TaskRow] {
        queryTasks("SELECT \(TaskRow.columns) FROM tasks ORDER BY id DESC;")
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
    /// Insert one `tasks` row — the SINGLE place a task is created. `status` nil means an
    /// active task (started immediately, via startTask); "queued" means a never-started
    /// plan minted by enqueueTask. `original_estimate_seconds` is stamped equal to the
    /// working estimate at creation (the frozen calibration baseline). Returns the new id.
    private func insertTask(focus: String, estimateSeconds: Int,
                            parentTaskId: Int64? = nil, status: String? = nil) -> Int64? {
        var t: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO tasks (parent_task_id, created_at, focus, estimate_seconds, original_estimate_seconds, status) VALUES (?,?,?,?,?,?);", -1, &t, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(t) }
        if let p = parentTaskId { sqlite3_bind_int64(t, 1, p) } else { sqlite3_bind_null(t, 1) }
        sqlite3_bind_text(t, 2, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(t, 3, focus, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(t, 4, Int32(estimateSeconds))
        sqlite3_bind_int(t, 5, Int32(estimateSeconds))   // original == working at creation
        if let s = status { sqlite3_bind_text(t, 6, s, -1, SQLITE_TRANSIENT) } else { sqlite3_bind_null(t, 6) }
        guard sqlite3_step(t) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    func startTask(reason: String, estimateSeconds: Int, focus: String,
                   parentTaskId: Int64? = nil) -> (taskId: Int64, intervalId: Int64)? {
        guard let taskId = insertTask(focus: focus, estimateSeconds: estimateSeconds, parentTaskId: parentTaskId),
              let intervalId = startInterval(taskId: taskId, reason: reason) else { return nil }
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
        let intervalId = sqlite3_last_insert_rowid(db)
        // A `queued` (never-started) task becomes active the moment it gets an interval.
        exec("UPDATE tasks SET status=NULL WHERE id=\(taskId) AND status='queued';")
        return intervalId
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

    /// Set an interval's recorded start time. Used by "Add time spent" to grow/shrink the
    /// time logged against the current (open) interval durably: moving the start earlier
    /// adds spent time, later subtracts it, and the change survives a restart (which
    /// reconstructs the running interval from its stored `started_at`).
    func setIntervalStartedAt(id: Int64, iso: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE intervals SET started_at=? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, iso, -1, SQLITE_TRANSIENT); sqlite3_bind_int64(s, 2, id); sqlite3_step(s)
    }

    /// Move a task's creation time. Used by "Add time spent" to keep `created_at` no later
    /// than the interval it now starts — and to walk that back up the parent chain, so a
    /// subtask never predates the task it runs under.
    func setTaskCreatedAt(id: Int64, iso: String) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET created_at=? WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, iso, -1, SQLITE_TRANSIENT); sqlite3_bind_int64(s, 2, id); sqlite3_step(s)
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

    /// Reopen a task: clear its terminal status so it's active/in-progress again. The
    /// task's finish time (`endedAt`) is derived from status, so clearing status alone
    /// un-finishes it; rating/note are kept. Used by See History's "Resume task" / "Add
    /// to queue" to pick a completed (or set-aside) task back up. No-op if already active.
    func reopenTask(id: Int64) {
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE tasks SET status=NULL WHERE id=?;", -1, &s, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int64(s, 1, id); sqlite3_step(s)
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
        queryTasks("SELECT \(TaskRow.columns) FROM tasks WHERE id=? LIMIT 1;") {
            sqlite3_bind_int64($0, 1, id)
        }.first
    }

    /// A task's ancestors, nearest first: [parent, grandparent, …, root]. Empty for
    /// a top-level task. This is the parent_task_id walk used to rebuild the subtask
    /// stack on resume/restart. Guarded against cycles.
    func ancestorTasks(of taskId: Int64) -> [TaskRow] {
        var chain: [TaskRow] = []
        var next = task(id: taskId)?.parentTaskId
        var guardCount = 0
        while let pid = next, guardCount < 100 {
            guard let parent = task(id: pid) else { break }
            chain.append(parent)
            next = parent.parentTaskId
            guardCount += 1
        }
        return chain
    }

    /// Direct child tasks (subtasks) of a task, oldest first.
    func childTasks(of taskId: Int64) -> [TaskRow] {
        queryTasks("SELECT \(TaskRow.columns) FROM tasks WHERE parent_task_id=? ORDER BY id ASC;") {
            sqlite3_bind_int64($0, 1, taskId)
        }
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
        queryTasks("SELECT \(TaskRow.columns) FROM tasks WHERE status='completed' AND rating IS NULL ORDER BY id DESC;")
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

    /// Enqueue a focus. `taskId` set = resume that existing task (deferred/pre-empted).
    /// nil = a fresh plan: mint a `queued` task now (durable identity), so every queue
    /// row references a real task from creation. Starting it clears the `queued` status;
    /// removing it from the queue abandons it (kept in history). `front` inserts at head.
    /// Returns the task id the row points at.
    @discardableResult
    func enqueueTask(focus: String, estimateSeconds: Int, taskId: Int64? = nil, front: Bool = false) -> Int64? {
        let tid: Int64
        if let t = taskId {
            tid = t
        } else {
            // No existing task → mint a never-started `queued` one.
            guard let minted = insertTask(focus: focus, estimateSeconds: estimateSeconds, status: "queued") else { return nil }
            tid = minted
        }
        let pos = front ? "(SELECT COALESCE(MIN(position), 0) - 1 FROM queue)"
                        : "(SELECT COALESCE(MAX(position), 0) + 1 FROM queue)"
        let sql = "INSERT INTO queue (created_at, seconds, task_id, position) VALUES (?,?,?, \(pos));"
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_text(s, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(s, 2, Int32(estimateSeconds))
        sqlite3_bind_int64(s, 3, tid)
        sqlite3_step(s)
        return tid
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
        SELECT t.id, t.focus, t.estimate_seconds, t.original_estimate_seconds, t.status, t.rating, t.note,
               COALESCE(SUM(iv.seconds), 0), COUNT(iv.id),
               MIN(iv.started_at),
               CASE WHEN t.status IN ('completed','interrupted','abandoned') THEN MAX(iv.ended_at) END,
               MAX(COALESCE(iv.ended_at, iv.started_at)),
               t.parent_task_id
        FROM tasks t LEFT JOIN intervals iv ON iv.task_id = t.id
        WHERE COALESCE(t.status,'') <> 'queued'   -- never-started plans live in the queue, not history
        GROUP BY t.id ORDER BY t.id DESC LIMIT ?;
        """
        var s: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &s, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(s) }
        sqlite3_bind_int(s, 1, Int32(limit))
        func intOrNil(_ c: Int32) -> Int? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : Int(sqlite3_column_int(s, c)) }
        func int64OrNil(_ c: Int32) -> Int64? { sqlite3_column_type(s, c) == SQLITE_NULL ? nil : sqlite3_column_int64(s, c) }
        func text(_ c: Int32) -> String? { sqlite3_column_text(s, c).map { String(cString: $0) } }
        var rows: [TaskHistoryRow] = []
        while sqlite3_step(s) == SQLITE_ROW {
            rows.append(TaskHistoryRow(
                id: sqlite3_column_int64(s, 0),
                focus: text(1) ?? "",
                estimateSeconds: intOrNil(2),
                originalEstimateSeconds: intOrNil(3),
                status: text(4),
                rating: intOrNil(5),
                note: text(6),
                actualSeconds: Int(sqlite3_column_int(s, 7)),
                intervalCount: Int(sqlite3_column_int(s, 8)),
                startedAt: text(9),
                endedAt: text(10),
                lastActivity: text(11),
                parentTaskId: int64OrNil(12)))
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

extension TaskRow {
    /// The task columns every single-table task read selects, in this order.
    static let columns = "id, parent_task_id, created_at, focus, estimate_seconds, status, rating, note"

    /// Build a TaskRow from a stepped statement whose columns are `TaskRow.columns`.
    init(row s: OpaquePointer?) {
        self.init(id: sqlite3_column_int64(s, 0),
                  parentTaskId: colInt64(s, 1),
                  createdAt: colText(s, 2),
                  focus: colText(s, 3) ?? "",
                  estimateSeconds: colInt(s, 4),
                  status: colText(s, 5),
                  rating: colInt(s, 6),
                  note: colText(s, 7))
    }
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
    let estimateSeconds: Int?          // working estimate (grown by add-time / auto-extend)
    let originalEstimateSeconds: Int?  // first guess (frozen) — the calibration baseline
    let status: String?
    let rating: Int?
    let note: String?
    let actualSeconds: Int    // Σ of the task's interval seconds
    let intervalCount: Int
    let startedAt: String?    // first interval start
    let endedAt: String?      // FINISH time (nil unless completed/interrupted)
    let lastActivity: String? // most recent interval moment (open included) — recency sort
    let parentTaskId: Int64?  // nil = top-level; else the parent task (for the History tree)
}
