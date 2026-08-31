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
    private var taskId: Int64?         // the current task
    private var intervalId: Int64?     // its current OPEN interval (the chunk underway)
    private var intervalStart: Date?   // when the current interval began (for elapsed time)
    private var estimateSeconds: Int?  // the task's estimate (for the pill's "/ total")
    private var spentBefore: Int?      // seconds spent on this task in PRIOR closed intervals
    private var pausedAt: Date?        // start of the current pause (nil = running) — freezes the WHOLE stack

    // Subtasks: the leaf task lives in the vars above; its ancestors (parent, grand-
    // parent, … root) keep ticking concurrently and live here, root first. A subtask
    // pushes the current leaf onto this stack; finishing a subtask pops back to it.
    private struct Frame {
        let taskId: Int64
        let intervalId: Int64
        let intervalStart: Date
        let estimateSeconds: Int
        let spentBefore: Int
        var deadline: Date            // var: shifts on pause/resume
        let focus: String
    }
    private var ancestors: [Frame] = []

    /// Clear all live task/interval state, including the ancestor stack (back to idle).
    private func clearSessionState() {
        currentFocus = nil; deadline = nil; taskId = nil; intervalId = nil
        intervalStart = nil; estimateSeconds = nil; spentBefore = nil; pausedAt = nil
        ancestors.removeAll()
    }

    /// Snapshot the current leaf as a Frame (for pushing when starting a subtask).
    private func leafFrame() -> Frame? {
        guard let tid = taskId, let iid = intervalId, let start = intervalStart,
              let est = estimateSeconds, let dl = deadline, let f = currentFocus else { return nil }
        return Frame(taskId: tid, intervalId: iid, intervalStart: start,
                     estimateSeconds: est, spentBefore: spentBefore ?? 0, deadline: dl, focus: f)
    }

    /// Load a Frame into the leaf vars.
    private func setLeaf(_ f: Frame) {
        taskId = f.taskId; intervalId = f.intervalId; intervalStart = f.intervalStart
        estimateSeconds = f.estimateSeconds; spentBefore = f.spentBefore
        deadline = f.deadline; currentFocus = f.focus
    }

    /// Pop the nearest ancestor back into the leaf vars. Returns false if none.
    @discardableResult
    private func popAncestorToLeaf() -> Bool {
        guard let parent = ancestors.popLast() else { return false }
        setLeaf(parent)
        return true
    }

    /// Keep every ancestor's remaining ≥ the leaf's, extending (working estimate only)
    /// any that fall short — so no ancestor overtimes while a descendant still runs.
    /// Called after the leaf's countdown grows (new subtask, or Add time). Cascades up
    /// the whole chain, so deeper nesting stays consistent too.
    private func extendAncestorsToCoverLeaf() {
        let leafRemaining = remainingSeconds()          // frozen if paused
        guard leafRemaining > 0 else { return }
        let ref = pausedAt ?? Date()
        for i in ancestors.indices {
            let anRemaining = Int(ancestors[i].deadline.timeIntervalSince(ref).rounded())
            if anRemaining < leafRemaining {
                let extra = leafRemaining - anRemaining
                db.addTimeToTask(id: ancestors[i].taskId, seconds: extra)   // working estimate only
                ancestors[i].deadline = ancestors[i].deadline.addingTimeInterval(Double(extra))
            }
        }
    }

    /// Suspend the whole active stack: close every level's interval and re-queue the
    /// LEAF (carrying its parent link) to the front, then clear all state. Resuming
    /// the queued leaf rebuilds the stack via the parent_task_id walk.
    private func suspendStack() {
        guard let tid = taskId, let iid = intervalId, let focus = currentFocus else { return }
        let remaining = max(1, remainingSeconds())
        let elapsed = elapsedFocusSeconds()
        finalizePause()
        db.endInterval(id: iid, elapsedSeconds: elapsed)
        let now = Date()
        for f in ancestors {
            db.closeOpenPause(sessionId: f.intervalId)
            let anElapsed = max(0, Int(now.timeIntervalSince(f.intervalStart).rounded()) - db.totalPausedSeconds(sessionId: f.intervalId))
            db.endInterval(id: f.intervalId, elapsedSeconds: anElapsed)
        }
        db.enqueueTask(focus: focus, estimateSeconds: remaining, taskId: tid, front: true)
        clearSessionState()
    }

    /// Suspend just the current subtask (leaf): close its interval, re-queue it
    /// (carrying its parent link), then pop to the parent, which keeps ticking.
    /// Returns false if there's no parent (top-level) — caller uses suspendStack then.
    @discardableResult
    private func suspendLeaf() -> Bool {
        guard !ancestors.isEmpty, let tid = taskId, let iid = intervalId, let focus = currentFocus else { return false }
        let remaining = max(1, remainingSeconds())
        let elapsed = elapsedFocusSeconds()
        finalizePause()
        db.endInterval(id: iid, elapsedSeconds: elapsed)
        db.enqueueTask(focus: focus, estimateSeconds: remaining, taskId: tid, front: true)
        popAncestorToLeaf()          // parent becomes the leaf and keeps ticking
        return true
    }

    /// Push the current leaf as an ancestor and start `focus` as a subtask under it —
    /// fresh (resumeId nil) or resuming a set-aside subtask (resumeId set; attach under
    /// the already-live parent instead of rebuilding it).
    private func startSubtaskUnderLeaf(reason: String, seconds: Int, focus: String,
                                       resumeId: Int64?, openStart: Int?) {
        guard let parentId = taskId, let frame = leafFrame() else { return }
        ancestors.append(frame)
        if let rid = resumeId {
            beginSession(reason: reason, seconds: seconds, focus: focus,
                         resumeTaskId: rid, rebuildAncestors: false, openSecondsStart: openStart)
        } else {
            beginSession(reason: reason, seconds: seconds, focus: focus,
                         parentTaskId: parentId, openSecondsStart: openStart)
        }
        extendAncestorsToCoverLeaf()   // keep the parent covering the new subtask
    }

    /// Wall-time of an interval row from its start to now — for closing orphan/
    /// abandoned intervals during restart.
    private func intervalElapsed(_ iv: Interval) -> Int {
        guard let start = isoParser.date(from: iv.startedAt) else { return iv.seconds }
        return max(0, Int(Date().timeIntervalSince(start).rounded()))
    }

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
    private var historyRows: [TaskHistoryRow] = []
    private var intervalRows: [IntervalHistoryRow] = []
    private enum HistoryMode { case tasks, intervals }
    private var historyMode: HistoryMode = .tasks
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
        let open = db.openIntervals()   // newest first

        guard let leafIv = open.first, let leafTask = db.task(id: leafIv.taskId),
              isoParser.date(from: leafIv.startedAt) != nil else {
            // Nothing valid to resume — sweep any strays and prompt normally.
            for iv in open { db.endInterval(id: iv.id, elapsedSeconds: intervalElapsed(iv)) }
            onReturn("launch")
            return
        }

        // The active stack = the leaf plus its ancestors (walk parent_task_id up);
        // each level has its own open interval. Anything open outside the chain is an
        // orphan from a past death → sweep it.
        let chain = [leafTask] + db.ancestorTasks(of: leafTask.id)   // [leaf, parent, … root]
        let chainIds = Set(chain.map { $0.id })
        var openByTask: [Int64: Interval] = [:]
        for iv in open where openByTask[iv.taskId] == nil { openByTask[iv.taskId] = iv }
        for iv in open where !chainIds.contains(iv.taskId) {
            db.endInterval(id: iv.id, elapsedSeconds: intervalElapsed(iv))
        }

        // Reconstruct a running frame for a task: close any open pause (downtime counts
        // as pause) and rebuild the deadline from estimate − prior-spent (+ paused).
        func frame(for task: TaskRow) -> Frame? {
            guard let iv = openByTask[task.id], let start = isoParser.date(from: iv.startedAt) else { return nil }
            db.closeOpenPause(sessionId: iv.id)
            let paused = db.totalPausedSeconds(sessionId: iv.id)
            let spent = db.spentSeconds(taskId: task.id)
            let dl = start.addingTimeInterval(Double((task.estimateSeconds ?? 0) - spent + paused))
            return Frame(taskId: task.id, intervalId: iv.id, intervalStart: start,
                         estimateSeconds: task.estimateSeconds ?? 0, spentBefore: spent, deadline: dl, focus: task.focus)
        }
        guard let leaf = frame(for: leafTask) else {
            db.endInterval(id: leafIv.id, elapsedSeconds: intervalElapsed(leafIv)); onReturn("launch"); return
        }
        // ancestors want root … parent (chain is leaf-first, so drop leaf and reverse).
        ancestors = chain.dropFirst().reversed().compactMap { frame(for: $0) }

        if ancestors.isEmpty {
            // Single task — keep the familiar Resume / Switch / Start-fresh prompt.
            // (Don't pre-set the leaf: adopt does that, and Start-fresh needs
            // currentFocus to stay nil so onReturn prompts.)
            if leaf.deadline > Date() {
                offerResume(task: leafTask, interval: leafIv, deadline: leaf.deadline)
            } else {
                adopt(task: leafTask, interval: leafIv, deadline: leaf.deadline)
                tick()
            }
        } else {
            // A subtask stack was live — auto-adopt the whole stack (no resume prompt).
            setLeaf(leaf)
            pausedAt = nil
            tick()
        }
    }

    private func offerResume(task: TaskRow, interval iv: Interval, deadline: Date) {
        NSApp.activate(ignoringOtherApps: true)
        showing = true
        let remaining = Int(deadline.timeIntervalSinceNow.rounded())
        let alert = makeAlert()
        alert.messageText = "Resume focus?"
        alert.informativeText = "\(task.focus)\n\n\(mmss(remaining)) remaining (of \(mmss(task.estimateSeconds ?? remaining)))"
        alert.addButton(withTitle: "Resume")            // .alertFirstButtonReturn
        alert.addButton(withTitle: "Switch focus…")     // .alertSecondButtonReturn
        alert.addButton(withTitle: "Start fresh…")      // .alertThirdButtonReturn
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let response = alert.runModal()
        showing = false

        switch response {
        case .alertFirstButtonReturn:            // Resume — continue where it left off
            adopt(task: task, interval: iv, deadline: deadline)
            tick()

        case .alertSecondButtonReturn:           // Switch — adopt it, then run the
            adopt(task: task, interval: iv, deadline: deadline)   // standard pre-empt flow
            tick()                                                // (re-queues remaining, starts new)
            changeFocus()

        default:                                 // Start fresh — abandon it, optionally
            showing = true                       // clear the queue, then start anew.
            let hasQueue = db.queueCount() > 0
            let clear = hasQueue ? confirmClearQueue() : false
            showing = false
            if hasQueue && !clear {
                offerResume(task: task, interval: iv, deadline: deadline)   // declined → back to the choice
                return
            }
            if clear { db.clearQueue() }
            db.endInterval(id: iv.id, elapsedSeconds: intervalElapsed(iv))
            db.finishTask(id: task.id, status: "interrupted")
            onReturn("launch")
        }
    }

    /// Reload a task and its still-open interval into memory — the same interval
    /// keeps getting written, and the countdown resumes at the task's remaining.
    private func adopt(task: TaskRow, interval iv: Interval, deadline: Date) {
        currentFocus = task.focus
        self.deadline = deadline
        taskId = task.id
        intervalId = iv.id
        intervalStart = isoParser.date(from: iv.startedAt) ?? Date()
        estimateSeconds = task.estimateSeconds
        spentBefore = db.spentSeconds(taskId: task.id)
        pausedAt = nil                       // resumes running (any open pause was closed)
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

        let preempting = taskId != nil
        let nested = preempting && !ancestors.isEmpty
        let parentId = ancestors.last?.taskId          // the immediate parent (for subtask mode)
        let title = preempting ? "Switch to a new focus" : "Set focus"
        let info = preempting
            ? "This runs now; the current focus goes to the front of the queue. Or pick one from the queue."
            : "What's your one focus right now, and for how long?"

        // When nested, offer to switch just this subtask (keeping the parent running)
        // vs. the whole task. Default: just this subtask.
        var subtaskBox: NSButton? = nil
        if nested {
            let cb = NSButton(checkboxWithTitle: "Switch just this subtask (keep the parent running)", target: nil, action: nil)
            cb.state = .on
            cb.frame = NSRect(x: 0, y: 0, width: 320, height: 20)
            subtaskBox = cb
        }

        // Pre-empt is voluntary → cancellable (cancel leaves the current session
        // untouched) and can pull from the queue. Idle "Set focus" stays mandatory.
        let newFocus: String
        let newSeconds: Int
        var newOpenStart: Int? = nil
        var resumeId: Int64? = nil
        let entry = askFocusAndMinutes(title: title, info: info, confirm: "Start",
                                       cancellable: preempting, queuePick: preempting, extraTop: subtaskBox)
        let subtaskMode = nested && (subtaskBox?.state == .on)   // read AFTER the modal
        switch entry {
        case .cancelled:
            return
        case .entered(let f, let s, let o):
            newFocus = f; newSeconds = s; newOpenStart = o          // fresh task
        case .queuePick:
            // In subtask mode the picker only offers set-aside subtasks of this parent.
            let picked = subtaskMode
                ? pickFromQueue(filter: { $0.taskId.flatMap { self.db.task(id: $0)?.parentTaskId } == parentId })
                : pickFromQueue()
            guard let item = picked else { return }
            db.removeFromQueue(id: item.id)
            newFocus = item.focus; newSeconds = item.seconds; resumeId = item.taskId
        }

        let preemptedInterval = intervalId
        if subtaskMode {
            // Suspend just this subtask (drops to the still-ticking parent), then run
            // the new sibling subtask under that parent.
            suspendLeaf()
            startSubtaskUnderLeaf(reason: "preempt", seconds: newSeconds, focus: newFocus,
                                  resumeId: resumeId, openStart: newOpenStart)
        } else {
            if preempting { suspendStack() }   // suspend the whole stack
            beginSession(reason: preempting ? "preempt" : "manual", seconds: newSeconds, focus: newFocus,
                         resumeTaskId: resumeId, openSecondsStart: newOpenStart)
        }
        if preempting { db.recordPreempt(preemptedSessionId: preemptedInterval, newSessionId: intervalId) }
    }

    // Insert a new focus at the FRONT of the queue — it jumps ahead of whatever
    // was queued next, without disturbing the running session. Records a pre-empt
    // (both ids NULL: nothing interrupted, nothing started yet — just a queue jump).
    @objc func preemptNextFocus() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        guard case let .entered(focus, seconds, _) = askFocusAndMinutes(
            title: "Add to front",
            info: "This goes to the front of the queue — it runs before whatever's queued next.",
            confirm: "Add to front", cancellable: true) else { return }
        db.enqueueTask(focus: focus, estimateSeconds: seconds, front: true)
        db.recordPreempt(preemptedSessionId: nil, newSessionId: nil)
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
        guard !showing, taskId != nil else { return }
        showing = true
        defer { showing = false }
        if let extra = askMinutes() { extendSession(by: extra); extendAncestorsToCoverLeaf() }
    }

    // Rename the running task's focus (a small prompt pre-filled with the current name).
    @objc func renameTask() {
        guard !showing, let id = taskId, let current = currentFocus else { return }
        showing = true
        defer { showing = false }
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = current
        let alert = makeAlert()
        alert.messageText = "Rename task"
        alert.informativeText = "Rename the current focus."
        alert.addButton(withTitle: "Save")     // index 0
        alert.addButton(withTitle: "Cancel")   // index 1
        alert.accessoryView = field
        guard runFloatingAlert(alert, firstResponder: field) == 0 else { return }
        let newName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !newName.isEmpty, newName != current {
            currentFocus = newName
            db.renameTask(id: id, focus: newName)
            tick()   // repaint the pill
        }
    }

    // ---- pause / resume ----
    @objc func togglePause() {
        guard !showing, let id = intervalId else { return }
        if let p = pausedAt {
            // Resume: shift every level's deadline forward by the pause (remaining is
            // preserved) and close each level's pause record. The whole stack resumes.
            let paused = max(0, Int(Date().timeIntervalSince(p).rounded()))
            deadline = deadline?.addingTimeInterval(Double(paused))
            db.endPause(sessionId: id, seconds: paused)
            for i in ancestors.indices {
                ancestors[i].deadline = ancestors[i].deadline.addingTimeInterval(Double(paused))
                db.endPause(sessionId: ancestors[i].intervalId, seconds: paused)
            }
            pausedAt = nil
        } else {
            // Pause: freeze the whole stack. tick() stops all countdowns while paused.
            pausedAt = Date()
            db.startPause(sessionId: id, at: pausedAt!)
            for f in ancestors { db.startPause(sessionId: f.intervalId, at: pausedAt!) }
        }
        tick()   // repaint the pill (running ⇄ paused)
    }

    /// Actual focus time in the CURRENT interval so far = wall-clock since the
    /// interval began, minus its pause time (closed pauses + any open pause).
    private func elapsedFocusSeconds() -> Int {
        guard let start = intervalStart else { return 0 }
        var paused = intervalId.map { db.totalPausedSeconds(sessionId: $0) } ?? 0
        if let p = pausedAt { paused += Int(Date().timeIntervalSince(p).rounded()) }
        return max(0, Int(Date().timeIntervalSince(start).rounded()) - paused)
    }

    /// Remaining time — the frozen value while paused, else deadline − now.
    private func remainingSeconds() -> Int {
        guard let dl = deadline else { return 0 }
        return Int(dl.timeIntervalSince(pausedAt ?? Date()).rounded())
    }

    /// Close any open pause when a session ends, so the record isn't left dangling.
    private func finalizePause() {
        guard let id = intervalId, let p = pausedAt else { return }
        db.endPause(sessionId: id, seconds: max(0, Int(Date().timeIntervalSince(p).rounded())))
        pausedAt = nil
    }

    /// Log an "Add time" event, bump the planned total, and shift the deadline.
    /// Adjusts from whichever is later — now or the current deadline — so it applies
    /// the full `extra` when the timer's already up, or on top of remaining time.
    /// `extra` may be negative to subtract time (the deadline moves earlier).
    private func extendSession(by extra: Int) {
        guard let tid = taskId else { return }
        db.addTimeToTask(id: tid, seconds: extra)
        estimateSeconds = (estimateSeconds ?? 0) + extra
        if pausedAt != nil {
            // Paused: extend the frozen deadline directly (the timer isn't "up").
            deadline = (deadline ?? Date()).addingTimeInterval(Double(extra))
        } else {
            let base = max(Date(), deadline ?? Date())
            deadline = base.addingTimeInterval(Double(extra))
        }
        tick()
    }

    // Finish the current task: mark completed, rate it, then advance — back to the
    // parent subtask (if any) or on to the next focus.
    @objc func completeTask() {
        guard !showing, taskId != nil else { return }
        showing = true
        let hadParent = rateAndComplete()   // rate + end as completed; pops to parent if a subtask
        showing = false
        if hadParent { tick() } else { promptForFocus(reason: "after-session") }
    }

    // Abort the current task: rate it, mark interrupted (recording elapsed),
    // then advance to the next (queued or improvised).
    @objc func abortTask() {
        guard !showing, let tid = taskId, let iid = intervalId, let focus = currentFocus else { return }
        showing = true
        let elapsed = elapsedFocusSeconds()   // excludes pause time
        finalizePause()
        // Return to the parent now (it keeps ticking, shown behind the rating); if
        // there's no parent, clear the leaf so the pill hides during the prompt.
        let hadParent = popAncestorToLeaf()
        if !hadParent { clearSessionState() }
        hudWindow.orderOut(nil)
        let (rating, note, openSeconds, applyTime) = promptRating(focus: "\(focus) · \(mmss(elapsed))", title: "Rate this session")
        db.endInterval(id: iid, elapsedSeconds: elapsed, openSecondsEnd: applyTime ? nil : openSeconds)
        if applyTime { db.addToInterval(id: iid, seconds: openSeconds) }
        db.finishTask(id: tid, status: "interrupted", rating: rating, note: note)
        showing = false
        if hadParent { tick() } else { promptForFocus(reason: "after-session") }
    }

    // Stop working on the current task without finishing it: suspend it (re-queued to
    // the front so it's resumable) and go idle — or, for a subtask, drop to the
    // still-ticking parent. No rating (it isn't done), unlike Abort.
    @objc func stopWorking() {
        guard !showing, taskId != nil else { return }
        showing = true
        defer { showing = false }
        let (proceed, subtaskOnly) = promptStopScope()
        guard proceed else { return }
        if subtaskOnly { suspendLeaf() } else { suspendStack() }
        tick()   // subtask → shows the parent; whole task → hides the pill (idle)
    }

    /// Confirm "Stop working?" — when nested, a checkbox picks "just this subtask"
    /// (drop to the parent) vs the whole task (go idle). Returns (proceed, subtaskOnly).
    private func promptStopScope() -> (proceed: Bool, subtaskOnly: Bool) {
        let nested = !ancestors.isEmpty
        let alert = makeAlert()
        alert.messageText = "Stop working?"
        alert.informativeText = nested
            ? "It goes to the front of the queue so you can resume it later."
            : "\(currentFocus ?? "This task") goes to the front of the queue so you can resume it later."
        var box: NSButton? = nil
        if nested {
            let cb = NSButton(checkboxWithTitle: "Just this subtask (keep the parent running)", target: nil, action: nil)
            cb.state = .on
            cb.sizeToFit()
            alert.accessoryView = cb
            box = cb
        }
        alert.addButton(withTitle: "Stop")     // index 0
        alert.addButton(withTitle: "Cancel")   // index 1
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return (runFloatingAlert(alert) == 0, box?.state == .on)
    }

    // Menu actions that are guarded by `showing` (they open their own prompt), so
    // they do nothing while another prompt is already up — disabled in that case.
    private static let showingBlockedActions: Set<Selector> = [
        #selector(addNextFocus), #selector(completeTask), #selector(abortTask),
        #selector(addTimeToCurrent), #selector(changeFocus), #selector(addSubtask),
        #selector(stopWorking), #selector(renameTask), #selector(togglePause), #selector(preemptNextFocus),
        #selector(clearQueue), #selector(rateUnrated), #selector(showSettings),
        #selector(deleteHistoryItems), #selector(abandonHistoryTask),
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // While a prompt is open, actions that would spawn another prompt are guarded
        // by `showing` and would silently no-op — disable them so the menu shows that.
        // (See history / See queue / Show current task / Quit still work.)
        if showing, let action = menuItem.action, Self.showingBlockedActions.contains(action) {
            return false
        }
        // Complete / Abort / Stop / Rename / Add time / Add subtask act on a running session.
        if menuItem.action == #selector(completeTask) || menuItem.action == #selector(abortTask)
            || menuItem.action == #selector(addTimeToCurrent) || menuItem.action == #selector(addSubtask)
            || menuItem.action == #selector(stopWorking) || menuItem.action == #selector(renameTask) {
            return currentFocus != nil
        }
        if menuItem.action == #selector(togglePause) {
            menuItem.title = pausedAt != nil ? "Resume" : "Pause"
            return currentFocus != nil
        }
        if menuItem.action == #selector(deleteHistoryItems) {
            return !historyTargetRows().isEmpty
        }
        if menuItem.action == #selector(abandonHistoryTask) {
            // Only meaningful in Tasks mode, on an in-progress (unfinished) task.
            guard historyMode == .tasks else { return false }
            return historyTargetRows().contains { historyRows[$0].endedAt == nil }
        }
        if menuItem.action == #selector(toggleShowPill) {
            menuItem.state = showPillEnabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(changeFocus) {
            menuItem.title = currentFocus != nil ? "Switch focus now" : "Set focus"
        }
        if menuItem.action == #selector(showHistory) {
            menuItem.title = "See history (\(db.taskCount()))"
        }
        if menuItem.action == #selector(showQueue) {
            menuItem.title = "See queue (\(db.queueCount()))"
        }
        if menuItem.action == #selector(clearQueue) {
            return db.queueCount() > 0
        }
        if menuItem.action == #selector(rateUnrated) {
            let n = db.unratedTaskCount()
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
        if case let .entered(focus, seconds, _) = askFocusAndMinutes(
            title: "Add next focus",
            info: "Queue a focus to run after the current one.",
            confirm: "Add to queue", cancellable: true) {
            db.enqueueTask(focus: focus, estimateSeconds: seconds)
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

        guard case let .entered(answer, seconds, openStart) = askFocusAndMinutes(
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
            if case let .entered(focus, seconds, openStart) = askFocusAndMinutes(
                title: "Start a different focus",
                info: "This runs now; the queued focus stays next in line.",
                confirm: "Start", cancellable: true) {
                beginSession(reason: "preempt", seconds: seconds, focus: focus, openSecondsStart: openStart)
                // Nothing was underway → preempted_session_id is NULL.
                db.recordPreempt(preemptedSessionId: nil, newSessionId: intervalId)
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
                             resumeTaskId: chosen.taskId, openSecondsStart: openStart)
                db.recordPreempt(preemptedSessionId: nil, newSessionId: intervalId)
                return
            }
            // Cancelled the picker → fall through and start the front one.
        }

        db.removeFromQueue(id: item.id)
        let queuedOpenStart = Int(Date().timeIntervalSince(confirmOpenedAt).rounded())
        beginSession(reason: "queue", seconds: item.seconds, focus: item.focus,
                     resumeTaskId: item.taskId, openSecondsStart: queuedOpenStart)
    }

    /// Show a "See Queue"-style picker (in a floating modal) of all queued focuses,
    /// with the same Est. start/finish schedule. Returns the one the user clicks,
    /// or nil if they cancel.
    private func pickFromQueue(filter: ((QueueItem) -> Bool)? = nil) -> QueueItem? {
        let items = filter.map { f in db.queueItems().filter(f) } ?? db.queueItems()
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

    private enum FocusEntry {
        case entered(focus: String, seconds: Int, openSeconds: Int)
        case queuePick            // user chose to pick an existing queued focus instead
        case cancelled
    }

    /// Editable "focus + minutes" modal. The field takes whole minutes, or a
    /// "M:SS" value (e.g. "2:30" → 150s) if a colon is present; the returned
    /// duration is in seconds. Loops until valid. With `queuePick` (and a non-empty
    /// queue) it also offers a "Pick from queue…" button → `.queuePick`.
    private func askFocusAndMinutes(title: String, info: String, confirm: String,
                                    cancellable: Bool, queuePick: Bool = false,
                                    extraTop: NSView? = nil) -> FocusEntry {
        NSApp.activate(ignoringOtherApps: true)

        let focusField = NSTextField(frame: NSRect(x: 0, y: 34, width: 320, height: 24))
        focusField.placeholderString = "e.g. \(randomFocusSuggestion())"

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
        if let extra = extraTop {   // e.g. the Switch "just this subtask" checkbox — sits on top
            extra.setFrameOrigin(NSPoint(x: 0, y: 90))
            accessory.setFrameSize(NSSize(width: 320, height: 90 + extra.frame.height))
            accessory.addSubview(extra)
        }

        let (elapsedTimer, openSeconds, _) = startElapsedTimer(elapsed)
        defer { elapsedTimer.invalidate() }

        let showQueueButton = queuePick && db.queueCount() > 0
        while true {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = info
            alert.addButton(withTitle: confirm)             // index 0
            var queueIndex = -1, cancelIndex = -1
            if showQueueButton { alert.addButton(withTitle: "Pick from queue…"); queueIndex = alert.buttons.count - 1 }
            if cancellable { alert.addButton(withTitle: "Cancel"); cancelIndex = alert.buttons.count - 1 }
            alert.accessoryView = accessory
            // Non-app-modal so the 🎯 menu stays usable while the prompt is up.
            let clicked = runFloatingAlert(alert, firstResponder: focusField)

            if clicked == cancelIndex { return .cancelled }
            if clicked == queueIndex { return .queuePick }

            let answer = focusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = parseDurationSeconds(minutesField.stringValue) ?? 0
            if !answer.isEmpty && seconds > 0 { return .entered(focus: answer, seconds: seconds, openSeconds: openSeconds()) }
            // otherwise invalid: loop and ask again
        }
    }

    /// Next "(continued)" name: "X" → "X (continued)" → "X (continued 2)" → "X (continued 3)"…

    // Start a focus. `resumeTaskId` set = resume that existing task with a NEW
    // interval (countdown continues from its remaining). `parentTaskId` set = this is
    // a subtask (a fresh task under a parent; the parent keeps ticking as an ancestor
    // — the caller pushes it first). Otherwise a fresh top-level task, which clears
    // any leftover ancestor stack.
    private func beginSession(reason: String, seconds: Int, focus: String, resumeTaskId: Int64? = nil,
                              parentTaskId: Int64? = nil, rebuildAncestors: Bool = true,
                              openSecondsStart: Int? = nil) {
        currentFocus = focus
        intervalStart = Date()
        pausedAt = nil
        if let tid = resumeTaskId, let t = db.task(id: tid) {
            // Whole-stack resume: rebuild the ancestor stack (root-first), reopening
            // each ancestor as a running frame with a fresh interval. Empty for a
            // top-level task, so a plain resume is unchanged. Skipped (rebuildAncestors
            // = false) when attaching under an already-live parent (subtask switch).
            if rebuildAncestors {
                ancestors = db.ancestorTasks(of: tid).reversed().map { a in
                    let spent = db.spentSeconds(taskId: a.id)
                    let rem = max(1, (a.estimateSeconds ?? 0) - spent)
                    let start = Date()
                    let iid = db.startInterval(taskId: a.id, reason: reason) ?? 0
                    return Frame(taskId: a.id, intervalId: iid, intervalStart: start,
                                 estimateSeconds: a.estimateSeconds ?? 0, spentBefore: spent,
                                 deadline: start.addingTimeInterval(Double(rem)), focus: a.focus)
                }
            }
            taskId = tid
            estimateSeconds = t.estimateSeconds ?? seconds
            spentBefore = db.spentSeconds(taskId: tid)
            let remaining = max(1, (estimateSeconds ?? seconds) - (spentBefore ?? 0))
            deadline = Date().addingTimeInterval(Double(remaining))
            intervalId = db.startInterval(taskId: tid, reason: reason)
        } else {
            if parentTaskId == nil { ancestors.removeAll() }   // fresh top-level → no stack
            estimateSeconds = seconds
            spentBefore = 0
            deadline = Date().addingTimeInterval(Double(seconds))
            let ids = db.startTask(reason: reason, estimateSeconds: seconds, focus: focus, parentTaskId: parentTaskId)
            taskId = ids?.taskId
            intervalId = ids?.intervalId
        }
        if let iid = intervalId, let s = openSecondsStart { db.addIntervalOpenSecondsStart(id: iid, seconds: s) }
        if pushoverEnabled { sendPushover(title: "Focus started", message: "\(focus) — \(mmss(seconds))") }
        tick()
    }

    // Start a subtask under the current task: push the current leaf onto the ancestor
    // stack (it keeps ticking), then run a fresh child task now.
    @objc func addSubtask() {
        guard !showing, let parent = taskId else { return }
        showing = true
        defer { showing = false }
        guard case let .entered(focus, seconds, openStart) = askFocusAndMinutes(
            title: "Add subtask",
            info: "Runs under the current task. If it's longer than the parent's remaining time, the parent is auto-extended so they finish together.",
            confirm: "Start", cancellable: true) else { return }
        // Push the parent and start the fresh subtask under it (auto-extends ancestors
        // to cover it, so they finish together).
        _ = parent
        startSubtaskUnderLeaf(reason: "subtask", seconds: seconds, focus: focus,
                              resumeId: nil, openStart: openStart)
    }

    // ---- history ----
    @objc func showHistory() {
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1040, height: 560),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Focus history"
            window.isReleasedWhenClosed = false   // we keep & reuse it
            window.center()

            let container = NSView(frame: window.contentView!.bounds)
            container.autoresizingMask = [.width, .height]

            // Tasks ⇄ Intervals toggle across the top.
            let toggle = NSSegmentedControl(labels: ["Tasks", "Intervals"],
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(historyModeChanged(_:)))
            toggle.selectedSegment = (historyMode == .intervals ? 1 : 0)
            toggle.frame = NSRect(x: 12, y: container.bounds.height - 32, width: 220, height: 24)
            toggle.autoresizingMask = [.minYMargin, .maxXMargin]   // pin to top-left

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: container.bounds.width,
                                                    height: container.bounds.height - 40))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true   // let wide columns (Focus/Task/Note) scroll
            scroll.borderType = .noBorder

            let table = CopyableTableView()
            table.dataSource = self
            table.delegate = self
            table.usesAlternatingRowBackgroundColors = true
            // Keep each column's natural width; total can exceed the window and
            // scroll horizontally, so wide columns aren't squeezed.
            table.columnAutoresizingStyle = .noColumnAutoresizing
            table.rowHeight = 22
            table.allowsColumnResizing = true
            table.allowsMultipleSelection = true   // Shift/⌘-click to select a range
            table.style = .inset
            table.onCopy = { [weak self] indexes in self?.copyHistoryRows(indexes) }
            // Right-click a row (or a selection) to delete it.
            let histMenu = NSMenu()
            histMenu.addItem(withTitle: "Give up (abandon)", action: #selector(abandonHistoryTask), keyEquivalent: "")
            histMenu.addItem(withTitle: "Delete", action: #selector(deleteHistoryItems), keyEquivalent: "")
            for mi in histMenu.items { mi.target = self }
            table.menu = histMenu

            scroll.documentView = table
            container.addSubview(scroll)
            container.addSubview(toggle)
            window.contentView = container

            historyWindow = window
            historyTable = table
        }

        reloadHistory()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func historyModeChanged(_ sender: NSSegmentedControl) {
        historyMode = sender.selectedSegment == 1 ? .intervals : .tasks
        reloadHistory()
    }

    /// Load the active mode's rows, install its columns, apply the sort, and refresh.
    private func reloadHistory() {
        switch historyMode {
        case .tasks:     historyRows = db.taskHistory()
        case .intervals: intervalRows = db.intervalHistory()
        }
        configureHistoryColumns()
        // Keep the current sort if it still applies to this mode; else fall back to
        // the mode's default — tasks: Ended desc (most-recently-worked, in-progress
        // on top); intervals: Started desc (newest interval first).
        let current = historyTable?.sortDescriptors.first?.key
        if current == nil || !historyColumnKeys().contains(current!) {
            let key = historyMode == .tasks ? "ended" : "when"
            historyTable?.sortDescriptors = [NSSortDescriptor(key: key, ascending: false)]
        }
        applyHistorySort()
        historyTable?.reloadData()
    }

    // Sort keys valid for the active mode's columns.
    private func historyColumnKeys() -> Set<String> {
        historyMode == .tasks ? ["when", "ended", "min", "origmin", "ivs", "rating", "status", "focus", "note"]
                              : ["when", "dur", "rating", "reason", "task"]
    }

    // Sort the active mode's backing array by the table's current sort descriptor.
    private func applyHistorySort() {
        guard let d = historyTable?.sortDescriptors.first, let key = d.key else { return }
        let asc = d.ascending
        switch historyMode {
        case .tasks:     historyRows = historyRows.sorted { taskLess($0, $1, key: key, ascending: asc) }
        case .intervals: intervalRows = intervalRows.sorted { intervalLess($0, $1, key: key, ascending: asc) }
        }
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard tableView === historyTable else { return }
        applyHistorySort()
        tableView.reloadData()
    }

    private func dir<T: Comparable>(_ a: T, _ b: T, _ ascending: Bool) -> Bool { ascending ? a < b : a > b }

    private func taskLess(_ a: TaskHistoryRow, _ b: TaskHistoryRow, key: String, ascending: Bool) -> Bool {
        switch key {
        case "when":    return dir(a.startedAt ?? "", b.startedAt ?? "", ascending)
        case "ended":
            // Finished tasks sort by finish time; unfinished (nil Ended) float to the
            // top (sentinel), and the unfinished group is tie-broken by recency so the
            // most-recently-worked in-progress task leads.
            if a.endedAt == nil && b.endedAt == nil {
                return dir(a.lastActivity ?? "", b.lastActivity ?? "", ascending)
            }
            return dir(a.endedAt ?? "\u{FFFF}", b.endedAt ?? "\u{FFFF}", ascending)
        case "min":     return dir(a.actualSeconds, b.actualSeconds, ascending)
        case "origmin": return dir(a.originalEstimateSeconds ?? -1, b.originalEstimateSeconds ?? -1, ascending)
        case "ivs":     return dir(a.intervalCount, b.intervalCount, ascending)
        case "rating":  return dir(a.rating ?? -1, b.rating ?? -1, ascending)
        case "status":  return dir(a.status ?? "", b.status ?? "", ascending)
        case "focus":   return dir(a.focus.lowercased(), b.focus.lowercased(), ascending)
        case "note":    return dir(a.note ?? "", b.note ?? "", ascending)
        default:        return dir(a.id, b.id, ascending)
        }
    }

    private func intervalLess(_ a: IntervalHistoryRow, _ b: IntervalHistoryRow, key: String, ascending: Bool) -> Bool {
        switch key {
        case "when":   return dir(a.startedAt, b.startedAt, ascending)
        case "dur":    return dir(a.seconds, b.seconds, ascending)
        case "rating": return dir(a.rating ?? -1, b.rating ?? -1, ascending)
        case "reason": return dir(a.reason ?? "", b.reason ?? "", ascending)
        case "task":   return dir(a.taskFocus.lowercased(), b.taskFocus.lowercased(), ascending)
        default:       return dir(a.id, b.id, ascending)
        }
    }

    private func configureHistoryColumns() {
        guard let table = historyTable else { return }
        for col in table.tableColumns { table.removeTableColumn(col) }
        func add(_ id: String, _ title: String, width: CGFloat, min: CGFloat, align: NSTextAlignment = .left) {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = width; col.minWidth = min; col.headerCell.alignment = align
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)   // click header to sort
            table.addTableColumn(col)
        }
        switch historyMode {
        case .tasks:
            add("when", "Started", width: 140, min: 120)
            add("ended", "Ended", width: 140, min: 120)
            add("min", "Actual", width: 70, min: 56, align: .right)
            add("origmin", "Est (orig)", width: 78, min: 60, align: .right)
            add("ivs", "Intervals", width: 70, min: 56, align: .right)
            add("rating", "Rating", width: 60, min: 50, align: .right)
            add("status", "Status", width: 95, min: 70)
            add("focus", "Focus", width: 360, min: 150)
            add("note", "Note", width: 320, min: 100)
        case .intervals:
            add("when", "Started", width: 140, min: 120)
            add("dur", "Duration", width: 70, min: 56, align: .right)
            add("rating", "Rating", width: 60, min: 50, align: .right)
            add("reason", "Reason", width: 100, min: 70)
            add("task", "Task", width: 460, min: 150)
        }
    }

    // Copy the selected history rows to the clipboard as TSV (with a header).
    private func copyHistoryRows(_ indexes: IndexSet) {
        guard !indexes.isEmpty else { return }
        if historyMode == .intervals {
            var lines = ["Started\tEnded\tDuration (s)\tRating\tReason\tTask"]
            for i in indexes where i < intervalRows.count {
                let r = intervalRows[i]
                let fields = [
                    whenLabel(r.startedAt),
                    r.endedAt.map(whenLabel) ?? "",
                    "\(r.seconds)",
                    r.rating.map { "\($0)" } ?? "",
                    r.reason ?? "",
                    r.taskFocus,
                ].map(tsvClean)
                lines.append(fields.joined(separator: "\t"))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
            return
        }
        var lines = ["Started\tEnded\tActual (s)\tOrig est (s)\tIntervals\tRating\tStatus\tFocus\tNote"]
        for i in indexes where i < historyRows.count {
            let r = historyRows[i]
            let fields = [
                r.startedAt.map(whenLabel) ?? "",
                r.endedAt.map(whenLabel) ?? "",
                "\(r.actualSeconds)",
                r.originalEstimateSeconds.map { "\($0)" } ?? "",
                "\(r.intervalCount)",
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
        let count = historyMode == .intervals ? intervalRows.count : historyRows.count
        return rows.filter { $0 < count }
    }

    // Delete the right-clicked (or selected) history sessions, after confirming.
    @objc func deleteHistoryItems() {
        guard !showing else { return }
        let rows = historyTargetRows()
        guard !rows.isEmpty else { return }
        let n = rows.count
        let noun = historyMode == .intervals ? "interval" : "task"

        showing = true
        defer { showing = false }
        let alert = makeAlert()
        alert.messageText = "Delete \(n) \(noun)\(n == 1 ? "" : "s")?"
        alert.informativeText = historyMode == .intervals
            ? "This permanently removes \(n == 1 ? "this interval" : "these intervals") — the parent task's totals shrink. This can't be undone."
            : "This permanently removes \(n == 1 ? "this task" : "these tasks") (and its intervals) from history. This can't be undone."
        alert.addButton(withTitle: "Delete")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        if historyMode == .intervals {
            db.deleteIntervals(ids: rows.map { intervalRows[$0].id })
        } else {
            db.deleteTasks(ids: rows.map { historyRows[$0].id })
        }
        reloadHistory()
    }

    // "Give up" on selected in-progress task(s) from See History: mark them
    // abandoned (a terminal status — kept in history with time worked so far, no
    // rating) and drop them from the queue, so they stop floating at the top.
    @objc func abandonHistoryTask() {
        guard !showing, historyMode == .tasks else { return }
        let rows = historyTargetRows().filter { historyRows[$0].endedAt == nil }   // in-progress only
        guard !rows.isEmpty else { return }
        let ids = rows.map { historyRows[$0].id }

        showing = true
        defer { showing = false }
        let n = ids.count
        let alert = makeAlert()
        alert.messageText = "Give up on \(n) task\(n == 1 ? "" : "s")?"
        alert.informativeText = "Marks \(n == 1 ? "it" : "them") abandoned — kept in history with the time worked so far, and removed from the queue. No rating."
        alert.addButton(withTitle: "Give up")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        for id in ids { abandon(taskId: id) }
        reloadHistory()
    }

    private func abandon(taskId tid: Int64) {
        if taskId == tid {
            // It's the currently-running task — stop it too (close interval, clear pill).
            finalizePause()
            if let iid = intervalId { db.endInterval(id: iid, elapsedSeconds: elapsedFocusSeconds()) }
            clearSessionState()
            hudWindow.orderOut(nil)
        } else if let iv = db.openInterval(taskId: tid) {
            db.endInterval(id: iv.id, elapsedSeconds: intervalElapsed(iv))
        }
        db.finishTask(id: tid, status: "abandoned")
        db.removeQueuedTask(taskId: tid)
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
        for s in db.unratedCompletedTasks() {
            let label = "\(s.createdAt.map(whenLabel) ?? "") · \(s.focus) · \(mmss(db.spentSeconds(taskId: s.id)))"
            let (rating, note, _, _) = promptRating(focus: label, title: "Rate session")
            db.setTaskRating(id: s.id, rating: rating, note: note)
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
        tableView === queueTable ? queueRows.count
            : (historyMode == .intervals ? intervalRows.count : historyRows.count)
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

        if historyMode == .intervals {
            guard row < intervalRows.count else { return nil }
            let r = intervalRows[row]
            let text: String
            var align: NSTextAlignment = .left
            switch id {
            case "when":   text = whenLabel(r.startedAt)
            case "dur":    text = mmss(r.seconds); align = .right
            case "rating": text = r.rating.map { "\($0)/10" } ?? "—"; align = .right
            case "reason": text = r.reason ?? "—"
            default:       text = r.taskFocus
            }
            return historyCell(tableView, id: id, text: text, align: align)
        }

        guard row < historyRows.count else { return nil }
        let r = historyRows[row]
        let text: String
        var align: NSTextAlignment = .left
        switch id {
        case "when":      text = r.startedAt.map(whenLabel) ?? "—"
        case "ended":     text = r.endedAt.map(whenLabel) ?? "—"
        case "min":       text = mmss(r.actualSeconds); align = .right
        case "origmin":   text = r.originalEstimateSeconds.map { mmss($0) } ?? "—"; align = .right
        case "ivs":       text = "\(r.intervalCount)"; align = .right
        case "rating":    text = r.rating.map { "\($0)/10" } ?? "—"; align = .right
        case "status":    text = r.status ?? (r.endedAt == nil ? "active" : "—")
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
        guard let focus = currentFocus, let dl = deadline else { hudWindow.orderOut(nil); return }

        // Only the LEAF triggers time's-up (it's what you're actively doing). Ancestors
        // past their deadline just show overtime and wait until they become the leaf.
        if pausedAt == nil {
            let remaining = Int(dl.timeIntervalSinceNow.rounded())
            if remaining <= 0 {
                if showing { return }                                    // a prompt is up; leave things be
                if RunLoop.current.currentMode == .eventTracking {       // menu open → defer to next tick
                    statusItem.menu?.cancelTracking()
                    return
                }
                timeUp(focus: focus)
                return
            }
        }

        hudLabel.attributedStringValue = pillAttributedString()
        layoutHUD()
        if showPillEnabled { hudWindow.orderFrontRegardless() } else { hudWindow.orderOut(nil) }
    }

    /// Build the pill text for the whole stack: ancestors (root at top) then the leaf,
    /// each with its own countdown. A level past its deadline shows red "+overtime".
    private func pillAttributedString() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let ref = pausedAt ?? Date()
        func line(focus: String, deadline: Date, estimate: Int, isLeaf: Bool) -> NSAttributedString {
            let rem = Int(deadline.timeIntervalSince(ref).rounded())
            let over = rem < 0
            let timeStr = over ? "+\(mmss(-rem))"
                               : (showTotalOnPillEnabled ? "\(mmss(rem)) / \(mmss(estimate))" : mmss(rem))
            let icon = isLeaf ? (pausedAt != nil ? "⏸ " : "🎯 ") : "↳ "
            let suffix = (isLeaf && pausedAt != nil) ? " (paused)" : ""
            let font = isLeaf ? NSFont.systemFont(ofSize: 14, weight: .semibold)
                              : NSFont.systemFont(ofSize: 12, weight: .medium)
            let color: NSColor = over ? .systemRed : (isLeaf ? .white : NSColor(white: 1, alpha: 0.7))
            return NSAttributedString(string: "\(icon)\(focus)    \(timeStr)\(suffix)",
                                      attributes: [.font: font, .foregroundColor: color])
        }
        for f in ancestors {   // root … immediate parent
            out.append(line(focus: f.focus, deadline: f.deadline, estimate: f.estimateSeconds, isLeaf: false))
            out.append(NSAttributedString(string: "\n"))
        }
        out.append(line(focus: currentFocus ?? "", deadline: deadline ?? Date(),
                        estimate: estimateSeconds ?? 0, isLeaf: true))
        return out
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
            let tid = taskId, iid = intervalId
            let elapsed = elapsedFocusSeconds()
            finalizePause()
            let hadParent = popAncestorToLeaf()
            if !hadParent { clearSessionState() }
            if let iid = iid { db.endInterval(id: iid, elapsedSeconds: elapsed) }
            if let tid = tid { db.finishTask(id: tid, status: "completed") }   // rating deferred to "Rate unrated"
            showing = false
            if hadParent { tick() } else { promptForFocus(reason: "after-session") }
            return
        }

        switch promptTimeUp(focus: focus, seconds: estimateSeconds ?? 0) {
        case .addTime(let added):
            // Keep the SAME session going. The popup-open time was already accounted
            // (to duration or end, per the checkbox) inside promptTimeUp — just extend.
            extendSession(by: added)
            extendAncestorsToCoverLeaf()   // keep ancestors covering the extended leaf
            showing = false

        case .rate(let rating, let note, let openSeconds, let applyTime):
            let tid = taskId, iid = intervalId
            let elapsed = elapsedFocusSeconds()
            finalizePause()
            let hadParent = popAncestorToLeaf()
            if !hadParent { clearSessionState() }
            if let iid = iid {
                db.endInterval(id: iid, elapsedSeconds: elapsed, openSecondsEnd: applyTime ? nil : openSeconds)
                if applyTime { db.addToInterval(id: iid, seconds: openSeconds) }
            }
            if let tid = tid { db.finishTask(id: tid, status: "completed", rating: rating, note: note) }
            // Back to the parent subtask (if any) or on to the next focus.
            showing = false
            if hadParent { tick() } else { promptForFocus(reason: "after-session") }
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
                if let iid = intervalId {
                    let span = openSeconds()
                    if apply.state == .on { db.addToInterval(id: iid, seconds: span) }
                    else { db.addIntervalOpenSecondsEnd(id: iid, seconds: span) }
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

    /// Force a rating, close the leaf as completed, and pop back to the parent (if a
    /// subtask) or clear the leaf. Returns whether a parent was popped. Caller holds
    /// `showing`. Completing early records the time actually used as the interval's.
    @discardableResult
    private func rateAndComplete() -> Bool {
        guard let tid = taskId, let iid = intervalId, let focus = currentFocus else { return false }
        let elapsed = elapsedFocusSeconds()   // excludes pause time
        finalizePause()
        let hadParent = popAncestorToLeaf()
        if !hadParent { clearSessionState() }
        hudWindow.orderOut(nil)
        let (rating, note, openSeconds, applyTime) = promptRating(focus: focus, title: "Rate this session")
        db.endInterval(id: iid, elapsedSeconds: elapsed, openSecondsEnd: applyTime ? nil : openSeconds)
        if applyTime { db.addToInterval(id: iid, seconds: openSeconds) }
        db.finishTask(id: tid, status: "completed", rating: rating, note: note)
        return hadParent
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
        menu.addItem(withTitle: "Pause", action: #selector(togglePause), keyEquivalent: "")
        menu.addItem(withTitle: "Add time", action: #selector(addTimeToCurrent), keyEquivalent: "")
        menu.addItem(withTitle: "Add subtask", action: #selector(addSubtask), keyEquivalent: "")
        menu.addItem(withTitle: "Rename task", action: #selector(renameTask), keyEquivalent: "")
        menu.addItem(withTitle: "Abort task", action: #selector(abortTask), keyEquivalent: "")
        menu.addItem(withTitle: "Stop working", action: #selector(stopWorking), keyEquivalent: "")
        menu.addItem(withTitle: "Switch focus now", action: #selector(changeFocus), keyEquivalent: "")
        menu.addItem(.separator())
        // The queue.
        menu.addItem(withTitle: "Add to queue", action: #selector(addNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Add to front", action: #selector(preemptNextFocus), keyEquivalent: "")
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
        hudLabel.maximumNumberOfLines = 0          // allow a line per stack level (subtasks)
        hudLabel.cell?.usesSingleLineMode = false
        hudLabel.cell?.wraps = false               // explicit newlines, don't wrap

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
