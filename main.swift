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

func mmss(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

func isoNow() -> String { ISO8601DateFormatter().string(from: Date()) }

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
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate {
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

    func applicationDidFinishLaunching(_ note: Notification) {
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

        // Drive the countdown / HUD once a second.
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()

        // Launching at login IS a return.
        onReturn("launch")
    }

    // ---- return handling ----
    func onReturn(_ reason: String) {
        guard !showing else { return }
        guard Date().timeIntervalSince(lastFired) >= cooldown else { return }
        promptForFocus(reason: reason)
        lastFired = Date()          // stamp AFTER dismissal
    }

    @objc func changeFocus() { promptForFocus(reason: "manual") }

    private func promptForFocus(reason: String) {
        guard !showing else { return }
        showing = true
        defer { showing = false }

        // Changing focus while a session is running forces you to rate the
        // outgoing one first (same as clearing or letting the timer finish).
        rateAndEndCurrent(outcome: "superseded")

        NSApp.activate(ignoringOtherApps: true)

        let focusField = NSTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 24))
        focusField.placeholderString = "e.g. Ship the focus pill"
        focusField.stringValue = currentFocus ?? ""

        let minutesLabel = NSTextField(labelWithString: "Minutes:")
        minutesLabel.frame = NSRect(x: 0, y: 0, width: 60, height: 24)
        let minutesField = NSTextField(frame: NSRect(x: 62, y: 0, width: 70, height: 24))
        minutesField.stringValue = String(defaultMinutes)

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 62))
        accessory.addSubview(focusField)
        accessory.addSubview(minutesLabel)
        accessory.addSubview(minutesField)

        // Loop until a non-empty focus AND valid minutes — no escape, no Skip.
        var answer = ""
        var minutes = 0
        while answer.isEmpty || minutes <= 0 {
            let alert = NSAlert()
            alert.messageText = "Welcome back"
            alert.informativeText = "What's your one focus right now, and for how long?"
            alert.addButton(withTitle: "Start")
            alert.accessoryView = accessory
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = focusField
            alert.runModal()
            answer = focusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            minutes = Int(minutesField.stringValue.trimmingCharacters(in: .whitespaces)) ?? 0
        }

        currentFocus = answer
        deadline = Date().addingTimeInterval(Double(minutes) * 60)
        sessionId = db.startSession(reason: reason, minutes: minutes, focus: answer)
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

    private func timeUp(focus: String) {
        guard !showing else { return }   // a prompt is open; retry on the next tick
        showing = true
        defer { showing = false }

        let endedId = sessionId
        currentFocus = nil
        deadline = nil
        sessionId = nil
        hudWindow.orderOut(nil)

        let rating = promptRating(focus: focus, title: "Time's up")
        if let id = endedId { db.endSession(id: id, outcome: "completed", rating: rating) }
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
            let alert = NSAlert()
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
    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🎯"   // fixed icon; never changes, so it never relayouts
        let menu = NSMenu()
        menu.addItem(withTitle: "Change focus…", action: #selector(changeFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Clear focus", action: #selector(clearFocus), keyEquivalent: "")
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
