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
            outcome    TEXT           -- completed / cleared / superseded
        );
        """)
        // FIFO queue of upcoming sessions. Front = lowest id; "add to end" is a
        // plain insert; "pop off" deletes the lowest id.
        exec("""
        CREATE TABLE IF NOT EXISTS queue (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at TEXT NOT NULL,
            minutes    INTEGER,
            focus      TEXT
        );
        """)
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
    }

    private func exec(_ sql: String) { sqlite3_exec(db, sql, nil, nil, nil) }

    /// Insert a new in-progress session; returns its row id.
    func startSession(reason: String, minutes: Int, focus: String) -> Int64? {
        let sql = "INSERT INTO sessions (started_at, reason, minutes, focus) VALUES (?,?,?,?);"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, reason, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(minutes))
        sqlite3_bind_text(stmt, 4, focus, -1, SQLITE_TRANSIENT)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        return sqlite3_last_insert_rowid(db)
    }

    /// Close out a session with an outcome and (optionally) a rating.
    func endSession(id: Int64, outcome: String, rating: Int?) {
        let sql = "UPDATE sessions SET ended_at=?, outcome=?, rating=? WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, isoNow(), -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, outcome, -1, SQLITE_TRANSIENT)
        if let r = rating { sqlite3_bind_int(stmt, 3, Int32(r)) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_int64(stmt, 4, id)
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

    /// Sessions never closed out (ended_at IS NULL), newest first — i.e. a
    /// session that was live when the process died (uninstall/crash/reboot).
    func openSessions() -> [ActiveSession] {
        let sql = "SELECT id, started_at, minutes, focus FROM sessions WHERE ended_at IS NULL ORDER BY id DESC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [ActiveSession] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? ""
            rows.append(ActiveSession(id: sqlite3_column_int64(stmt, 0),
                                      startedAt: sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? "",
                                      minutes: Int(sqlite3_column_int(stmt, 2)),
                                      focus: focus))
        }
        return rows
    }

    /// Most recent sessions, newest first, for the history window.
    func recent(limit: Int = 500) -> [SessionRow] {
        let sql = """
        SELECT started_at, ended_at, minutes, focus, rating, outcome
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
                outcome: text(5)))
        }
        return rows
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
        let sql = "SELECT id, minutes, focus FROM queue ORDER BY id ASC;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var rows: [QueueItem] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
            rows.append(QueueItem(id: sqlite3_column_int64(stmt, 0),
                                  minutes: Int(sqlite3_column_int(stmt, 1)),
                                  focus: focus))
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

    /// The next queued focus (front of the FIFO), or nil if the queue is empty.
    func frontOfQueue() -> QueueItem? {
        let sql = "SELECT id, minutes, focus FROM queue ORDER BY id ASC LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let focus = sqlite3_column_text(stmt, 2).map { String(cString: $0) } ?? ""
        return QueueItem(id: sqlite3_column_int64(stmt, 0),
                         minutes: Int(sqlite3_column_int(stmt, 1)),
                         focus: focus)
    }

    func removeFromQueue(id: Int64) {
        let sql = "DELETE FROM queue WHERE id=?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        sqlite3_step(stmt)
    }
}

struct QueueItem {
    let id: Int64
    let minutes: Int
    let focus: String
}

struct ActiveSession {
    let id: Int64
    let startedAt: String
    let minutes: Int
    let focus: String
}

struct SessionRow {
    let startedAt: String
    let endedAt: String?
    let minutes: Int
    let focus: String
    let rating: Int?
    let outcome: String?
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSTableViewDataSource,
                           NSTableViewDelegate, NSMenuItemValidation {
    private let db = DB()

    // ---- session state ----
    private var currentFocus: String?
    private var deadline: Date?
    private var sessionId: Int64?

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
            db.endSession(id: stale.id, outcome: "interrupted", rating: nil)
        }

        guard let candidate = open.first,
              let start = isoParser.date(from: candidate.startedAt) else {
            // Nothing (or unparseable) to resume — clean up and prompt normally.
            if let c = open.first { db.endSession(id: c.id, outcome: "interrupted", rating: nil) }
            onReturn("launch")
            return
        }

        let deadline = start.addingTimeInterval(Double(candidate.minutes) * 60)
        if deadline > Date() {
            offerResume(candidate, deadline: deadline)     // still time left
        } else {
            // Expired while away → treat as finished: adopt it and let tick()'s
            // timeUp run the mandatory rating (outcome 'completed').
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
            db.endSession(id: s.id, outcome: "interrupted", rating: nil)
            onReturn("launch")
        }
    }

    /// Reload an existing (still-open) session row into memory — same row keeps
    /// getting written, so history stays one row / one rating.
    private func adopt(_ s: ActiveSession, deadline: Date) {
        currentFocus = s.focus
        self.deadline = deadline
        sessionId = s.id
    }

    // "Set focus" is an explicit ad-hoc entry — it bypasses the queue.
    @objc func changeFocus() { promptForFocus(reason: "manual", useQueue: false) }

    // "Next focus" jumps to the next queued item (disabled when the queue is empty).
    @objc func nextFocus() {
        guard !showing, db.frontOfQueue() != nil else { return }
        showing = true
        defer { showing = false }
        rateAndEndCurrent(outcome: "superseded")   // rate the current one first
        NSApp.activate(ignoringOtherApps: true)
        if let next = db.frontOfQueue() { confirmQueued(next) }
    }

    // Grey out "Next focus" when the queue is empty; relabel "Set focus" to make
    // clear it aborts a running session.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(nextFocus) {
            return db.frontOfQueue() != nil
        }
        if menuItem.action == #selector(changeFocus) {
            menuItem.title = currentFocus != nil ? "Abort and set focus" : "Set focus"
        }
        if menuItem.action == #selector(addNextFocus) {
            menuItem.title = "Add to queue (\(db.queueCount()))"
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

    private func promptForFocus(reason: String, useQueue: Bool = true) {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        // Changing focus while a session is running forces you to rate the
        // outgoing one first (same as clearing or letting the timer finish).
        rateAndEndCurrent(outcome: "superseded")

        NSApp.activate(ignoringOtherApps: true)

        // Auto-starts (return / after-session) use a queued focus if present;
        // "Set focus" passes useQueue:false to force an ad-hoc editable entry.
        if useQueue, let next = db.frontOfQueue() {
            confirmQueued(next)
            return
        }

        guard let (answer, minutes) = askFocusAndMinutes(
            title: "Welcome back",
            info: "What's your one focus right now, and for how long?",
            confirm: "Start", cancellable: false) else { return }
        beginSession(reason: reason, minutes: minutes, focus: answer)
    }

    /// Non-editable confirmation for the next queued focus. Pops it off and starts.
    private func confirmQueued(_ item: QueueItem) {
        let alert = makeAlert()
        alert.messageText = "Next focus"
        alert.informativeText = "\(item.focus)\n\n\(item.minutes) minutes"
        alert.addButton(withTitle: "Start")                  // .alertFirstButtonReturn
        alert.addButton(withTitle: "Pre-empt with another…") // .alertSecondButtonReturn
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()

        if response == .alertSecondButtonReturn {
            // Pre-empt: leave the queued item where it is (still the front, since
            // we never removed it) and run an ad-hoc focus right now instead.
            if let (focus, minutes) = askFocusAndMinutes(
                title: "Pre-empt with a new focus",
                info: "This runs now; the queued focus stays next in line.",
                confirm: "Start", cancellable: true) {
                beginSession(reason: "preempt", minutes: minutes, focus: focus)
                return
            }
            // Cancelled the pre-empt → fall through and start the queued one.
        }

        db.removeFromQueue(id: item.id)
        beginSession(reason: "queue", minutes: item.minutes, focus: item.focus)
    }

    /// Editable "focus + minutes" modal. Loops until valid; returns nil only if
    /// `cancellable` and the user cancels.
    private func askFocusAndMinutes(title: String, info: String, confirm: String,
                                    cancellable: Bool) -> (String, Int)? {
        NSApp.activate(ignoringOtherApps: true)

        let focusField = NSTextField(frame: NSRect(x: 0, y: 88, width: 320, height: 24))
        focusField.placeholderString = "e.g. Ship the focus pill"

        let minutesLabel = NSTextField(labelWithString: "Minutes:")
        minutesLabel.frame = NSRect(x: 0, y: 56, width: 60, height: 24)
        let minutesField = NSTextField(frame: NSRect(x: 62, y: 56, width: 70, height: 24))
        minutesField.stringValue = String(defaultMinutes)

        let soundCheck = NSButton(checkboxWithTitle: "Play sound when time's up",
                                  target: nil, action: nil)
        soundCheck.frame = NSRect(x: 0, y: 28, width: 320, height: 20)
        soundCheck.state = playSoundEnabled ? .on : .off

        let pushoverCheck = NSButton(checkboxWithTitle: "Send Pushover notification",
                                     target: nil, action: nil)
        pushoverCheck.frame = NSRect(x: 0, y: 2, width: 320, height: 20)
        pushoverCheck.state = pushoverEnabled ? .on : .off

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 112))
        accessory.addSubview(focusField)
        accessory.addSubview(minutesLabel)
        accessory.addSubview(minutesField)
        accessory.addSubview(soundCheck)
        accessory.addSubview(pushoverCheck)

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
            playSoundEnabled = soundCheck.state == .on
            pushoverEnabled = pushoverCheck.state == .on

            let answer = focusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let minutes = Int(minutesField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if !answer.isEmpty && minutes > 0 { return (answer, minutes) }
            // otherwise invalid: loop and ask again
        }
    }

    private func beginSession(reason: String, minutes: Int, focus: String) {
        currentFocus = focus
        deadline = Date().addingTimeInterval(Double(minutes) * 60)
        sessionId = db.startSession(reason: reason, minutes: minutes, focus: focus)
        tick()
    }

    @objc func clearFocus() {
        guard !showing else { return }
        if sessionId != nil {
            showing = true
            rateAndEndCurrent(outcome: "cleared")   // must rate before clearing
            showing = false
        } else {
            currentFocus = nil
            deadline = nil
        }
        tick()
    }

    // ---- history ----
    @objc func showHistory() {
        historyRows = db.recent()

        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 680, height: 460),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Focus history"
            window.isReleasedWhenClosed = false   // we keep & reuse it
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
            table.allowsColumnResizing = true
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
            addColumn("when", "Started", width: 140, min: 120)
            addColumn("min", "Min", width: 48, min: 40, align: .right)
            addColumn("rating", "Rating", width: 60, min: 50, align: .right)
            addColumn("outcome", "Outcome", width: 95, min: 70)
            addColumn("focus", "Focus", width: 300, min: 150)   // flexible last column

            scroll.documentView = table
            window.contentView = scroll

            historyWindow = window
            historyTable = table
        }

        historyTable?.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showQueue() {
        queueRows = db.queueItems()

        if queueWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 360),
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
            addColumn("focus", "Focus (next up first)", width: 320, min: 150)

            scroll.documentView = table
            window.contentView = scroll

            queueWindow = window
            queueTable = table
        }

        queueTable?.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        queueWindow?.makeKeyAndOrderFront(nil)
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
            switch id {
            case "pos": text = "\(row + 1)"; align = .right
            case "min": text = "\(q.minutes)"; align = .right
            default:    text = q.focus
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
        case "outcome": text = r.outcome ?? (r.endedAt == nil ? "active" : "—")
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

        switch promptTimeUp(focus: focus) {
        case .addTime(let extra):
            // Keep the SAME session going: log the addition, extend, resume.
            if let id = sessionId { db.addTime(sessionId: id, minutes: extra) }
            deadline = Date().addingTimeInterval(Double(extra) * 60)
            showing = false
            tick()

        case .rate(let rating):
            let endedId = sessionId
            currentFocus = nil
            deadline = nil
            sessionId = nil
            if let id = endedId { db.endSession(id: id, outcome: "completed", rating: rating) }
            // Roll straight into the next session: having rated, set a new focus.
            showing = false
            promptForFocus(reason: "after-session")
        }
    }

    private enum TimeUpChoice { case rate(Int); case addTime(Int) }

    /// Time's-up modal: rate 1–10 to finish, or add more time to keep going.
    private func promptTimeUp(focus: String) -> TimeUpChoice {
        NSApp.activate(ignoringOtherApps: true)
        let ratingField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        ratingField.placeholderString = "1–10"
        while true {
            let alert = makeAlert()
            alert.messageText = "Time's up"
            alert.informativeText = "Focus: \(focus)\n\nRate it 1–10 to finish, or add more time:"
            alert.addButton(withTitle: "Save")        // .alertFirstButtonReturn
            alert.addButton(withTitle: "Add time…")   // .alertSecondButtonReturn
            alert.accessoryView = ratingField
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = ratingField
            let response = alert.runModal()

            if response == .alertSecondButtonReturn {
                if let extra = askMinutes(title: "Add time", info: "How many more minutes?", prefill: 5) {
                    return .addTime(extra)
                }
                continue   // cancelled the add → back to the time's-up modal
            }
            let rating = Int(ratingField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
            if (1...10).contains(rating) { return .rate(rating) }
            // invalid rating → loop
        }
    }

    /// Small numeric prompt (cancellable). Returns minutes > 0, or nil if cancelled.
    private func askMinutes(title: String, info: String, prefill: Int) -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        field.stringValue = String(prefill)
        while true {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = info
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

    /// If a session is active, force a rating then close it out with `outcome`
    /// and clear all session state. Caller must already hold `showing`.
    private func rateAndEndCurrent(outcome: String) {
        guard let id = sessionId, let focus = currentFocus else { return }
        currentFocus = nil
        deadline = nil
        sessionId = nil
        hudWindow.orderOut(nil)
        let rating = promptRating(focus: focus, title: "Rate this session")
        db.endSession(id: id, outcome: outcome, rating: rating)
    }

    /// Mandatory 1–10 rating modal — floating, no escape, loops until valid.
    private func promptRating(focus: String, title: String) -> Int {
        NSApp.activate(ignoringOtherApps: true)
        let ratingField = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 24))
        ratingField.placeholderString = "1–10"
        var rating = 0
        while rating < 1 || rating > 10 {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = "Focus: \(focus)\n\nHow did this session go? Rate it 1–10:"
            alert.addButton(withTitle: "Save")
            alert.accessoryView = ratingField
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = ratingField
            alert.runModal()
            rating = Int(ratingField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return rating
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
        menu.addItem(withTitle: "Set focus", action: #selector(changeFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Next focus", action: #selector(nextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Add to queue", action: #selector(addNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Clear focus", action: #selector(clearFocus), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "See history", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(withTitle: "See queue", action: #selector(showQueue), keyEquivalent: "")
        menu.addItem(.separator())
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
