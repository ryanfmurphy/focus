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
            minutes    INTEGER,       -- planned duration
            focus      TEXT,
            rating     INTEGER,       -- 1..10, only for completed sessions
            status     TEXT,          -- completed / interrupted (NULL while active)
            note       TEXT,          -- optional note written when rating
            original_session_id INTEGER  -- root of a pre-empt→continued chain (NULL if this is the original)
        );
        """)
        // Migrations for older DBs (each errors harmlessly if already applied).
        exec("ALTER TABLE sessions ADD COLUMN note TEXT;")
        exec("ALTER TABLE sessions RENAME COLUMN outcome TO status;")
        exec("ALTER TABLE sessions ADD COLUMN original_session_id INTEGER;")
        // FIFO queue of upcoming sessions. Front = lowest id; "add to end" is a
        // plain insert; "pop off" deletes the lowest id.
        exec("""
        CREATE TABLE IF NOT EXISTS queue (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            minutes    INTEGER,
            focus      TEXT,
            original_session_id INTEGER  -- carries the chain root onto the resumed session
        );
        """)
        exec("ALTER TABLE queue ADD COLUMN original_session_id INTEGER;")
        // One row per "Add time" event, so a session extended N times has N rows
        // (sessions.minutes is also bumped to the running total).
        exec("""
        CREATE TABLE IF NOT EXISTS time_additions (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id INTEGER NOT NULL,
            added_at   TEXT NOT NULL,
            minutes    INTEGER
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
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// Insert a new in-progress session; returns its row id.
    func startSession(reason: String, minutes: Int, focus: String, originalSessionId: Int64?) -> Int64? {
        let sql = "INSERT INTO sessions (started_at, reason, minutes, focus, original_session_id) VALUES (?,?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, reason, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(minutes))
        sqlite3_bind_text(stmt, 4, focus, -1, SQLITE_TRANSIENT)
        if let o = originalSessionId { sqlite3_bind_int64(stmt, 5, o) } else { sqlite3_bind_null(stmt, 5) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    // Bind an optional note (empty → NULL) at the given parameter index.
    private func bindNote(_ stmt: OpaquePointer?, _ idx: Int32, _ note: String) {
        if note.isEmpty { sqlite3_bind_null(stmt, idx) }
        else { sqlite3_bind_text(stmt, idx, note, -1, SQLITE_TRANSIENT) }
    }

    /// Close out a session with a status, (optionally) a rating, and a note.
    func endSession(id: Int64, status: String, rating: Int?, note: String = "") {
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
    }

    /// Close a session as "interrupted", recording how many minutes it actually
    /// ran (overwriting the planned minutes), with an optional rating/note.
    func markInterrupted(id: Int64, elapsedMinutes: Int, rating: Int? = nil, note: String = "") {
        let sql = "UPDATE sessions SET ended_at=?, status='interrupted', minutes=?, rating=?, note=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(elapsedMinutes))
        if let r = rating { sqlite3_bind_int(stmt, 3, Int32(r)) } else { sqlite3_bind_null(stmt, 3) }
        bindNote(stmt, 4, note)
        sqlite3_bind_int64(stmt, 5, id)
        sqlite3_step(stmt)
    }

    /// Log an "Add time" event and bump the session's total minutes.
    func addTime(sessionId: Int64, minutes: Int) {
        var ins: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO time_additions (session_id, added_at, minutes) VALUES (?,?,?);",
                              -1, &ins, nil) == SQLITE_OK {
            sqlite3_bind_int64(ins, 1, sessionId)
            sqlite3_bind_text(ins, 2, isoNow(), -1, SQLITE_TRANSIENT)
            sqlite3_bind_int(ins, 3, Int32(minutes))
            sqlite3_step(ins)
        }
        sqlite3_finalize(ins)

        var upd: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE sessions SET minutes = minutes + ? WHERE id = ?;",
                              -1, &upd, nil) == SQLITE_OK {
            sqlite3_bind_int(upd, 1, Int32(minutes))
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
        let sql = "SELECT id, started_at, minutes, focus, original_session_id FROM sessions WHERE ended_at IS NULL ORDER BY id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ActiveSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            let orig = sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 4)
            rows.append(ActiveSession(id: sqlite3_column_int64(stmt, 0),
                                      startedAt: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                                      minutes: Int(sqlite3_column_int(stmt, 2)),
                                      focus: focus, originalSessionId: orig))
        }
        return rows
    }

    /// Completed sessions with no rating yet (deferred), oldest first.
    func unratedCompleted() -> [ActiveSession] {
        let sql = """
        SELECT id, started_at, minutes, focus, original_session_id FROM sessions
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
                                      minutes: Int(sqlite3_column_int(stmt, 2)),
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

    /// Set a rating and note on an already-completed session ("Rate unrated sessions").
    func setRating(id: Int64, rating: Int, note: String = "") {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET rating=?, note=? WHERE id=?;", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(rating))
        bindNote(stmt, 2, note)
        sqlite3_bind_int64(stmt, 3, id)
        sqlite3_step(stmt)
    }

    /// Most recent sessions, newest first, for the history window.
    func recent(limit: Int = 500) -> [SessionRow] {
        let sql = """
        SELECT started_at, ended_at, minutes, focus, rating, status, note
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

        var rows: [SessionRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let rating: Int? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil : Int(sqlite3_column_int(stmt, 4))
            rows.append(SessionRow(
                startedAt: text(0) ?? "",
                endedAt: text(1),
                minutes: Int(sqlite3_column_int(stmt, 2)),
                focus: text(3) ?? "",
                rating: rating,
                status: text(5),
                note: text(6)))
        }
        return rows
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
        let sql = "SELECT id, minutes, focus, original_session_id FROM queue ORDER BY id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [QueueItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            let orig = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
            rows.append(QueueItem(id: sqlite3_column_int64(stmt, 0),
                                  minutes: Int(sqlite3_column_int(stmt, 1)),
                                  focus: focus, originalSessionId: orig))
        }
        return rows
    }

    /// Append a focus to the end of the queue.
    func enqueue(focus: String, minutes: Int) {
        let sql = "INSERT INTO queue (created_at, minutes, focus) VALUES (?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(minutes))
        sqlite3_bind_text(stmt, 3, focus, -1, SQLITE_TRANSIENT)
        sqlite3_step(stmt)
    }

    /// Insert at the FRONT of the queue (used when pre-empting the current focus).
    /// Ordering is by id ASC, so give it an id below the current minimum.
    /// `originalSessionId` carries the chain root onto the eventual resumed session.
    func enqueueFront(focus: String, minutes: Int, originalSessionId: Int64?) {
        let sql = """
        INSERT INTO queue (id, created_at, minutes, focus, original_session_id)
        VALUES ((SELECT COALESCE(MIN(id), 1) - 1 FROM queue), ?, ?, ?, ?);
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(minutes))
        sqlite3_bind_text(stmt, 3, focus, -1, SQLITE_TRANSIENT)
        if let o = originalSessionId { sqlite3_bind_int64(stmt, 4, o) } else { sqlite3_bind_null(stmt, 4) }
        sqlite3_step(stmt)
    }

    /// The next queued focus (front of the FIFO), or nil if the queue is empty.
    func frontOfQueue() -> QueueItem? {
        let sql = "SELECT id, minutes, focus, original_session_id FROM queue ORDER BY id ASC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        let orig = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 3)
        return QueueItem(id: sqlite3_column_int64(stmt, 0),
                         minutes: Int(sqlite3_column_int(stmt, 1)),
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
    let minutes: Int
    let focus: String
    let originalSessionId: Int64?
}

struct ActiveSession {
    let id: Int64
    let startedAt: String
    let minutes: Int
    let focus: String
    let originalSessionId: Int64?
}

struct SessionRow {
    let startedAt: String
    let endedAt: String?
    let minutes: Int
    let focus: String
    let rating: Int?
    let status: String?
    let note: String?
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

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource,
                           NSTableViewDelegate, NSMenuItemValidation {
    private let db = DB()

    // ---- session state ----
    private var currentFocus: String?
    private var deadline: Date?
    private var sessionId: Int64?
    private var sessionStart: Date?   // when the current session began (for elapsed time)
    private var sessionMinutes: Int?  // planned duration of the current session (incl. added time)
    private var sessionOriginalId: Int64?  // chain root if this session continues an interrupted one

    // Debounce guards for the return-prompt (wake + unlock + session often fire
    // together). `showing` also stops any modal from stacking on another.
    private var showing = false
    private var lastFired = Date.distantPast
    private let cooldown: TimeInterval = 10

    // ---- ui ----
    private var statusItem: NSStatusItem!
    private var hudWindow: NSWindow!
    private var hudLabel: NSTextField!
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

        let deadline = start.addingTimeInterval(Double(candidate.minutes) * 60)
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
        alert.informativeText = "\(s.focus)\n\n\(mmss(remaining)) remaining (of \(s.minutes) min)"
        alert.addButton(withTitle: "Resume")            // .alertFirstButtonReturn
        alert.addButton(withTitle: "Start new focus")   // .alertSecondButtonReturn
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        showing = false

        if response == .alertFirstButtonReturn {
            adopt(s, deadline: deadline)
            tick()
        } else {
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
        sessionMinutes = s.minutes
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
        let title = preempting ? "Pre-empt with a new focus" : "Set focus"
        let info = preempting
            ? "This runs now; the current focus goes to the front of the queue."
            : "What's your one focus right now, and for how long?"

        // Pre-empt is voluntary → cancellable (cancel leaves the current session
        // untouched). Idle "Set focus" stays mandatory.
        guard let (focus, minutes) = askFocusAndMinutes(
            title: title, info: info, confirm: "Start", cancellable: preempting) else { return }

        var preemptedId: Int64? = nil
        if preempting, let id = sessionId, let curFocus = currentFocus, let dl = deadline {
            preemptedId = id
            let remaining = max(1, Int((dl.timeIntervalSinceNow / 60).rounded()))
            let elapsed = max(0, Int((Date().timeIntervalSince(sessionStart ?? Date()) / 60).rounded()))
            // Complete the existing record as interrupted, recording elapsed minutes.
            db.markInterrupted(id: id, elapsedMinutes: elapsed)
            // Queue a fresh copy for the remaining time to resume next, carrying
            // the chain root (this session's original, or itself if it's the root).
            db.enqueueFront(focus: continuedName(curFocus), minutes: remaining,
                            originalSessionId: sessionOriginalId ?? id)
        }
        beginSession(reason: preempting ? "preempt" : "manual", minutes: minutes, focus: focus)
        if preempting { db.recordPreempt(preemptedSessionId: preemptedId, newSessionId: sessionId) }
    }

    // Prompt for minutes and add them to the running session — same as choosing
    // "Add time" at time's up, but available any time from the menu.
    @objc func addTimeToCurrent() {
        guard !showing, sessionId != nil else { return }
        showing = true
        defer { showing = false }
        if let extra = askMinutes() { extendSession(by: extra) }
    }

    /// Log an "Add time" event, bump the planned total, and extend the deadline.
    /// Extends from whichever is later — now or the current deadline — so it adds
    /// the full `extra` when the timer's already up, or on top of remaining time.
    private func extendSession(by extra: Int) {
        guard let id = sessionId else { return }
        db.addTime(sessionId: id, minutes: extra)
        sessionMinutes = (sessionMinutes ?? 0) + extra
        let base = max(Date(), deadline ?? Date())
        deadline = base.addingTimeInterval(Double(extra) * 60)
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
        let elapsed = max(0, Int((Date().timeIntervalSince(sessionStart ?? Date()) / 60).rounded()))
        currentFocus = nil; deadline = nil; sessionId = nil
        sessionStart = nil; sessionMinutes = nil; sessionOriginalId = nil
        hudWindow.orderOut(nil)
        let (rating, note) = promptRating(focus: "\(focus) · \(elapsed) min", title: "Rate this session")
        db.markInterrupted(id: id, elapsedMinutes: elapsed, rating: rating, note: note)
        showing = false
        promptForFocus(reason: "after-session")
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // Complete / Abort / Pre-empt act on a running session.
        if menuItem.action == #selector(completeTask) || menuItem.action == #selector(abortTask)
            || menuItem.action == #selector(addTimeToCurrent) {
            return currentFocus != nil
        }
        if menuItem.action == #selector(changeFocus) {
            menuItem.title = currentFocus != nil ? "Pre-empt task" : "Set focus"
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
        return true
    }

    /// Queue a focus to run after the current/queued ones. Doesn't touch the
    /// active session. Cancellable, since it's a voluntary action.
    @objc func addNextFocus() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        if let (focus, minutes) = askFocusAndMinutes(
            title: "Add next focus",
            info: "Queue a focus to run after the current one.",
            confirm: "Add to queue", cancellable: true) {
            db.enqueue(focus: focus, minutes: minutes)
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

        guard let (answer, minutes) = askFocusAndMinutes(
            title: "Welcome back",
            info: "What's your one focus right now, and for how long?",
            confirm: "Start", cancellable: false) else { return }
        beginSession(reason: reason, minutes: minutes, focus: answer)
    }

    /// Non-editable confirmation for the next queued focus. Pops it off and starts.
    /// When `autoEligible` and the auto-proceed preference is on, a 10s countdown
    /// auto-starts it (as if "Start" were clicked).
    private func confirmQueued(_ item: QueueItem, autoEligible: Bool) {
        let alert = makeAlert()
        alert.messageText = "Next focus"
        alert.informativeText = "\(item.focus)\n\n\(item.minutes) minutes"
        alert.addButton(withTitle: "Start")                  // .alertFirstButtonReturn
        alert.addButton(withTitle: "Pre-empt with another…") // .alertSecondButtonReturn
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        var autoTimer: Timer?
        if autoEligible && autoProceedEnabled {
            let label = NSTextField(wrappingLabelWithString: "")
            label.frame = NSRect(x: 0, y: 0, width: 340, height: 34)
            label.alignment = .center
            label.font = NSFont.systemFont(ofSize: 12)
            alert.accessoryView = label
            var remaining = 10
            label.stringValue = "Will automatically proceed with this focus in \(remaining) seconds."
            // .common mode so it fires while the modal is up; stopModal with the
            // first-button code ends runModal exactly as a "Start" click would.
            let timer = Timer(timeInterval: 1, repeats: true) { t in
                remaining -= 1
                if remaining <= 0 {
                    t.invalidate()
                    NSApp.stopModal(withCode: .alertFirstButtonReturn)
                } else {
                    label.stringValue = "Will automatically proceed with this focus in \(remaining) second\(remaining == 1 ? "" : "s")."
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            autoTimer = timer
        }

        let response = alert.runModal()
        autoTimer?.invalidate()

        if response == .alertSecondButtonReturn {
            // Pre-empt: leave the queued item where it is (still the front, since
            // we never removed it) and run an ad-hoc focus right now instead.
            if let (focus, minutes) = askFocusAndMinutes(
                title: "Pre-empt with a new focus",
                info: "This runs now; the queued focus stays next in line.",
                confirm: "Start", cancellable: true) {
                beginSession(reason: "preempt", minutes: minutes, focus: focus)
                // Nothing was underway → preempted_session_id is NULL.
                db.recordPreempt(preemptedSessionId: nil, newSessionId: sessionId)
                return
            }
            // Cancelled the pre-empt → fall through and start the queued one.
        }

        db.removeFromQueue(id: item.id)
        beginSession(reason: "queue", minutes: item.minutes, focus: item.focus,
                     originalSessionId: item.originalSessionId)
    }

    /// Editable "focus + minutes" modal. Loops until valid; returns nil only if
    /// `cancellable` and the user cancels.
    private func askFocusAndMinutes(title: String, info: String, confirm: String,
                                    cancellable: Bool) -> (String, Int)? {
        NSApp.activate(ignoringOtherApps: true)

        let focusField = NSTextField(frame: NSRect(x: 0, y: 114, width: 320, height: 24))
        focusField.placeholderString = "e.g. Ship the focus pill"

        let minutesLabel = NSTextField(labelWithString: "Minutes:")
        minutesLabel.frame = NSRect(x: 0, y: 82, width: 60, height: 24)
        let minutesField = NSTextField(frame: NSRect(x: 62, y: 82, width: 70, height: 24))
        minutesField.stringValue = String(defaultMinutes)

        let (soundCheck, pushoverCheck, autoProceedCheck) = preferenceCheckboxes()
        soundCheck.frame = NSRect(x: 0, y: 54, width: 320, height: 20)
        pushoverCheck.frame = NSRect(x: 0, y: 28, width: 320, height: 20)
        autoProceedCheck.frame = NSRect(x: 0, y: 2, width: 320, height: 20)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 138))
        accessory.addSubview(focusField)
        accessory.addSubview(minutesLabel)
        accessory.addSubview(minutesField)
        accessory.addSubview(soundCheck)
        accessory.addSubview(pushoverCheck)
        accessory.addSubview(autoProceedCheck)

        while true {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: confirm)             // .alertFirstButtonReturn
            if cancellable { alert.addButton(withTitle: "Cancel") }
            alert.accessoryView = accessory
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = focusField
            let response = alert.runModal()

            if cancellable && response == .alertSecondButtonReturn { return nil }

            // Persist the checkbox choices as the standing preference.
            persistPreferences(soundCheck, pushoverCheck, autoProceedCheck)

            let answer = focusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let minutes = Int(minutesField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if !answer.isEmpty && minutes > 0 { return (answer, minutes) }
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

    private func beginSession(reason: String, minutes: Int, focus: String, originalSessionId: Int64? = nil) {
        currentFocus = focus
        sessionStart = Date()
        sessionMinutes = minutes
        sessionOriginalId = originalSessionId
        deadline = Date().addingTimeInterval(Double(minutes) * 60)
        sessionId = db.startSession(reason: reason, minutes: minutes, focus: focus,
                                    originalSessionId: originalSessionId)
        if pushoverEnabled { sendPushover(title: "Focus started", message: "\(focus) — \(minutes) min") }
        tick()
    }

    // ---- history ----
    @objc func showHistory() {
        historyRows = db.recent()

        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Focus history"
            window.isReleasedWhenClosed = false   // we keep & reuse it
            window.center()

            let scroll = NSScrollView(frame: window.contentView!.bounds)
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.borderType = .noBorder

            let table = CopyableTableView()
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.rowHeight = 22
            table.allowsColumnResizing = true
            table.allowsMultipleSelection = true   // Shift/⌘-click to select a range
            table.style = .inset
            table.onCopy = { [weak self] indexes in self?.copyHistoryRows(indexes) }

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
            addColumn("min", "Min", width: 48, min: 40, align: .right)
            addColumn("rating", "Rating", width: 60, min: 50, align: .right)
            addColumn("status", "Status", width: 95, min: 70)
            addColumn("focus", "Focus", width: 240, min: 150)
            addColumn("note", "Note", width: 220, min: 100)   // flexible last column

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
        var lines = ["Started\tMinutes\tRating\tStatus\tFocus\tNote"]
        for i in indexes where i < historyRows.count {
            let r = historyRows[i]
            let fields = [
                whenLabel(r.startedAt),
                "\(r.minutes)",
                r.rating.map { "\($0)" } ?? "",
                r.status ?? (r.endedAt == nil ? "active" : ""),
                r.focus,
                r.note ?? "",
            ].map(tsvClean)
            lines.append(fields.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // TSV has no quoting, so flatten any tabs/newlines in a field to spaces.
    private func tsvClean(_ s: String) -> String {
        s.replacingOccurrences(of: "\t", with: " ")
         .replacingOccurrences(of: "\n", with: " ")
         .replacingOccurrences(of: "\r", with: " ")
    }

    @objc func showQueue() {
        queueRows = db.queueItems()

        // Estimated schedule: start from when the current session finishes (its
        // deadline, if one is running and still ahead), else now, then chain each
        // queued item's minutes.
        var cursor = Date()
        if let dl = deadline, dl > cursor { cursor = dl }
        queueEstimates = queueRows.map { item in
            let start = cursor
            let finish = cursor.addingTimeInterval(Double(item.minutes) * 60)
            cursor = finish
            return (start, finish)
        }

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

            let table = NSTableView()
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
            table.rowHeight = 22
            table.style = .inset

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
            addColumn("min", "Min", width: 48, min: 40, align: .right)
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
        let count = db.queueCount()
        guard count > 0 else { return }
        showing = true
        defer { showing = false }
        NSApp.activate(ignoringOtherApps: true)
        let alert = makeAlert()
        alert.messageText = "Clear queue?"
        alert.informativeText = "Remove all \(count) queued focus\(count == 1 ? "" : "es")? This can't be undone."
        alert.addButton(withTitle: "Clear queue")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        if alert.runModal() == .alertFirstButtonReturn { db.clearQueue() }
    }

    // Loop through the deferred (unrated, completed) sessions oldest-first and
    // ask for a rating on each.
    @objc func rateUnrated() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        for s in db.unratedCompleted() {
            let label = "\(whenLabel(s.startedAt)) · \(s.focus) · \(s.minutes) min"
            let (rating, note) = promptRating(focus: label, title: "Rate session")
            db.setRating(id: s.id, rating: rating, note: note)
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
            case "min":    text = "\(q.minutes)"; align = .right
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
        case "when":    text = whenLabel(r.startedAt)
        case "min":     text = "\(r.minutes)"; align = .right
        case "rating":  text = r.rating.map { "\($0)/10" } ?? "—"; align = .right
        case "status":  text = r.status ?? (r.endedAt == nil ? "active" : "—")
        case "note":    text = r.note ?? ""
        default:        text = r.focus
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
                timeUp(focus: focus)
                return
            }
            hudLabel.stringValue = "🎯 \(focus)    \(mmss(remaining))"
            layoutHUD()
            hudWindow.orderFrontRegardless()
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

    /// The three preference checkboxes, initialized from the stored values. Shared
    /// by the session-start modal and the Settings dialog so they stay in sync.
    private func preferenceCheckboxes() -> (sound: NSButton, pushover: NSButton, auto: NSButton) {
        let sound = NSButton(checkboxWithTitle: "Play sound when time's up", target: nil, action: nil)
        sound.state = playSoundEnabled ? .on : .off
        let pushover = NSButton(checkboxWithTitle: "Send Pushover notification", target: nil, action: nil)
        pushover.state = pushoverEnabled ? .on : .off
        let auto = NSButton(checkboxWithTitle: "Auto-proceed with next queued task", target: nil, action: nil)
        auto.state = autoProceedEnabled ? .on : .off
        return (sound, pushover, auto)
    }

    private func persistPreferences(_ sound: NSButton, _ pushover: NSButton, _ auto: NSButton) {
        playSoundEnabled = sound.state == .on
        pushoverEnabled = pushover.state == .on
        autoProceedEnabled = auto.state == .on
    }

    // Standalone Settings dialog for the three global preferences.
    @objc func showSettings() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        NSApp.activate(ignoringOtherApps: true)

        let (sound, pushover, auto) = preferenceCheckboxes()
        sound.frame = NSRect(x: 0, y: 52, width: 320, height: 20)
        pushover.frame = NSRect(x: 0, y: 26, width: 320, height: 20)
        auto.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 72))
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

        persistPreferences(sound, pushover, auto)
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

        switch promptTimeUp(focus: focus, minutes: sessionMinutes ?? 0) {
        case .addTime(let extra):
            // Keep the SAME session going: log the addition, extend, resume.
            extendSession(by: extra)
            showing = false

        case .rate(let rating, let note):
            let endedId = sessionId
            currentFocus = nil
            deadline = nil
            sessionId = nil
            if let id = endedId { db.endSession(id: id, status: "completed", rating: rating, note: note) }
            // Roll straight into the next session: having rated, set a new focus.
            showing = false
            promptForFocus(reason: "after-session")
        }
    }

    private enum TimeUpChoice { case rate(rating: Int, note: String); case addTime(Int) }

    /// Time's-up modal: rate 1–10 (+ optional note) to finish, or add more time.
    private func promptTimeUp(focus: String, minutes: Int) -> TimeUpChoice {
        NSApp.activate(ignoringOtherApps: true)
        let (accessory, ratingField, noteField, elapsed) = ratingAccessory()
        let timer = startElapsedTimer(elapsed)
        defer { timer.invalidate() }
        while true {
            let alert = makeAlert()
            alert.messageText = "Time's up"
            alert.informativeText = "Focus: \(focus)\n\(minutes) min\n\nRate it 1–10 to finish (optional note), or add more time:"
            alert.addButton(withTitle: "Save")        // .alertFirstButtonReturn
            alert.addButton(withTitle: "Add time…")   // .alertSecondButtonReturn
            alert.accessoryView = accessory
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = ratingField
            let response = alert.runModal()

            if response == .alertSecondButtonReturn {
                if let extra = askMinutes() {
                    return .addTime(extra)
                }
                continue   // cancelled the add → back to the time's-up modal
            }
            let rating = Int(ratingField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if (1...10).contains(rating) {
                return .rate(rating: rating, note: noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            // invalid rating → loop
        }
    }

    /// "Add time" minutes prompt (cancellable). Returns minutes > 0, or nil if cancelled.
    private func askMinutes() -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = "5"
        while true {
            let alert = makeAlert()
            alert.messageText = "Add time"
            alert.informativeText = "How many more minutes?"
            alert.addButton(withTitle: "Add")       // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")    // .alertSecondButtonReturn
            alert.accessoryView = field
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = field
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return nil }
            if let m = Int(field.stringValue.trimmingCharacters(in: .whitespaces)), m > 0 { return m }
        }
    }

    /// Force a rating, then close the current session out as completed and clear
    /// its state. Caller must already hold `showing`.
    private func rateAndComplete() {
        guard let id = sessionId, let focus = currentFocus else { return }
        currentFocus = nil
        deadline = nil
        sessionId = nil
        sessionStart = nil
        sessionMinutes = nil
        sessionOriginalId = nil
        hudWindow.orderOut(nil)
        let (rating, note) = promptRating(focus: focus, title: "Rate this session")
        db.endSession(id: id, status: "completed", rating: rating, note: note)
    }

    /// A rating (1–10) field over an optional note field, for the rating modals.
    private func ratingAccessory() -> (view: NSView, rating: NSTextField, note: NSTextField, elapsed: NSTextField) {
        let ratingField = NSTextField(frame: NSRect(x: 0, y: 34, width: 80, height: 24))
        ratingField.placeholderString = "1–10"
        let noteField = NSTextField(frame: NSRect(x: 0, y: 2, width: 320, height: 24))
        noteField.placeholderString = "Note (optional)"
        let elapsed = NSTextField(labelWithString: "")
        elapsed.frame = NSRect(x: 0, y: 62, width: 320, height: 18)
        elapsed.font = NSFont.systemFont(ofSize: 11)
        elapsed.textColor = .secondaryLabelColor
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 84))
        view.addSubview(ratingField)
        view.addSubview(noteField)
        view.addSubview(elapsed)
        return (view, ratingField, noteField, elapsed)
    }

    /// A `.common`-mode timer that shows how long the modal has been open, so it
    /// keeps ticking while runModal blocks. Caller invalidates it.
    private func startElapsedTimer(_ label: NSTextField) -> Timer {
        let openedAt = Date()
        label.stringValue = "Open for 0:00"
        let timer = Timer(timeInterval: 1, repeats: true) { _ in
            label.stringValue = "Open for \(mmss(Int(Date().timeIntervalSince(openedAt))))"
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    /// Mandatory 1–10 rating modal (+ optional note) — floating, loops until valid.
    private func promptRating(focus: String, title: String) -> (rating: Int, note: String) {
        NSApp.activate(ignoringOtherApps: true)
        let (accessory, ratingField, noteField, elapsed) = ratingAccessory()
        let timer = startElapsedTimer(elapsed)
        defer { timer.invalidate() }
        var rating = 0
        while rating < 1 || rating > 10 {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = "Focus: \(focus)\n\nRate it 1–10 (optional note):"
            alert.addButton(withTitle: "Save")
            alert.accessoryView = accessory
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = ratingField
            alert.runModal()
            rating = Int(ratingField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return (rating, noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
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
        menu.addItem(withTitle: "Add to queue", action: #selector(addNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Complete task", action: #selector(completeTask), keyEquivalent: "")
        menu.addItem(withTitle: "Abort task", action: #selector(abortTask), keyEquivalent: "")
        menu.addItem(withTitle: "Add time to current", action: #selector(addTimeToCurrent), keyEquivalent: "")
        menu.addItem(withTitle: "Pre-empt task", action: #selector(changeFocus), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "See history", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(withTitle: "See queue", action: #selector(showQueue), keyEquivalent: "")
        menu.addItem(withTitle: "Clear queue", action: #selector(clearQueue), keyEquivalent: "")
        menu.addItem(withTitle: "Rate unrated sessions", action: #selector(rateUnrated), keyEquivalent: "")
        menu.addItem(.separator())
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
        hudWindow.ignoresMouseEvents = true            // click-through
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
        hudLabel.sizeToFit()
        let padX: CGFloat = 14, padY: CGFloat = 8
        let w = hudLabel.frame.width + padX * 2
        let h = hudLabel.frame.height + padY * 2
        hudLabel.setFrameOrigin(NSPoint(x: padX, y: padY))

        guard let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let x = vf.maxX - w - 16
        let y = vf.maxY - h - 12
        hudWindow.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // background app, no Dock icon; allows status item
let controller = AppController()
app.delegate = controller
app.run()
