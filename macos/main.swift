import Cocoa
import SQLite3

// focus — pops a blocking "Welcome back, what's your focus?" modal whenever you
// return to the Mac (login / fast-user-switch, wake, screen unlock). You set a
// focus and a number of minutes. While a focus is active it's shown two ways:
//   • an always-on-top floating pill in the top-right of the screen, and
//   • a menu-bar item (with controls to change/clear the focus).
// When the timer expires it pops a MANDATORY modal that shows the focus and
// makes you rate the session 1–10. Every session is recorded in a SQLite table.

let defaultMinutes = 25

// A built-in macOS sound played when a timer finishes. Options live in
// /System/Library/Sounds (e.g. Glass, Hero, Ping, Blow, Submarine, Tink).
let timeUpSoundName = "Glass"

func mmss(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

// Render an emoji into an NSImage — used as the app icon so NSAlert modals show
// 🎯 instead of the generic "unbundled binary" application icon.
func emojiImage(_ emoji: String, size: CGFloat) -> NSImage {
    let font = NSFont.systemFont(ofSize: size * 0.82)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let str = emoji as NSString
    let textSize = str.size(withAttributes: attrs)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    str.draw(at: NSPoint(x: (size - textSize.width) / 2, y: (size - textSize.height) / 2),
             withAttributes: attrs)
    image.unlockFocus()
    return image
}

// Timestamps are stored as ISO8601 UTC; the history window renders them in the
// system's local time zone.
private let isoParser = ISO8601DateFormatter()
private let localTimeFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = .current
    return f
}()
// Time-of-day only, for the queue's estimated start/finish columns.
private let localClockFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "h:mm a"
    f.timeZone = .current
    return f
}()

// SQLite wants to know whether the bound string outlives the call; TRANSIENT
// tells it to copy, so passing a temporary Swift string is safe.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Storage

final class DB {
    private var db: OpaquePointer?

    init() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("focus")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("focus.db").path
        if sqlite3_open(path, &db) != SQLITE_OK {
            FileHandle.standardError.write("focus: cannot open db at \(path)\n".data(using: .utf8)!)
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

// An NSTableView that supports ⌘C — it forwards the selection to `onCopy`
// (NSTableView has no copy: of its own).
final class CopyableTableView: NSTableView {
    var onCopy: ((IndexSet) -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?(selectedRowIndexes) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

// An NSTableView that reports Delete / ⌦ key presses (to remove the selected item)
// and supports ⌘C (to copy the selected rows).
final class QueueTableView: NSTableView {
    var onDelete: ((Int) -> Void)?
    var onCopy: ((IndexSet) -> Void)?

    override func keyDown(with event: NSEvent) {
        // 51 = Delete (backspace), 117 = forward delete (fn+Delete).
        if (event.keyCode == 51 || event.keyCode == 117), selectedRow >= 0 {
            onDelete?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }

    @objc func copy(_ sender: Any?) { onCopy?(selectedRowIndexes) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

// A read-only "See Queue"-style table used to pick a queued focus to pre-empt
// with. Single-clicking a row fires `onPick` with that item. Self-contained data
// source/delegate so it doesn't collide with AppController's own two tables.
struct QueuePickRow { let item: QueueItem; let num: Int; let duration: String; let start: String; let finish: String }

final class QueuePickSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [QueuePickRow]
    private let onPick: (QueueItem) -> Void
    init(rows: [QueuePickRow], onPick: @escaping (QueueItem) -> Void) { self.rows = rows; self.onPick = onPick }

    func makeTable() -> NSTableView {
        let t = NSTableView()
        t.usesAlternatingRowBackgroundColors = true
        t.rowHeight = 22
        t.style = .inset
        t.headerView = NSTableHeaderView()
        func col(_ id: String, _ title: String, _ w: CGFloat, _ a: NSTextAlignment = .left) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = w; c.headerCell.alignment = a
            t.addTableColumn(c)
        }
        col("num", "#", 30, .right)
        col("dur", "Duration", 70, .right)
        col("start", "Est. start", 84, .right)
        col("finish", "Est. finish", 84, .right)
        col("focus", "Focus (next up first)", 240)
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.action = #selector(clicked(_:))   // single click → pick
        return t
    }

    @objc private func clicked(_ sender: NSTableView) {
        let r = sender.clickedRow
        guard r >= 0, r < rows.count else { return }
        onPick(rows[r].item)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        var align: NSTextAlignment = .left
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "num":    text = "\(r.num)"; align = .right
        case "dur":    text = r.duration; align = .right
        case "start":  text = r.start; align = .right
        case "finish": text = r.finish; align = .right
        default:       text = r.item.focus
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.alignment = align
        tf.font = NSFont.systemFont(ofSize: 12)
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource,
                           NSTableViewDelegate, NSMenuItemValidation, NSWindowDelegate {
    private let db = DB()

    // ---- session state ----
    private var currentFocus: String?
    private var deadline: Date?
    private var sessionId: Int64?
    private var sessionStart: Date?   // when the current session began (for elapsed time)
    private var sessionSeconds: Int?  // planned duration of the current session in seconds (incl. added time)
    private var sessionOriginalId: Int64?  // chain root if this session continues an interrupted one

    // Debounce guards for the return-prompt (wake + unlock + session often fire
    // together). `showing` also stops any modal from stacking on another.
    private var showing = false
    private var lastFired = Date.distantPast
    private let cooldown: TimeInterval = 10
    private var panelResult: Int?   // set by a floating (non-app-modal) panel's button

    // ---- ui ----
    private var statusItem: NSStatusItem!
    private var hudWindow: NSWindow!
    private var hudLabel: NSTextField!
    private var hudAnchorTopRight: NSPoint? // set once the user drags the pill; layout keeps this corner fixed
    private var hudProgrammaticMove = false // guards windowDidMove during our own setFrame
    private var uiTimer: Timer?
    private var historyWindow: NSWindow?
    private var historyTable: NSTableView?
    private var historyRows: [SessionRow] = []
    private var queueWindow: NSWindow?
    private var queueTable: NSTableView?
    private var queueRows: [QueueItem] = []
    private var queueEstimates: [(start: Date, finish: Date)] = []
    private lazy var alertIcon = emojiImage("🎯", size: 256)

    // NSAlert's default icon is the (missing) app icon; force 🎯 on every modal.
    private func makeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.icon = alertIcon
        return alert
    }

    @objc private func floatingPanelButton(_ sender: NSButton) { panelResult = sender.tag }

    /// Show an NSAlert's window *without* an application-modal session, so the 🎯
    /// menu and other app windows stay usable while it's up. We reuse the alert's
    /// layout but drive it with our own event pump: it returns the clicked button's
    /// index (0 = first button). Because events aren't restricted to this window,
    /// status-item clicks / other windows work; the `showing` guard still blocks a
    /// second prompt from stacking.
    private func runFloatingAlert(_ alert: NSAlert, firstResponder: NSView? = nil) -> Int {
        alert.layout()
        let panel = alert.window
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        // Re-point the buttons at us (their default action only works under runModal).
        for (i, b) in alert.buttons.enumerated() {
            b.target = self
            b.action = #selector(floatingPanelButton(_:))
            b.tag = i
        }
        panelResult = nil
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let fr = firstResponder { panel.makeFirstResponder(fr) }
        // Pump events until a button sets panelResult. nextEvent in .default mode
        // still services .common-mode timers (the countdown / "Open for" label), and
        // dispatching a status-item click runs the menu inline.
        while panelResult == nil {
            if let e = NSApp.nextEvent(matching: .any, until: .distantFuture, inMode: .default, dequeue: true) {
                NSApp.sendEvent(e)
            }
        }
        panel.orderOut(nil)
        return panelResult ?? 0
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // Give NSAlert a real icon (🎯) instead of the generic app icon.
        NSApp.applicationIconImage = emojiImage("🎯", size: 256)
        buildMainMenu()
        buildStatusItem()
        buildHUD()

        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.sessionDidBecomeActiveNotification,
                       object: nil, queue: .main) { [self] _ in onReturn("session") }
        ws.addObserver(forName: NSWorkspace.didWakeNotification,
                       object: nil, queue: .main) { [self] _ in onReturn("wake") }
        // Screen unlock is a distributed notification, not an NSWorkspace event.
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main) { [self] _ in onReturn("unlock") }

        // Drive the countdown / HUD once a second. Add it to the common run-loop
        // modes so it keeps firing while the status menu is open or a modal is up
        // (a default-mode timer would pause during menu/modal tracking).
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        RunLoop.main.add(timer, forMode: .common)
        uiTimer = timer
        tick()

        // On launch, offer to resume a session that was live when the process
        // last died (uninstall/crash/reboot); otherwise prompt as a return.
        restoreOrPrompt()
    }

    // ---- return handling ----
    func onReturn(_ reason: String) {
        // If a menu is open, don't raise the (non-app-modal) prompt nested in its
        // tracking loop — the menu would swallow keyboard input. Dismiss it and retry
        // once we're back in the normal run-loop mode.
        if RunLoop.current.currentMode == .eventTracking {
            statusItem.menu?.cancelTracking()
            DispatchQueue.main.async { [weak self] in self?.onReturn(reason) }
            return
        }
        guard !showing else { return }
        // A session already running is left alone: the countdown is wall-clock
        // based, so it just resumes after lock/sleep. If it expired while away,
        // the timer's tick() runs timeUp (rate → chain) — either way the return
        // must NOT interrupt or restart it. Only prompt when idle.
        guard currentFocus == nil else { return }
        guard Date().timeIntervalSince(lastFired) >= cooldown else { return }
        promptForFocus(reason: reason)
        lastFired = Date()          // stamp AFTER dismissal
    }

    // ---- resume-after-restart ----
    private func restoreOrPrompt() {
        let open = db.openSessions()   // newest first

        // Any older open rows are stale orphans from past deaths — sweep them.
        for stale in open.dropFirst() {
            db.endSession(id: stale.id, status: "interrupted", rating: nil)
        }

        guard let candidate = open.first,
              let start = isoParser.date(from: candidate.startedAt) else {
            // Nothing (or unparseable) to resume — clean up and prompt normally.
            if let c = open.first { db.endSession(id: c.id, status: "interrupted", rating: nil) }
            onReturn("launch")
            return
        }

        let deadline = start.addingTimeInterval(Double(candidate.seconds))
        if deadline > Date() {
            offerResume(candidate, deadline: deadline)     // still time left
        } else {
            // Expired while away → treat as finished: adopt it and let tick()'s
            // timeUp run the mandatory rating (status 'completed').
            adopt(candidate, deadline: deadline)
            tick()
        }
    }

    private func offerResume(_ s: ActiveSession, deadline: Date) {
        NSApp.activate(ignoringOtherApps: true)
        showing = true
        let remaining = Int(deadline.timeIntervalSinceNow.rounded())
        let alert = makeAlert()
        alert.messageText = "Resume focus?"
        alert.informativeText = "\(s.focus)\n\n\(mmss(remaining)) remaining (of \(mmss(s.seconds)))"
        alert.addButton(withTitle: "Resume")            // .alertFirstButtonReturn
        alert.addButton(withTitle: "Switch focus…")     // .alertSecondButtonReturn
        alert.addButton(withTitle: "Start fresh…")      // .alertThirdButtonReturn
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        showing = false

        switch response {
        case .alertFirstButtonReturn:            // Resume — continue where it left off
            adopt(s, deadline: deadline)
            tick()

        case .alertSecondButtonReturn:           // Pre-empt — adopt it, then run the
            adopt(s, deadline: deadline)         // standard pre-empt flow (re-queues the
            tick()                               // remaining time to the front, starts new).
            changeFocus()

        default:                                 // Start fresh — abandon it, optionally
            showing = true                       // clear the queue, then start anew.
            let hasQueue = db.queueCount() > 0
            let clear = hasQueue ? confirmClearQueue() : false
            showing = false
            if hasQueue && !clear {
                offerResume(s, deadline: deadline)   // declined clearing → back to the choice
                return
            }
            if clear { db.clearQueue() }
            db.endSession(id: s.id, status: "interrupted", rating: nil)
            onReturn("launch")
        }
    }

    /// Reload an existing (still-open) session row into memory — same row keeps
    /// getting written, so history stays one row / one rating.
    private func adopt(_ s: ActiveSession, deadline: Date) {
        currentFocus = s.focus
        self.deadline = deadline
        sessionId = s.id
        sessionStart = isoParser.date(from: s.startedAt) ?? Date()
        sessionSeconds = s.seconds
        sessionOriginalId = s.originalSessionId
    }

    // "Set focus" is an explicit ad-hoc entry — it bypasses the queue.
    // Idle → "Set focus" (ad-hoc, bypasses queue). Active → "Pre-empt": re-queue
    // the current focus (with its remaining time) to the FRONT and run a new one
    // now — the same idea as pre-empting a focus that's about to begin, but for
    // the one already running.
    @objc func changeFocus() {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        NSApp.activate(ignoringOtherApps: true)

        let preempting = sessionId != nil
        let title = preempting ? "Switch to a new focus" : "Set focus"
        let info = preempting
            ? "This runs now; the current focus goes to the front of the queue."
            : "What's your one focus right now, and for how long?"

        // Pre-empt is voluntary → cancellable (cancel leaves the current session
        // untouched). Idle "Set focus" stays mandatory.
        guard let (focus, seconds, openStart) = askFocusAndMinutes(
            title: title, info: info, confirm: "Start", cancellable: preempting) else { return }

        var preemptedId: Int64? = nil
        if preempting, let id = sessionId, let curFocus = currentFocus, let dl = deadline {
            preemptedId = id
            let remaining = max(1, Int(dl.timeIntervalSinceNow.rounded()))
            let elapsed = max(0, Int(Date().timeIntervalSince(sessionStart ?? Date()).rounded()))
            // Complete the existing record as interrupted, recording elapsed seconds.
            db.markInterrupted(id: id, elapsedSeconds: elapsed)
            // Queue a fresh copy for the remaining time to resume next, carrying
            // the chain root (this session's original, or itself if it's the root).
            db.enqueueFront(focus: continuedName(curFocus), seconds: remaining,
                            originalSessionId: sessionOriginalId ?? id)
        }
        beginSession(reason: preempting ? "preempt" : "manual", seconds: seconds, focus: focus,
                     openSecondsStart: openStart)
        if preempting { db.recordPreempt(preemptedSessionId: preemptedId, newSessionId: sessionId) }
    }

    // Insert a new focus at the FRONT of the queue — it jumps ahead of whatever
    // was queued next, without disturbing the running session. Records a pre-empt
    // (both ids NULL: nothing interrupted, nothing started yet — just a queue jump).
    @objc func preemptNextFocus() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        guard let (focus, seconds, _) = askFocusAndMinutes(
            title: "Add focus to front",
            info: "This goes to the front of the queue — it runs before whatever's queued next.",
            confirm: "Add to front", cancellable: true) else { return }
        db.enqueueFront(focus: focus, seconds: seconds, originalSessionId: nil)
        db.recordPreempt(preemptedSessionId: nil, newSessionId: nil)
    }

    // Defer the current task "to be continued": mark it deferred (recording the
    // elapsed time), append a fresh (continued) copy with the task's FULL original
    // duration to the END of the queue, then advance to the next focus. Unlike
    // pre-empt, it doesn't start a new focus now and re-queues the full time (at the
    // back) rather than the remaining time (at the front).
    @objc func deferTask() {
        guard !showing, let id = sessionId, let focus = currentFocus else { return }
        showing = true
        let elapsed = max(0, Int(Date().timeIntervalSince(sessionStart ?? Date()).rounded()))
        let full = db.plannedSecondsAtStart(id: id)
        let orig = sessionOriginalId ?? id
        currentFocus = nil; deadline = nil; sessionId = nil
        sessionStart = nil; sessionSeconds = nil; sessionOriginalId = nil
        hudWindow.orderOut(nil)
        db.markDeferred(id: id, elapsedSeconds: elapsed)
        db.enqueue(focus: continuedName(focus), seconds: full, originalSessionId: orig)
        showing = false
        promptForFocus(reason: "after-session")
    }

    // Toggle the floating corner pill on/off (persisted). The menu-bar icon and
    // all timing/logging are unaffected — only the pill is suppressed.
    @objc func toggleShowPill() {
        showPillEnabled.toggle()
        tick()   // apply immediately: re-show or hide the pill
    }

    // Prompt for minutes and add them to the running session — same as choosing
    // "Add time" at time's up, but available any time from the menu.
    @objc func addTimeToCurrent() {
        guard !showing, sessionId != nil else { return }
        showing = true
        defer { showing = false }
        if let extra = askMinutes() { extendSession(by: extra) }
    }

    /// Log an "Add time" event, bump the planned total, and shift the deadline.
    /// Adjusts from whichever is later — now or the current deadline — so it applies
    /// the full `extra` when the timer's already up, or on top of remaining time.
    /// `extra` may be negative to subtract time (the deadline moves earlier).
    private func extendSession(by extra: Int) {
        guard let id = sessionId else { return }
        db.addTime(sessionId: id, seconds: extra)
        sessionSeconds = (sessionSeconds ?? 0) + extra
        let base = max(Date(), deadline ?? Date())
        deadline = base.addingTimeInterval(Double(extra))
        tick()
    }

    // Finish the current task: mark completed, rate it, then advance to the next.
    @objc func completeTask() {
        guard !showing, sessionId != nil else { return }
        showing = true
        rateAndComplete()   // rate + end as completed
        showing = false
        promptForFocus(reason: "after-session")
    }

    // Abort the current task: rate it, mark interrupted (recording elapsed),
    // then advance to the next (queued or improvised).
    @objc func abortTask() {
        guard !showing, let id = sessionId, let focus = currentFocus else { return }
        showing = true
        let elapsed = max(0, Int(Date().timeIntervalSince(sessionStart ?? Date()).rounded()))
        currentFocus = nil; deadline = nil; sessionId = nil
        sessionStart = nil; sessionSeconds = nil; sessionOriginalId = nil
        hudWindow.orderOut(nil)
        let (rating, note, openSeconds, applyTime) = promptRating(focus: "\(focus) · \(mmss(elapsed))", title: "Rate this session")
        db.markInterrupted(id: id, elapsedSeconds: elapsed, rating: rating, note: note,
                           openSecondsEnd: applyTime ? nil : openSeconds)
        if applyTime { db.addToDuration(id: id, seconds: openSeconds) }
        showing = false
        promptForFocus(reason: "after-session")
    }

    // Menu actions that are guarded by `showing` (they open their own prompt), so
    // they do nothing while another prompt is already up — disabled in that case.
    private static let showingBlockedActions: Set<Selector> = [
        #selector(addNextFocus), #selector(completeTask), #selector(abortTask),
        #selector(addTimeToCurrent), #selector(deferTask), #selector(changeFocus),
        #selector(preemptNextFocus), #selector(clearQueue), #selector(rateUnrated),
        #selector(showSettings), #selector(deleteHistoryItems),
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // While a prompt is open, actions that would spawn another prompt are guarded
        // by `showing` and would silently no-op — disable them so the menu shows that.
        // (See history / See queue / Show current task / Quit still work.)
        if showing, let action = menuItem.action, Self.showingBlockedActions.contains(action) {
            return false
        }
        // Complete / Abort / Defer / Pre-empt act on a running session.
        if menuItem.action == #selector(completeTask) || menuItem.action == #selector(abortTask)
            || menuItem.action == #selector(addTimeToCurrent) || menuItem.action == #selector(deferTask) {
            return currentFocus != nil
        }
        if menuItem.action == #selector(deleteHistoryItems) {
            return !historyTargetRows().isEmpty
        }
        if menuItem.action == #selector(toggleShowPill) {
            menuItem.state = showPillEnabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(changeFocus) {
            menuItem.title = currentFocus != nil ? "Switch focus now" : "Set focus"
        }
        if menuItem.action == #selector(showHistory) {
            menuItem.title = "See history (\(db.sessionCount()))"
        }
        if menuItem.action == #selector(showQueue) {
            menuItem.title = "See queue (\(db.queueCount()))"
        }
        if menuItem.action == #selector(clearQueue) {
            return db.queueCount() > 0
        }
        if menuItem.action == #selector(rateUnrated) {
            let n = db.unratedCount()
            menuItem.title = "Rate unrated sessions (\(n))"
            return n > 0
        }
        // Queue right-click move items: enable based on the clicked row's position.
        if menuItem.action == #selector(moveQueueItemUp) || menuItem.action == #selector(moveQueueItemToTop) {
            let r = queueTable?.clickedRow ?? -1
            return r > 0
        }
        if menuItem.action == #selector(moveQueueItemDown) || menuItem.action == #selector(moveQueueItemToBottom) {
            let r = queueTable?.clickedRow ?? -1
            return r >= 0 && r < queueRows.count - 1
        }
        if menuItem.action == #selector(deleteClickedQueueItem) {
            let r = queueTable?.clickedRow ?? -1
            return r >= 0 && r < queueRows.count
        }
        return true
    }

    /// Queue a focus to run after the current/queued ones. Doesn't touch the
    /// active session. Cancellable, since it's a voluntary action.
    @objc func addNextFocus() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        if let (focus, seconds, _) = askFocusAndMinutes(
            title: "Add next focus",
            info: "Queue a focus to run after the current one.",
            confirm: "Add to queue", cancellable: true) {
            db.enqueue(focus: focus, seconds: seconds)
        }
    }

    private func promptForFocus(reason: String) {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        // promptForFocus only runs with no active session (callers guard on or
        // clear it first), so there's nothing to rate/close here.

        NSApp.activate(ignoringOtherApps: true)

        // Auto-starts (return / after-session) use a queued focus if present.
        // Only the after-session chain is eligible for hands-free auto-proceed.
        if let next = db.frontOfQueue() {
            confirmQueued(next, autoEligible: reason == "after-session")
            return
        }

        guard let (answer, seconds, openStart) = askFocusAndMinutes(
            title: "Welcome back",
            info: "What's your one focus right now, and for how long?",
            confirm: "Start", cancellable: false) else { return }
        beginSession(reason: reason, seconds: seconds, focus: answer, openSecondsStart: openStart)
    }

    /// Non-editable confirmation for the next queued focus. Pops it off and starts.
    /// When `autoEligible` and the auto-proceed preference is on, a 10s countdown
    /// auto-starts it (as if "Start" were clicked).
    private func confirmQueued(_ item: QueueItem, autoEligible: Bool) {
        let confirmOpenedAt = Date()   // how long this confirm stays up → the queued session's open_seconds_start
        let alert = makeAlert()
        alert.messageText = "Next focus"
        alert.informativeText = "\(item.focus)\n\n\(mmss(item.seconds))"
        alert.addButton(withTitle: "Start")             // .alertFirstButtonReturn
        alert.addButton(withTitle: "Start a different focus") // index 1
        // Always shown, but disabled when there's no other queued item to pick.
        let pickButton = alert.addButton(withTitle: "Pick another queued focus…")  // index 2
        pickButton.isEnabled = db.queueCount() > 1

        var autoTimer: Timer?
        var elapsedTimer: Timer?
        if autoEligible && autoProceedEnabled {
            let label = NSTextField(wrappingLabelWithString: "")
            label.frame = NSRect(x: 0, y: 0, width: 340, height: 34)
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 12)
            alert.accessoryView = label
            var remaining = 10
            label.stringValue = "Will automatically proceed with this focus in \(remaining) seconds."
            // .common mode so it fires while the panel is up; setting panelResult to
            // the first button's index ends the pump exactly as a "Start" click would.
            let timer = Timer(timeInterval: 1, repeats: true) { t in
                remaining -= 1
                if remaining <= 0 {
                    t.invalidate()
                    self.panelResult = 0
                } else {
                    label.stringValue = "Will automatically proceed with this focus in \(remaining) second\(remaining == 1 ? "" : "s")."
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoTimer = timer
        } else {
            // No auto-proceed → show how long you've been sitting on this prompt.
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 0, y: 0, width: 320, height: 18)
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 11)
            label.textColor = .secondaryLabelColor
            alert.accessoryView = label
            elapsedTimer = startElapsedTimer(label).timer
        }

        // Non-app-modal so the 🎯 menu stays usable while this prompt is up.
        let response = runFloatingAlert(alert)   // 0 = Start, 1 = Pre-empt with new, 2 = from queue
        autoTimer?.invalidate()
        elapsedTimer?.invalidate()

        if response == 1 {
            // Pre-empt with new: leave the queued item where it is (still the front,
            // since we never removed it) and run an ad-hoc focus right now instead.
            if let (focus, seconds, openStart) = askFocusAndMinutes(
                title: "Start a different focus",
                info: "This runs now; the queued focus stays next in line.",
                confirm: "Start", cancellable: true) {
                beginSession(reason: "preempt", seconds: seconds, focus: focus, openSecondsStart: openStart)
                // Nothing was underway → preempted_session_id is NULL.
                db.recordPreempt(preemptedSessionId: nil, newSessionId: sessionId)
                return
            }
            // Cancelled the pre-empt → fall through and start the queued one.
        } else if response == 2 {
            // Pre-empt from queue: pick any focus and start it now instead of
            // the front one (which stays queued). Same as a normal front-fetch, just
            // for the chosen item.
            if let chosen = pickFromQueue() {
                db.removeFromQueue(id: chosen.id)
                let openStart = Int(Date().timeIntervalSince(confirmOpenedAt).rounded())
                beginSession(reason: "queue", seconds: chosen.seconds, focus: chosen.focus,
                             originalSessionId: chosen.originalSessionId, openSecondsStart: openStart)
                db.recordPreempt(preemptedSessionId: nil, newSessionId: sessionId)
                return
            }
            // Cancelled the picker → fall through and start the front one.
        }

        db.removeFromQueue(id: item.id)
        let queuedOpenStart = Int(Date().timeIntervalSince(confirmOpenedAt).rounded())
        beginSession(reason: "queue", seconds: item.seconds, focus: item.focus,
                     originalSessionId: item.originalSessionId, openSecondsStart: queuedOpenStart)
    }

    /// Show a "See Queue"-style picker (in a floating modal) of all queued focuses,
    /// with the same Est. start/finish schedule. Returns the one the user clicks,
    /// or nil if they cancel.
    private func pickFromQueue() -> QueueItem? {
        let items = db.queueItems()
        guard !items.isEmpty else { return nil }

        // Same estimate chain as the queue window: from the current deadline if a
        // session is running (there isn't one here), else now.
        var cursor = Date()
        if let dl = deadline, dl > cursor { cursor = dl }
        var rows: [QueuePickRow] = []
        for item in items {
            let start = cursor
            let finish = cursor.addingTimeInterval(Double(item.seconds))
            cursor = finish
            rows.append(QueuePickRow(item: item, num: rows.count + 1,
                                     duration: mmss(item.seconds),
                                     start: localClockFormatter.string(from: start),
                                     finish: localClockFormatter.string(from: finish)))
        }

        var chosen: QueueItem?
        let source = QueuePickSource(rows: rows) { item in
            chosen = item
            NSApp.stopModal()   // ends the alert's runModal below
        }
        let table = source.makeTable()
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 540, height: 240))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        table.frame = scroll.bounds

        let alert = makeAlert()
        alert.messageText = "Pick another queued focus"
        alert.informativeText = "Click a queued focus to start it now (it's removed from the queue; the others stay)."
        alert.addButton(withTitle: "Cancel")
        alert.accessoryView = scroll
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.runModal()   // a row click calls NSApp.stopModal(); Cancel ends it too
        return chosen
    }

    /// Editable "focus + minutes" modal. The field takes whole minutes but the
    /// returned duration is in seconds (×60). Loops until valid; returns nil only
    /// if `cancellable` and the user cancels.
    private func askFocusAndMinutes(title: String, info: String, confirm: String,
                                    cancellable: Bool) -> (focus: String, seconds: Int, openSeconds: Int)? {
        NSApp.activate(ignoringOtherApps: true)

        let focusField = NSTextField(frame: NSRect(x: 0, y: 34, width: 320, height: 24))
        focusField.placeholderString = "e.g. Ship the focus pill"

        let minutesLabel = NSTextField(labelWithString: "Minutes:")
        minutesLabel.frame = NSRect(x: 0, y: 2, width: 60, height: 24)
        let minutesField = NSTextField(frame: NSRect(x: 62, y: 2, width: 70, height: 24))
        minutesField.stringValue = String(defaultMinutes)

        let elapsed = NSTextField(labelWithString: "")
        elapsed.frame = NSRect(x: 0, y: 62, width: 320, height: 18)
        elapsed.font = NSFont.systemFont(ofSize: 11)
        elapsed.textColor = .secondaryLabelColor

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
        accessory.addSubview(focusField)
        accessory.addSubview(minutesLabel)
        accessory.addSubview(minutesField)
        accessory.addSubview(elapsed)

        let (elapsedTimer, openSeconds, _) = startElapsedTimer(elapsed)
        defer { elapsedTimer.invalidate() }

        while true {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: confirm)             // index 0
            if cancellable { alert.addButton(withTitle: "Cancel") }   // index 1
            alert.accessoryView = accessory
            // Non-app-modal so the 🎯 menu stays usable while the prompt is up.
            let clicked = runFloatingAlert(alert, firstResponder: focusField)

            if cancellable && clicked == 1 { return nil }

            let answer = focusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let minutes = Int(minutesField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if !answer.isEmpty && minutes > 0 { return (answer, minutes * 60, openSeconds()) }
            // otherwise invalid: loop and ask again
        }
    }

    /// Next "(continued)" name: "X" → "X (continued)" → "X (continued 2)" → "X (continued 3)"…
    private func continuedName(_ focus: String) -> String {
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

    private func beginSession(reason: String, seconds: Int, focus: String, originalSessionId: Int64? = nil,
                              openSecondsStart: Int? = nil) {
        currentFocus = focus
        sessionStart = Date()
        sessionSeconds = seconds
        sessionOriginalId = originalSessionId
        deadline = Date().addingTimeInterval(Double(seconds))
        sessionId = db.startSession(reason: reason, seconds: seconds, focus: focus,
                                    originalSessionId: originalSessionId)
        if let id = sessionId, let s = openSecondsStart { db.addOpenSecondsStart(id: id, seconds: s) }
        if pushoverEnabled { sendPushover(title: "Focus started", message: "\(focus) — \(mmss(seconds))") }
        tick()
    }

    // ---- history ----
    @objc func showHistory() {
        historyRows = db.recent()

        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Focus history"
            window.isReleasedWhenClosed = false   // we keep & reuse it
            window.center()

            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true   // let wide columns (Focus/Note) scroll
            scroll.borderType = .noBorder

            let table = CopyableTableView()
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            // Keep each column's natural width; total can exceed the window and
            // scroll horizontally, so Focus/Note aren't squeezed.
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.rowHeight = 22
            table.allowsColumnResizing = true
            table.allowsMultipleSelection = true   // Shift/⌘-click to select a range
            table.style = .inset
            table.onCopy = { [weak self] indexes in self?.copyHistoryRows(indexes) }
            // Right-click a row (or a selection) to delete it.
            let histMenu = NSMenu()
            histMenu.addItem(withTitle: "Delete", action: #selector(deleteHistoryItems), keyEquivalent: "")
            for mi in histMenu.items { mi.target = self }
            table.menu = histMenu

            func addColumn(_ id: String, _ title: String, width: CGFloat, min: CGFloat,
                           align: NSTextAlignment = .left) {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                col.title = title
                col.width = width
                col.minWidth = min
                col.headerCell.alignment = align
                table.addTableColumn(col)
            }
            addColumn("when", "Started", width: 140, min: 120)
            addColumn("min", "Duration", width: 70, min: 56, align: .right)
            addColumn("origmin", "Original", width: 70, min: 56, align: .right)
            addColumn("rating", "Rating", width: 60, min: 50, align: .right)
            addColumn("status", "Status", width: 95, min: 70)
            addColumn("focus", "Focus", width: 360, min: 150)
            addColumn("note", "Note", width: 320, min: 100)
            addColumn("openstart", "Start popup open", width: 110, min: 90, align: .right)
            addColumn("openend", "End popup open", width: 110, min: 90, align: .right)

            scroll.documentView = table
            window.contentView = scroll

            historyWindow = window
            historyTable = table
        }

        historyTable?.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    // Copy the selected history rows to the clipboard as TSV (with a header).
    private func copyHistoryRows(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        var lines = ["Started\tDuration (s)\tOriginal (s)\tRating\tStatus\tFocus\tNote\tStart popup open (s)\tEnd popup open (s)"]
        for i in indexes where i < historyRows.count {
            let r = historyRows[i]
            let fields = [
                whenLabel(r.startedAt),
                "\(r.seconds)",
                r.originalSeconds.map { "\($0)" } ?? "",
                r.rating.map { "\($0)" } ?? "",
                r.status ?? (r.endedAt == nil ? "active" : ""),
                r.focus,
                r.note ?? "",
                r.openSecondsStart.map { "\($0)" } ?? "",
                r.openSecondsEnd.map { "\($0)" } ?? "",
            ].map(tsvClean)
            lines.append(fields.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // Rows a history right-click acts on: the current selection if the clicked row
    // is part of it, otherwise just the clicked row.
    private func historyTargetRows() -> [Int] {
        guard let table = historyTable else { return [] }
        let clicked = table.clickedRow
        let selected = table.selectedRowIndexes
        let rows: IndexSet
        if clicked >= 0 && selected.contains(clicked) { rows = selected }
        else if clicked >= 0 { rows = IndexSet(integer: clicked) }
        else { rows = selected }
        return rows.filter { $0 < historyRows.count }
    }

    // Delete the right-clicked (or selected) history sessions, after confirming.
    @objc func deleteHistoryItems() {
        guard !showing else { return }
        let rows = historyTargetRows()
        guard !rows.isEmpty else { return }
        let ids = rows.map { historyRows[$0].id }

        showing = true
        defer { showing = false }
        let n = ids.count
        let alert = makeAlert()
        alert.messageText = "Delete \(n) session\(n == 1 ? "" : "s")?"
        alert.informativeText = "This permanently removes \(n == 1 ? "this session" : "these sessions") from history. This can't be undone."
        alert.addButton(withTitle: "Delete")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        db.deleteSessions(ids: ids)
        historyRows = db.recent()
        historyTable?.reloadData()
    }

    // TSV has no quoting, so flatten any tabs/newlines in a field to spaces.
    private func tsvClean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    // Reload queue rows and recompute the estimated schedule (front to back).
    private func reloadQueueData() {
        queueRows = db.queueItems()
        // Start from when the current session finishes (its deadline, if one is
        // running and still ahead), else now, then chain each queued item's duration.
        var cursor = Date()
        if let dl = deadline, dl > cursor { cursor = dl }
        queueEstimates = queueRows.map { item in
            let start = cursor
            let finish = cursor.addingTimeInterval(Double(item.seconds))
            cursor = finish
            return (start, finish)
        }
    }

    @objc func showQueue() {
        reloadQueueData()

        if queueWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Focus queue"
            window.isReleasedWhenClosed = false
            window.center()

            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let table = QueueTableView()
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.rowHeight = 22
            table.style = .inset
            table.allowsMultipleSelection = true   // Shift/⌘-click to select a range, then ⌘C
            table.onDelete = { [weak self] row in self?.deleteQueueRow(at: row) }
            table.onCopy = { [weak self] indexes in self?.copyQueueRows(indexes) }
            // Right-click a row to re-order it within the queue, or remove it.
            let rowMenu = NSMenu()
            rowMenu.addItem(withTitle: "Move up", action: #selector(moveQueueItemUp), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Move down", action: #selector(moveQueueItemDown), keyEquivalent: "")
            rowMenu.addItem(.separator())
            rowMenu.addItem(withTitle: "Move to top", action: #selector(moveQueueItemToTop), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Move to bottom", action: #selector(moveQueueItemToBottom), keyEquivalent: "")
            rowMenu.addItem(.separator())
            rowMenu.addItem(withTitle: "Delete from queue", action: #selector(deleteClickedQueueItem), keyEquivalent: "")
            for mi in rowMenu.items { mi.target = self }
            table.menu = rowMenu

            func addColumn(_ id: String, _ title: String, width: CGFloat, min: CGFloat,
                           align: NSTextAlignment = .left) {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
                col.title = title
                col.width = width
                col.minWidth = min
                col.headerCell.alignment = align
                table.addTableColumn(col)
            }
            addColumn("pos", "#", width: 36, min: 30, align: .right)
            addColumn("min", "Duration", width: 70, min: 56, align: .right)
            addColumn("start", "Est. start", width: 90, min: 70, align: .right)
            addColumn("finish", "Est. finish", width: 90, min: 70, align: .right)
            addColumn("focus", "Focus (next up first)", width: 300, min: 150)

            scroll.documentView = table
            window.contentView = scroll

            queueWindow = window
            queueTable = table
        }

        queueTable?.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        queueWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func clearQueue() {
        guard !showing else { return }
        guard db.queueCount() > 0 else { return }
        showing = true
        defer { showing = false }
        NSApp.activate(ignoringOtherApps: true)
        if confirmClearQueue() { db.clearQueue() }
    }

    /// Show the "Clear queue?" confirmation; returns true if the user confirms
    /// (false if the queue is empty). The caller manages `showing` and clearing.
    private func confirmClearQueue() -> Bool {
        let count = db.queueCount()
        guard count > 0 else { return false }
        let alert = makeAlert()
        alert.messageText = "Clear queue?"
        alert.informativeText = "Remove all \(count) queued focus\(count == 1 ? "" : "es")? This can't be undone."
        alert.addButton(withTitle: "Clear queue")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return alert.runModal() == .alertFirstButtonReturn
    }

    // Loop through the deferred (unrated, completed) sessions oldest-first and
    // ask for a rating on each.
    @objc func rateUnrated() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        for s in db.unratedCompleted() {
            let label = "\(whenLabel(s.startedAt)) · \(s.focus) · \(mmss(s.seconds))"
            let (rating, note, openSeconds, applyTime) = promptRating(focus: label, title: "Rate session")
            db.setRating(id: s.id, rating: rating, note: note, openSecondsEnd: applyTime ? nil : openSeconds)
            if applyTime { db.addToDuration(id: s.id, seconds: openSeconds) }
        }
    }

    // started_at is ISO8601 UTC ("2026-08-07T00:12:03Z"); render it in local time.
    private func whenLabel(_ iso: String) -> String {
        if let date = isoParser.date(from: iso) {
            return localTimeFormatter.string(from: date)
        }
        // Fallback: show the raw value if it doesn't parse.
        return String(iso.prefix(16)).replacingOccurrences(of: "T", with: " ")
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === queueTable ? queueRows.count : historyRows.count
    }

    // ---- queue reordering (right-click menu on the queue table) ----
    @objc func moveQueueItemUp()      { moveClickedQueueRow { $0 - 1 } }
    @objc func moveQueueItemDown()    { moveClickedQueueRow { $0 + 1 } }
    @objc func moveQueueItemToTop()   { moveClickedQueueRow { _ in 0 } }
    @objc func moveQueueItemToBottom(){ moveClickedQueueRow { _ in Int.max } }

    /// Move the right-clicked queue row to a new index (computed from its current
    /// one), then persist the new order and refresh.
    private func moveClickedQueueRow(_ destination: (Int) -> Int) {
        guard let table = queueTable else { return }
        let src = table.clickedRow
        guard src >= 0, src < queueRows.count else { return }
        let target = min(max(destination(src), 0), queueRows.count - 1)
        guard target != src else { return }
        var ids = queueRows.map { $0.id }
        let moved = ids.remove(at: src)
        ids.insert(moved, at: target)
        db.reorderQueue(ids: ids)
        reloadQueueData()
        table.reloadData()
    }

    // Delete the right-clicked queue row (menu), or the selected row (Delete key).
    @objc func deleteClickedQueueItem() { deleteQueueRow(at: queueTable?.clickedRow ?? -1) }

    private func deleteQueueRow(at row: Int) {
        guard row >= 0, row < queueRows.count else { return }
        db.removeFromQueue(id: queueRows[row].id)
        reloadQueueData()
        queueTable?.reloadData()
    }

    // Copy the selected queue rows to the clipboard as TSV (with a header).
    private func copyQueueRows(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        var lines = ["Duration (s)\tFocus"]
        for i in indexes where i < queueRows.count {
            let q = queueRows[i]
            let fields = [
                "\(q.seconds)",
                q.focus,
            ].map(tsvClean)
            lines.append(fields.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn?.identifier.rawValue else { return nil }

        if tableView === queueTable {
            guard row < queueRows.count else { return nil }
            let q = queueRows[row]
            let text: String
            var align: NSTextAlignment = .left
            let est = row < queueEstimates.count ? queueEstimates[row] : nil
            switch id {
            case "pos":    text = "\(row + 1)"; align = .right
            case "min":    text = mmss(q.seconds); align = .right
            case "start":  text = est.map { localClockFormatter.string(from: $0.start) } ?? ""; align = .right
            case "finish": text = est.map { localClockFormatter.string(from: $0.finish) } ?? ""; align = .right
            default:       text = q.focus
            }
            return historyCell(tableView, id: id, text: text, align: align)
        }

        guard row < historyRows.count else { return nil }
        let r = historyRows[row]
        let text: String
        var align: NSTextAlignment = .left
        switch id {
        case "when":      text = whenLabel(r.startedAt)
        case "min":       text = mmss(r.seconds); align = .right
        case "origmin":   text = r.originalSeconds.map { mmss($0) } ?? "—"; align = .right
        case "rating":    text = r.rating.map { "\($0)/10" } ?? "—"; align = .right
        case "status":    text = r.status ?? (r.endedAt == nil ? "active" : "—")
        case "openstart": text = mmss(r.openSecondsStart ?? 0); align = .right   // NULL shows 0:00
        case "openend":   text = mmss(r.openSecondsEnd ?? 0); align = .right
        case "note":      text = r.note ?? ""
        default:          text = r.focus
        }
        return historyCell(tableView, id: id, text: text, align: align)
    }

    private func historyCell(_ table: NSTableView, id: String, text: String,
                             align: NSTextAlignment) -> NSTableCellView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let cell: NSTableCellView
        if let reused = table.makeView(withIdentifier: identifier, owner: self) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = identifier
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            tf.lineBreakMode = .byTruncatingTail
            tf.font = NSFont.systemFont(ofSize: 12)
            cell.addSubview(tf)
            cell.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
                tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = text
        cell.textField?.alignment = align
        return cell
    }

    // ---- per-second update ----
    private func tick() {
        if let focus = currentFocus, let dl = deadline {
            let remaining = Int(dl.timeIntervalSinceNow.rounded())
            if remaining <= 0 {
                // Don't raise the (non-app-modal) time's-up panel while a menu /
                // tracking loop is up: our event pump would nest inside it and the
                // open menu would swallow keyboard input. Dismiss the menu and defer
                // to the next tick, which runs in the normal run-loop mode.
                if RunLoop.current.currentMode == .eventTracking {
                    statusItem.menu?.cancelTracking()
                    return
                }
                timeUp(focus: focus)
                return
            }
            // Optionally append "/ total" — e.g. 3:00 / 5:00 = 3 min left of a 5 min session.
            let time = showTotalOnPillEnabled ? "\(mmss(remaining)) / \(mmss(sessionSeconds ?? remaining))"
                                              : mmss(remaining)
            hudLabel.stringValue = "🎯 \(focus)    \(time)"
            layoutHUD()
            if showPillEnabled {
                hudWindow.orderFrontRegardless()
            } else {
                hudWindow.orderOut(nil)
            }
        } else {
            hudWindow.orderOut(nil)
        }
    }

    // ---- notify preferences (persisted) ----
    private var playSoundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "playSound") as? Bool ?? true }  // default on
        set { UserDefaults.standard.set(newValue, forKey: "playSound") }
    }
    private var pushoverEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pushover") }                       // default off
        set { UserDefaults.standard.set(newValue, forKey: "pushover") }
    }
    private var autoProceedEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "autoProceed") }                    // default off
        set { UserDefaults.standard.set(newValue, forKey: "autoProceed") }
    }
    private var showPillEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showPill") as? Bool ?? true }    // default on
        set { UserDefaults.standard.set(newValue, forKey: "showPill") }
    }
    private var showTotalOnPillEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "showTotalOnPill") as? Bool ?? true }  // default on
        set { UserDefaults.standard.set(newValue, forKey: "showTotalOnPill") }
    }

    /// The global preference checkboxes, initialized from the stored values,
    /// for the Settings dialog.
    private func preferenceCheckboxes() -> (sound: NSButton, pushover: NSButton, auto: NSButton, total: NSButton) {
        let sound = NSButton(checkboxWithTitle: "Play sound when time's up", target: nil, action: nil)
        sound.state = playSoundEnabled ? .on : .off
        let pushover = NSButton(checkboxWithTitle: "Send Pushover notification at start and end of sessions", target: nil, action: nil)
        pushover.state = pushoverEnabled ? .on : .off
        let auto = NSButton(checkboxWithTitle: "Auto-proceed with next queued task", target: nil, action: nil)
        auto.state = autoProceedEnabled ? .on : .off
        let total = NSButton(checkboxWithTitle: "Show total session time after remaining time", target: nil, action: nil)
        total.state = showTotalOnPillEnabled ? .on : .off
        return (sound, pushover, auto, total)
    }

    private func persistPreferences(_ sound: NSButton, _ pushover: NSButton, _ auto: NSButton, _ total: NSButton) {
        playSoundEnabled = sound.state == .on
        pushoverEnabled = pushover.state == .on
        autoProceedEnabled = auto.state == .on
        showTotalOnPillEnabled = total.state == .on
    }

    // Standalone Settings dialog for the global preferences.
    @objc func showSettings() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        NSApp.activate(ignoringOtherApps: true)

        let (sound, pushover, auto, total) = preferenceCheckboxes()
        total.frame = NSRect(x: 0, y: 78, width: 460, height: 20)
        sound.frame = NSRect(x: 0, y: 52, width: 460, height: 20)
        pushover.frame = NSRect(x: 0, y: 26, width: 460, height: 20)
        auto.frame = NSRect(x: 0, y: 0, width: 460, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 98))
        accessory.addSubview(total)
        accessory.addSubview(sound)
        accessory.addSubview(pushover)
        accessory.addSubview(auto)

        let alert = makeAlert()
        alert.messageText = "Settings"
        alert.informativeText = "These apply to every session."
        alert.addButton(withTitle: "Done")
        alert.accessoryView = accessory
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        alert.runModal()

        persistPreferences(sound, pushover, auto, total)
        tick()   // apply the pill's remaining/total toggle immediately
    }

    /// Fire-and-forget Pushover message. Credentials come from ~/focus/pushover.json
    /// ({"token":"...","user":"..."}), so they stay out of the code/repo.
    private func sendPushover(title: String, message: String) {
        let credURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("focus/pushover.json")
        guard let data = try? Data(contentsOf: credURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = json["token"] as? String,
              let user = json["user"] as? String else {
            FileHandle.standardError.write(
                "focus: Pushover enabled but ~/focus/pushover.json is missing or invalid\n"
                    .data(using: .utf8)!)
            return
        }
        var req = URLRequest(url: URL(string: "https://api.pushover.net/1/messages.json")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var comps = URLComponents()
        comps.queryItems = [
            URLQueryItem(name: "token", value: token),
            URLQueryItem(name: "user", value: user),
            URLQueryItem(name: "title", value: title),
            URLQueryItem(name: "message", value: message),
        ]
        req.httpBody = comps.percentEncodedQuery?.data(using: .utf8)
        URLSession.shared.dataTask(with: req) { _, response, error in
            if let error = error {
                FileHandle.standardError.write("focus: Pushover error: \(error)\n".data(using: .utf8)!)
            }
        }.resume()
    }

    private func timeUp(focus: String) {
        guard !showing else { return }   // a prompt is open; retry on the next tick
        showing = true

        if playSoundEnabled { NSSound(named: timeUpSoundName)?.play() }
        if pushoverEnabled { sendPushover(title: "Time's up", message: focus) }

        hudWindow.orderOut(nil)   // hide the frozen-at-0:00 pill during the modal

        // Hands-free: complete without a rating (defer it to "Rate unrated
        // sessions") and roll straight into the next queued focus.
        if autoProceedEnabled {
            let endedId = sessionId
            currentFocus = nil
            deadline = nil
            sessionId = nil
            if let id = endedId { db.endSession(id: id, status: "completed", rating: nil) }
            showing = false
            promptForFocus(reason: "after-session")
            return
        }

        switch promptTimeUp(focus: focus, seconds: sessionSeconds ?? 0) {
        case .addTime(let added):
            // Keep the SAME session going. The popup-open time was already accounted
            // (to duration or end, per the checkbox) inside promptTimeUp — just extend.
            extendSession(by: added)
            showing = false

        case .rate(let rating, let note, let openSeconds, let applyTime):
            let endedId = sessionId
            currentFocus = nil
            deadline = nil
            sessionId = nil
            if let id = endedId {
                db.endSession(id: id, status: "completed", rating: rating, note: note,
                              openSecondsEnd: applyTime ? nil : openSeconds)
                if applyTime { db.addToDuration(id: id, seconds: openSeconds) }
            }
            // Roll straight into the next session: having rated, set a new focus.
            showing = false
            promptForFocus(reason: "after-session")
        }
    }

    private enum TimeUpChoice { case rate(rating: Int, note: String, openSeconds: Int, applyTime: Bool); case addTime(added: Int) }

    /// Time's-up modal: rate 1–10 (+ optional note) to finish, or add more time.
    private func promptTimeUp(focus: String, seconds: Int) -> TimeUpChoice {
        NSApp.activate(ignoringOtherApps: true)
        let (accessory, ratingField, noteField, elapsed, apply) = ratingAccessory()
        let (timer, openSeconds, resetElapsed) = startElapsedTimer(elapsed)
        defer { timer.invalidate() }
        while true {
            let alert = makeAlert()
            alert.messageText = "Time's up"
            alert.informativeText = "Focus: \(focus)\n\(mmss(seconds))\n\nRate it 1–10 to finish (optional note), or add more time:"
            alert.addButton(withTitle: "Save")        // index 0
            alert.addButton(withTitle: "Add time…")   // index 1
            alert.accessoryView = accessory
            // Non-app-modal so the menu stays usable while the prompt is up.
            let clicked = runFloatingAlert(alert, firstResponder: ratingField)

            if clicked == 1 {
                // Account for the popup-open time so far right now (before the Add-time
                // prompt): to the session's duration if "Apply this time" is checked,
                // otherwise banked as end-popup-open. Then restart the counter so this
                // stretch isn't counted again on the next Add-time / rating.
                if let id = sessionId {
                    let span = openSeconds()
                    if apply.state == .on { db.addToDuration(id: id, seconds: span) }
                    else { db.addOpenSecondsEnd(id: id, seconds: span) }
                    resetElapsed()
                }
                if let extra = askMinutes() {
                    return .addTime(added: extra)
                }
                continue   // cancelled the add → back to the time's-up modal
            }
            let rating = Int(ratingField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if (1...10).contains(rating) {
                return .rate(rating: rating,
                             note: noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                             openSeconds: openSeconds(), applyTime: apply.state == .on)
            }
            // invalid rating → loop
        }
    }

    /// "Add time" minutes prompt (cancellable). The field takes whole minutes
    /// (negative to subtract) and returns seconds (×60), or nil if cancelled.
    private func askMinutes() -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = "5"
        while true {
            let alert = makeAlert()
            alert.messageText = "Add time"
            alert.informativeText = "How many minutes? (negative to subtract)"
            alert.addButton(withTitle: "Add")       // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")    // .alertSecondButtonReturn
            alert.accessoryView = field
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = field
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return nil }
            // Any non-zero whole number: positive adds time, negative subtracts.
            if let m = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), m != 0 { return m * 60 }
        }
    }

    /// Force a rating, then close the current session out as completed and clear
    /// its state. Caller must already hold `showing`. Completing early records the
    /// time actually used as the Duration (Original Duration is untouched).
    private func rateAndComplete() {
        guard let id = sessionId, let focus = currentFocus else { return }
        let elapsed = max(0, Int(Date().timeIntervalSince(sessionStart ?? Date()).rounded()))
        currentFocus = nil
        deadline = nil
        sessionId = nil
        sessionStart = nil
        sessionSeconds = nil
        sessionOriginalId = nil
        hudWindow.orderOut(nil)
        let (rating, note, openSeconds, applyTime) = promptRating(focus: focus, title: "Rate this session")
        db.endSession(id: id, status: "completed", rating: rating, note: note,
                      openSecondsEnd: applyTime ? nil : openSeconds, elapsedSeconds: elapsed)
        if applyTime { db.addToDuration(id: id, seconds: openSeconds) }
    }

    /// A rating (1–10) field over an optional note field, for the rating modals,
    /// with the "Open for M:SS" timer on top and an "apply this time" checkbox below it.
    private func ratingAccessory() -> (view: NSView, rating: NSTextField, note: NSTextField, elapsed: NSTextField, apply: NSButton) {
        let ratingField = NSTextField(frame: NSRect(x: 0, y: 34, width: 80, height: 24))
        ratingField.placeholderString = "1–10"
        let noteField = NSTextField(frame: NSRect(x: 0, y: 2, width: 340, height: 24))
        noteField.placeholderString = "Note (optional)"
        // When checked, the popup-open time is added to the session's duration
        // instead of being recorded as end-popup-open time (which becomes 0).
        // Small + gray to sit with the "Open for …" timer above it.
        let apply = NSButton(checkboxWithTitle: "", target: nil, action: nil)
        apply.controlSize = .small
        apply.attributedTitle = NSAttributedString(
            string: "Apply this time to the previous focus session",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        apply.frame = NSRect(x: 0, y: 78, width: 340, height: 18)
        apply.state = .off
        let elapsed = NSTextField(labelWithString: "")
        elapsed.frame = NSRect(x: 0, y: 100, width: 340, height: 18)
        elapsed.font = NSFont.systemFont(ofSize: 11)
        elapsed.textColor = .secondaryLabelColor
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 122))
        view.addSubview(ratingField)
        view.addSubview(noteField)
        view.addSubview(apply)
        view.addSubview(elapsed)
        // Wire the field editor loop so Tab / Shift-Tab cycle rating ⇄ note.
        ratingField.nextKeyView = noteField
        noteField.nextKeyView = ratingField
        return (view, ratingField, noteField, elapsed, apply)
    }

    /// A `.common`-mode timer that shows how long the modal has been open, so it
    /// keeps ticking while runModal blocks. Caller invalidates the timer, and can
    /// call `openSeconds()` at close time to get the elapsed seconds (rounded).
    private func startElapsedTimer(_ label: NSTextField) -> (timer: Timer, openSeconds: () -> Int, reset: () -> Void) {
        var openedAt = Date()   // var so `reset` can restart the count
        label.stringValue = "Open for 0:00"
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            label.stringValue = "Open for \(mmss(Int(Date().timeIntervalSince(openedAt))))"
        }
        RunLoop.main.add(timer, forMode: .common)
        return (timer,
                { Int(Date().timeIntervalSince(openedAt).rounded()) },
                { openedAt = Date(); label.stringValue = "Open for 0:00" })
    }

    /// Mandatory 1–10 rating modal (+ optional note) — floating, loops until valid.
    private func promptRating(focus: String, title: String) -> (rating: Int, note: String, openSeconds: Int, applyTime: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let (accessory, ratingField, noteField, elapsed, apply) = ratingAccessory()
        let (timer, openSeconds, _) = startElapsedTimer(elapsed)
        defer { timer.invalidate() }
        var rating = 0
        while rating < 1 || rating > 10 {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = "Focus: \(focus)\n\nRate it 1–10 (optional note):"
            alert.addButton(withTitle: "Save")
            alert.accessoryView = accessory
            // Non-app-modal so the 🎯 menu stays usable while the prompt is up.
            _ = runFloatingAlert(alert, firstResponder: ratingField)
            rating = Int(ratingField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return (rating, noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                openSeconds(), apply.state == .on)
    }

    // ---- UI construction ----

    // Without a main menu, an .accessory app never dispatches the standard
    // editing key equivalents (⌘A/⌘C/⌘V/⌘X/⌘Z) to the text field's field editor,
    // so copy/paste/select-all silently do nothing in our modals. Providing an
    // Edit menu with the usual first-responder actions restores them.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Quit focus",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        NSApp.mainMenu = mainMenu
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎯"   // fixed icon; never changes, so it never relayouts
        let menu = NSMenu()
        // The running task (these grey out when idle, except changeFocus → "Set focus").
        menu.addItem(withTitle: "Complete task", action: #selector(completeTask), keyEquivalent: "")
        menu.addItem(withTitle: "Add time", action: #selector(addTimeToCurrent), keyEquivalent: "")
        menu.addItem(withTitle: "Defer task", action: #selector(deferTask), keyEquivalent: "")
        menu.addItem(withTitle: "Abort task", action: #selector(abortTask), keyEquivalent: "")
        menu.addItem(withTitle: "Switch focus now", action: #selector(changeFocus), keyEquivalent: "")
        menu.addItem(.separator())
        // The queue.
        menu.addItem(withTitle: "Add to queue", action: #selector(addNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Add focus to front", action: #selector(preemptNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "See queue", action: #selector(showQueue), keyEquivalent: "")
        menu.addItem(withTitle: "Clear queue", action: #selector(clearQueue), keyEquivalent: "")
        menu.addItem(.separator())
        // Review.
        menu.addItem(withTitle: "See history", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Rate unrated sessions", action: #selector(rateUnrated), keyEquivalent: "")
        menu.addItem(.separator())
        // App.
        menu.addItem(withTitle: "Show current task", action: #selector(toggleShowPill), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Quit focus", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
        statusItem.menu = menu
    }

    private func buildHUD() {
        hudWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 34),
                             styleMask: .borderless, backing: .buffered, defer: false)
        hudWindow.isOpaque = false
        hudWindow.backgroundColor = .clear
        hudWindow.hasShadow = true
        hudWindow.isMovableByWindowBackground = true   // drag the pill anywhere on it
        hudWindow.delegate = self                      // to notice user drags (windowDidMove)
        hudWindow.level = .statusBar                   // above normal windows
        hudWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = NSVisualEffectView(frame: hudWindow.contentView!.bounds)
        blur.material = .hudWindow
        blur.state = .active
        blur.blendingMode = .behindWindow
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 10
        blur.layer?.masksToBounds = true
        blur.autoresizingMask = [.width, .height]

        hudLabel = NSTextField(labelWithString: "")
        hudLabel.font = NSFont.systemFont(ofSize: 14, weight: .semibold)
        hudLabel.textColor = .white
        hudLabel.backgroundColor = .clear
        hudLabel.isBezeled = false
        hudLabel.isEditable = false

        blur.addSubview(hudLabel)
        hudWindow.contentView = blur
    }

    private func layoutHUD() {
        // Don't move/resize the pill mid-drag (primary mouse button held) — that
        // would fight the drag. It re-justifies on the first tick after release.
        if (NSEvent.pressedMouseButtons & 1) != 0 { return }

        hudLabel.sizeToFit()
        let padX: CGFloat = 14, padY: CGFloat = 8
        let w = hudLabel.frame.width + padX * 2
        let h = hudLabel.frame.height + padY * 2
        hudLabel.setFrameOrigin(NSPoint(x: padX, y: padY))

        // Anchor the top-right corner (right edge + top edge), so the pill grows
        // left/down as the focus text changes and stays neatly justified — whether
        // it's at the default corner or wherever the user dragged it.
        let topRight: NSPoint
        if let dragged = hudAnchorTopRight {
            topRight = dragged
        } else {
            guard let screen = NSScreen.main else { return }
            let vf = screen.visibleFrame
            topRight = NSPoint(x: vf.maxX - 16, y: vf.maxY - 12)
        }
        let origin = NSPoint(x: topRight.x - w, y: topRight.y - h)
        hudProgrammaticMove = true
        hudWindow.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        hudProgrammaticMove = false
    }

    // The user dragged the pill — remember its top-right corner so layoutHUD keeps
    // that fixed (and stops snapping back to the screen corner).
    func windowDidMove(_ notification: Notification) {
        guard (notification.object as? NSWindow) === hudWindow, !hudProgrammaticMove else { return }
        hudAnchorTopRight = NSPoint(x: hudWindow.frame.maxX, y: hudWindow.frame.maxY)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // background app, no Dock icon; allows status item
let controller = AppController()
app.delegate = controller
app.run()
