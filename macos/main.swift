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

// Same ⌘C support for the History outline (NSOutlineView is an NSTableView subclass).
final class CopyableOutlineView: NSOutlineView {
    var onCopy: ((IndexSet) -> Void)?

    @objc func copy(_ sender: Any?) { onCopy?(selectedRowIndexes) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

// A node in the History tree: a task (with subtask children), or an interval shown as
// a dim child row when "Show intervals" is on. A reference type so NSOutlineView can
// track identity/expansion.
final class HistoryNode {
    let task: TaskHistoryRow?
    let interval: IntervalHistoryRow?
    var children: [HistoryNode]
    init(task: TaskHistoryRow, children: [HistoryNode] = []) { self.task = task; self.interval = nil; self.children = children }
    init(interval: IntervalHistoryRow) { self.task = nil; self.interval = interval; self.children = [] }
}

// An NSTableView that reports Delete / ⌦ key presses (to remove the selected item)
// and supports ⌘C (to copy the selected rows).
final class QueueTableView: NSTableView {
    var onDelete: ((Int) -> Void)?
    var onCopy: ((IndexSet) -> Void)?
    var onMove: ((Int) -> Void)?   // ⌘↑ / ⌘↓ → move the selected row by ∓1

    override func keyDown(with event: NSEvent) {
        // ⌘↑ / ⌘↓ move the selected row up / down one (126 = up arrow, 125 = down).
        if event.modifierFlags.contains(.command), event.keyCode == 126 || event.keyCode == 125 {
            onMove?(event.keyCode == 126 ? -1 : 1)
            return
        }
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

// The pill's content view. It replaces isMovableByWindowBackground with manual handling so
// a *click* and a *drag* don't fight: a press that moves past a small threshold drives the
// window drag; a press that doesn't, and lands on the ⏸ icon, fires `onResumeClick`. You can
// drag from anywhere on the pill, but only the pause glyph resumes. `resumeHitRect` (in view
// coords) is set by layout while paused, nil otherwise.
final class PillView: NSVisualEffectView {
    var onResumeClick: (() -> Void)?
    var resumeHitRect: NSRect?
    private var downAt: NSPoint = .zero
    private var dragging = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self   // claim the whole pill (drag anywhere), label included
    }
    override func mouseDown(with event: NSEvent) {
        downAt = event.locationInWindow
        dragging = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let window = window else { return }
        let moved = hypot(event.locationInWindow.x - downAt.x, event.locationInWindow.y - downAt.y)
        if moved > 3 {                       // past the click/drag threshold → it's a drag
            dragging = true
            window.performDrag(with: event)  // runs the drag loop; the window follows the mouse
        }
    }
    override func mouseUp(with event: NSEvent) {
        guard !dragging, let rect = resumeHitRect else { return }   // a click, and paused
        if rect.contains(convert(downAt, from: nil)) { onResumeClick?() }   // …on the ⏸ icon
    }
}

/// A modal that collects ONE OR MORE (focus, minutes) rows for batch-enqueuing. Each row is
/// a name field + a minutes field + a "−" remove button; "+ Add another" appends a row.
/// Submit returns every row that's filled and valid, top-to-bottom (queue order); fully-empty
/// rows are skipped, and a half-filled/invalid row blocks submit. Cancel/Esc returns nil.
/// Used only by the queue-add paths — the single-task start-now prompts keep askFocusAndMinutes.
final class MultiFocusPrompt: NSObject {
    struct Entry { let focus: String; let seconds: Int; let tags: [String] }

    private final class RowView: NSView {
        let focus = NSTextField()
        let minutes = NSTextField()
        let tags = NSTextField()
        let remove = NSButton(title: "\u{2212}", target: nil, action: nil)   // − (minus)
    }

    private let titleText: String, infoText: String, confirmText: String
    private let defaultTags: String
    private var window: NSWindow!
    private var infoLabel: NSTextField!
    private var headerFocus: NSTextField!
    private var headerTags: NSTextField!
    private var headerMinutes: NSTextField!
    private var addButton: NSButton!
    private var submitButton: NSButton!
    private var cancelButton: NSButton!
    private var rows: [RowView] = []
    private var result: [Entry]?

    private let width: CGFloat = 620, pad: CGFloat = 16, rowH: CGFloat = 30
    private let infoH: CGFloat = 34, btnH: CGFloat = 28, gap: CGFloat = 10, headerH: CGFloat = 16

    init(title: String, info: String, confirm: String, defaultTags: String = "") {
        titleText = title; infoText = info; confirmText = confirm; self.defaultTags = defaultTags
        super.init()
    }

    /// Show the modal (app-modal). Returns the entered rows, or nil if cancelled / all empty.
    func run() -> [Entry]? {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 300),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.title = titleText
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        infoLabel = NSTextField(wrappingLabelWithString: infoText)
        infoLabel.font = NSFont.systemFont(ofSize: 12)
        window.contentView!.addSubview(infoLabel)

        headerFocus = columnHeader("Focus / task")
        headerTags = columnHeader("Tags (comma-separated)")
        headerMinutes = columnHeader("Duration (min)")
        window.contentView!.addSubview(headerFocus)
        window.contentView!.addSubview(headerTags)
        window.contentView!.addSubview(headerMinutes)

        addButton = NSButton(title: "+ Add another", target: self, action: #selector(addRowClicked))
        addButton.bezelStyle = .rounded
        window.contentView!.addSubview(addButton)

        submitButton = NSButton(title: confirmText, target: self, action: #selector(submit))
        submitButton.bezelStyle = .rounded
        submitButton.keyEquivalent = "\r"   // Enter submits
        window.contentView!.addSubview(submitButton)

        cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelButton.bezelStyle = .rounded
        cancelButton.keyEquivalent = "\u{1b}"   // Esc
        window.contentView!.addSubview(cancelButton)

        addRow()   // start with one row
        relayout()
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(rows.first?.focus)
        NSApp.runModal(for: window)
        window.orderOut(nil)
        return result
    }

    private func addRow() {
        let row = RowView()
        row.focus.placeholderString = "e.g. \(randomFocusSuggestion())"
        row.minutes.stringValue = String(defaultMinutes)
        row.tags.stringValue = defaultTags
        row.tags.placeholderString = "optional"
        row.remove.bezelStyle = .circular
        row.remove.target = self
        row.remove.action = #selector(removeRowClicked(_:))
        row.addSubview(row.focus); row.addSubview(row.tags); row.addSubview(row.minutes); row.addSubview(row.remove)
        rows.append(row)
        window.contentView!.addSubview(row)
    }

    @objc private func addRowClicked() {
        addRow(); relayout(); window.makeFirstResponder(rows.last?.focus)
    }

    @objc private func removeRowClicked(_ sender: NSButton) {
        guard rows.count > 1, let row = rows.first(where: { $0.remove === sender }) else { return }
        row.removeFromSuperview()
        rows.removeAll { $0 === row }
        relayout()
    }

    @objc private func submit() {
        var out: [Entry] = []
        for r in rows {
            let f = r.focus.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = r.minutes.stringValue.trimmingCharacters(in: .whitespaces)
            if f.isEmpty && m.isEmpty { continue }   // fully empty row → skip
            guard !f.isEmpty, let s = parseDurationSeconds(m), s > 0 else {
                // half-filled / invalid → focus the offending field and block submit
                window.makeFirstResponder(f.isEmpty ? r.focus : r.minutes)
                NSSound.beep()
                return
            }
            let tags = r.tags.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            out.append(Entry(focus: f, seconds: s, tags: tags))
        }
        result = out.isEmpty ? nil : out
        NSApp.stopModal()
    }

    @objc private func cancel() { result = nil; NSApp.stopModal() }

    // Column geometry, shared by the header labels and every row so they line up.
    private let removeW: CGFloat = 26, minutesW: CGFloat = 56, tagsW: CGFloat = 160, fieldGap: CGFloat = 8
    private func focusW(_ rowWidth: CGFloat) -> CGFloat { rowWidth - removeW - minutesW - tagsW - 3 * fieldGap }

    private func columnHeader(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: 10, weight: .medium)
        l.textColor = .secondaryLabelColor
        return l
    }

    private func relayout() {
        let rowWidth = width - 2 * pad
        let n = CGFloat(rows.count)
        let contentH = pad + infoH + gap + headerH + n * rowH + gap + btnH + gap + btnH + pad

        // Grow/shrink downward: keep the window's TOP edge fixed as rows are added/removed.
        let oldTop = window.frame.maxY
        window.setContentSize(NSSize(width: width, height: contentH))
        if oldTop > 0 {
            var origin = window.frame.origin
            origin.y = oldTop - window.frame.height
            window.setFrameOrigin(origin)
        }

        let fW = focusW(rowWidth)
        var topY = contentH - pad
        topY -= infoH
        infoLabel.frame = NSRect(x: pad, y: topY, width: rowWidth, height: infoH)
        topY -= gap
        // Header labels, aligned to the row columns below.
        topY -= headerH
        headerFocus.frame = NSRect(x: pad, y: topY, width: fW, height: headerH)
        headerTags.frame = NSRect(x: pad + fW + fieldGap, y: topY, width: tagsW, height: headerH)
        headerMinutes.frame = NSRect(x: pad + fW + tagsW + 2 * fieldGap, y: topY, width: minutesW + fieldGap + removeW, height: headerH)
        for row in rows {
            topY -= rowH
            row.frame = NSRect(x: pad, y: topY, width: rowWidth, height: rowH)
            layoutRow(row, rowWidth: rowWidth)
            row.remove.isHidden = (rows.count == 1)   // no "−" when a single row remains
        }
        topY -= gap
        topY -= btnH
        addButton.frame = NSRect(x: pad, y: topY, width: 150, height: btnH)
        // Submit / Cancel pinned to the bottom-right, sized to fit their titles.
        submitButton.sizeToFit(); cancelButton.sizeToFit()
        let submitW = max(100, submitButton.frame.width + 20)
        let cancelW = max(80, cancelButton.frame.width + 20)
        submitButton.frame = NSRect(x: width - pad - submitW, y: pad, width: submitW, height: btnH)
        cancelButton.frame = NSRect(x: width - pad - submitW - 8 - cancelW, y: pad, width: cancelW, height: btnH)
    }

    private func layoutRow(_ row: RowView, rowWidth: CGFloat) {
        let fW = focusW(rowWidth)
        row.focus.frame = NSRect(x: 0, y: 3, width: fW, height: 24)
        row.tags.frame = NSRect(x: fW + fieldGap, y: 3, width: tagsW, height: 24)
        row.minutes.frame = NSRect(x: fW + tagsW + 2 * fieldGap, y: 3, width: minutesW, height: 24)
        row.remove.frame = NSRect(x: rowWidth - removeW, y: 3, width: removeW, height: 24)
    }
}

// A read-only "See Queue"-style table used to pick a queued focus to pre-empt
// with. Single-clicking a row fires `onPick` with that item. Self-contained data
// source/delegate so it doesn't collide with AppController's own two tables.
struct QueuePickRow { let item: QueueItem; let num: Int; let duration: String; let start: String; let finish: String; let focusDisplay: String }

final class QueuePickSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [QueuePickRow]
    private let onPick: (QueueItem) -> Void
    init(rows: [QueuePickRow], onPick: @escaping (QueueItem) -> Void) { self.rows = rows; self.onPick = onPick }

    func makeTable() -> NSTableView {
        let t = NSTableView()
        t.usesAlternatingRowBackgroundColors = true
        t.rowHeight = 22
        t.style = .inset
        t.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle   // Focus grows with the window
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
        default:       text = r.focusDisplay
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

/// A subtask you can switch to: a non-terminal child of the current task. `queueRowId`
/// set = parked in the queue (shown normally); nil = it exists but isn't queued —
/// e.g. removed from the queue — and is shown grayed.
struct SubtaskChoice { let taskId: Int64; let focus: String; let remaining: Int; let queueRowId: Int64? }

struct SubtaskPickRow { let choice: SubtaskChoice; let duration: String }

final class SubtaskPickSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let rows: [SubtaskPickRow]
    private let onPick: (SubtaskChoice) -> Void
    init(rows: [SubtaskPickRow], onPick: @escaping (SubtaskChoice) -> Void) { self.rows = rows; self.onPick = onPick }

    func makeTable() -> NSTableView {
        let t = NSTableView()
        t.usesAlternatingRowBackgroundColors = true
        t.rowHeight = 22
        t.style = .inset
        t.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        t.headerView = NSTableHeaderView()
        func col(_ id: String, _ title: String, _ w: CGFloat, _ a: NSTextAlignment = .left) {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            c.title = title; c.width = w; c.headerCell.alignment = a
            t.addTableColumn(c)
        }
        col("dur", "Remaining", 90, .right)
        col("focus", "Subtask (queued first; grayed = not queued)", 340)
        t.dataSource = self
        t.delegate = self
        t.target = self
        t.action = #selector(clicked(_:))
        return t
    }

    @objc private func clicked(_ sender: NSTableView) {
        let r = sender.clickedRow
        guard r >= 0, r < rows.count else { return }
        onPick(rows[r].choice)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = rows[row]
        let text: String
        let align: NSTextAlignment
        switch tableColumn?.identifier.rawValue {
        case "dur": text = r.duration; align = .right
        default:    text = r.choice.focus; align = .left
        }
        let cell = NSTableCellView()
        let tf = NSTextField(labelWithString: text)
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        tf.alignment = align
        tf.font = NSFont.systemFont(ofSize: 12)
        tf.textColor = r.choice.queueRowId == nil ? .secondaryLabelColor : .labelColor   // grayed = not queued
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
                           NSTableViewDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate,
                           NSMenuItemValidation, NSWindowDelegate {
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

    /// The task you committed to for this work session — the one pulled from the queue
    /// (or started fresh). Strict mode locks you to it: you can drill into subtasks below
    /// it, but can't Stop working / Switch away from the commitment itself, even when it's
    /// a subtask (its parents were rebuilt as ticking context). Persisted so the lock
    /// survives quit/relaunch (which restores the running stack). Set only on a *primary*
    /// start, never on a subtask push.
    private var committedTaskId: Int64? {
        get { (UserDefaults.standard.object(forKey: "committedTaskId") as? Int).map(Int64.init) }
        set {
            if let v = newValue { UserDefaults.standard.set(Int(v), forKey: "committedTaskId") }
            else { UserDefaults.standard.removeObject(forKey: "committedTaskId") }
        }
    }

    /// In strict mode, whether the current leaf IS the committed task (so Stop/Switch are
    /// locked out). False when idle, when strict is off, or when the leaf is a deeper
    /// subtask created below the commitment.
    private var lockedToCommitment: Bool {
        strictModeEnabled && taskId != nil && taskId == committedTaskId
    }

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
    /// Suspend the whole stack, re-queuing the current task to resume later. `toFront`
    /// picks where: Switch-focus-now pre-empts (→ front, runs next), Stop working parks
    /// it at the back of the queue (→ end).
    private func suspendStack(toFront: Bool) {
        guard let tid = taskId, let iid = intervalId, let focus = currentFocus else { return }
        let remaining = max(1, remainingSeconds())
        let elapsed = elapsedFocusSeconds()
        resumeStackIfPaused()
        db.endInterval(id: iid, elapsedSeconds: elapsed)
        let now = Date()
        for f in ancestors {
            db.closeOpenPause(sessionId: f.intervalId)
            let anElapsed = max(0, Int(now.timeIntervalSince(f.intervalStart).rounded()) - db.totalPausedSeconds(sessionId: f.intervalId))
            db.endInterval(id: f.intervalId, elapsedSeconds: anElapsed)
        }
        db.enqueueTask(focus: focus, estimateSeconds: remaining, taskId: tid, front: toFront)
        clearSessionState()
    }

    /// Suspend just the current subtask (leaf): close its interval, re-queue it (carrying
    /// its parent link) so it's resumable from the queue, then pop to the parent, which
    /// keeps ticking. `toFront` picks front (pre-empt) vs. end (Stop working).
    /// Returns false if there's no parent (top-level) — caller uses suspendStack then.
    @discardableResult
    private func suspendLeaf(toFront: Bool = true) -> Bool {
        guard !ancestors.isEmpty, let tid = taskId, let iid = intervalId, let focus = currentFocus else { return false }
        let remaining = max(1, remainingSeconds())
        let elapsed = elapsedFocusSeconds()
        resumeStackIfPaused()
        db.endInterval(id: iid, elapsedSeconds: elapsed)
        db.enqueueTask(focus: focus, estimateSeconds: remaining, taskId: tid, front: toFront)
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
    // True only while the non-app-modal "Ready to focus?" chooser is up. Because that
    // prompt doesn't seize the app, Settings can be opened over it (the one blocked action
    // exempted while it's showing).
    private var nextFocusOpen = false
    // Set by Settings (opened over the chooser) to make the chooser tear down and rebuild
    // so it reflects the new settings (e.g. strict mode toggled on/off).
    private var nextFocusNeedsRerender = false
    private var lastFired = Date.distantPast
    private let cooldown: TimeInterval = 10
    private var panelResult: Int?   // set by a floating (non-app-modal) panel's button

    // ---- ui ----
    private var statusItem: NSStatusItem!
    private var hudWindow: NSWindow!
    private var hudPill: PillView!
    private var hudLabel: NSTextField!
    private var hudAnchorTopRight: NSPoint? // set once the user drags the pill; layout keeps this corner fixed
    private var hudProgrammaticMove = false // guards windowDidMove during our own setFrame
    private var uiTimer: Timer?
    private var historyWindow: NSWindow?
    private var historyOutline: NSOutlineView?
    private var historyRows: [TaskHistoryRow] = []       // all tasks (flat), for building the tree
    private var historyTags: [Int64: [String]] = [:]     // task id → its tag names (for the Tags column)
    private var historyNodes: [HistoryNode] = []          // root nodes shown in the outline
    private var showIntervalsInTree = false               // nest each task's intervals as dim child rows
    private var queueWindow: NSWindow?
    private var queueTable: NSTableView?
    private var queueFilterLabel: NSTextField?        // "Filter: work, urgent" in the See Queue top bar
    private var queueFilterClearButton: NSButton?
    private var queueRows: [QueueItem] = []
    private var queueEstimates: [(start: Date, finish: Date)] = []
    private var queueTags: [Int64: [String]] = [:]       // task id → tag names (for the queue Tags column)

    // Queue tag filter — a persisted set of tag names (case-insensitive). Empty = no filter.
    // When non-empty, See Queue shows only items whose task has ≥1 of these tags, the
    // next-task choice considers only those, and untagged items are ineligible. Edited from
    // the See Queue window's filter control.
    private var queueFilterTags: [String] {
        get { (UserDefaults.standard.array(forKey: "queueFilterTags") as? [String]) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "queueFilterTags") }
    }
    private func queueFilterActive() -> Bool { !queueFilterTags.isEmpty }

    /// Does this queue item match the active filter? Always true when no filter is set;
    /// with a filter active, an untagged item (or one with none of the selected tags) is
    /// ineligible.
    private func matchesQueueFilter(_ item: QueueItem, tagsByTask: [Int64: [String]]) -> Bool {
        let filter = Set(queueFilterTags.map { $0.lowercased() })
        if filter.isEmpty { return true }
        guard let tid = item.taskId, let names = tagsByTask[tid] else { return false }
        return names.contains { filter.contains($0.lowercased()) }
    }

    /// The front-most queue item eligible under the active filter, or nil.
    private func nextEligibleQueueItem() -> QueueItem? {
        let byTask = db.tagNamesByTask()
        return db.queueItems().first { matchesQueueFilter($0, tagsByTask: byTask) }
    }
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
        promptNextFocus(startReason: reason)
        lastFired = Date()          // stamp AFTER dismissal
    }

    // ---- resume-after-restart ----
    private func restoreOrPrompt() {
        let open = db.openIntervals()   // newest first

        guard let leafIv = open.first, let leafTask = db.task(id: leafIv.taskId),
              isoParser.date(from: leafIv.startedAt) != nil else {
            // No task was running — sweep any strays and show the startup chooser.
            for iv in open { db.endInterval(id: iv.id, elapsedSeconds: intervalElapsed(iv)) }
            promptNextFocus(startReason: "launch")
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

        // Was the stack paused when the process died? (Pause opens a pause row on every
        // level at once, so the leaf's open pause implies the whole stack's.) If so we
        // preserve it below instead of folding the downtime into pause and resuming.
        let pausedStart = db.openPauseStart(sessionId: leafIv.id)

        // Reconstruct a frame for a task. When resuming (not paused), close any open
        // pause so the downtime counts as pause; when paused-at-quit, leave the pause
        // open so it keeps freezing. Either way the deadline is estimate − prior-spent
        // (+ closed pauses) — for the paused case that's the frozen-at-pause deadline.
        func frame(for task: TaskRow) -> Frame? {
            guard let iv = openByTask[task.id], let start = isoParser.date(from: iv.startedAt) else { return nil }
            if pausedStart == nil { db.closeOpenPause(sessionId: iv.id) }
            let paused = db.totalPausedSeconds(sessionId: iv.id)
            let spent = db.spentSeconds(taskId: task.id)
            let dl = start.addingTimeInterval(Double((task.estimateSeconds ?? 0) - spent + paused))
            return Frame(taskId: task.id, intervalId: iv.id, intervalStart: start,
                         estimateSeconds: task.estimateSeconds ?? 0, spentBefore: spent, deadline: dl, focus: task.focus)
        }
        guard let leaf = frame(for: leafTask) else {
            db.endInterval(id: leafIv.id, elapsedSeconds: intervalElapsed(leafIv)); promptNextFocus(startReason: "launch"); return
        }
        // ancestors want root … parent (chain is leaf-first, so drop leaf and reverse).
        ancestors = chain.dropFirst().reversed().compactMap { frame(for: $0) }

        // A task/stack was running when we quit → continue it silently, with NO startup
        // prompt: keep running if it was running, keep frozen if it was paused. (When
        // paused, the downtime folds into the pause once the user hits Resume.)
        setLeaf(leaf)
        pausedAt = pausedStart   // nil = running; the open pause's start = stay paused
        tick()
    }

    /// The single "what's next?" flow for every idle moment — launch, wake, unlock, "Set
    /// focus", and after a session ends. With a queue, it confirms the front focus (Start /
    /// different / pick / Close, auto-proceeding when that preference is on); with an empty
    /// queue, it asks for a fresh focus. Close goes idle — except in strict mode, which
    /// forces you to start something. Loops back if you cancel out of a sub-prompt.
    private func promptNextFocus(startReason: String) {
        guard !showing else { return }
        showing = true
        nextFocusOpen = true
        defer { showing = false; nextFocusOpen = false }
        NSApp.activate(ignoringOtherApps: true)
        while true {
            nextFocusNeedsRerender = false   // fresh each render; Settings sets it to loop back
            if let next = nextEligibleQueueItem() {   // front-most item passing the tag filter
                switch confirmQueued(next) {
                case .started, .closed: return
                case .retry: continue   // includes "Settings changed → rebuild"
                }
            }
            // Empty queue → start a fresh focus. Strict mode makes it mandatory (no cancel).
            let entry = askFocusAndMinutes(
                title: "Ready to focus?", info: "What's your one focus right now, and for how long?",
                confirm: "Start", cancellable: !strictModeEnabled)
            if nextFocusNeedsRerender { continue }   // Settings changed → rebuild the chooser
            switch entry {
            case .entered(let focus, let seconds, let openStart, let tags):
                beginSession(reason: startReason, seconds: seconds, focus: focus, openSecondsStart: openStart)
                applyTags(tags, toNewTask: taskId)
                return
            case .cancelled:
                return   // Close → idle (only reachable when not strict)
            case .queuePick:
                continue // not offered here; treat as a retry
            }
        }
    }

    // "Set focus" is an explicit ad-hoc entry — it bypasses the queue.
    // Idle → "Set focus" (ad-hoc, bypasses queue). Active → "Pre-empt": re-queue
    // the current focus (with its remaining time) to the FRONT and run a new one
    // now — the same idea as pre-empting a focus that's about to begin, but for
    // the one already running.
    @objc func changeFocus() {
        // Idle "Set focus" is the same unified next-focus flow used at launch / wake /
        // after a session (promptNextFocus manages its own `showing`). The rest of this
        // method is the active "Switch focus now" flow, so `preempting` is always true.
        guard taskId != nil else { promptNextFocus(startReason: "manual"); return }
        guard !showing else { return }
        showing = true
        defer { showing = false }

        NSApp.activate(ignoringOtherApps: true)

        let preempting = taskId != nil
        let nested = preempting && !ancestors.isEmpty
        let parentId = ancestors.last?.taskId          // the immediate parent (for subtask mode)
        let title = preempting ? "Switch to a new focus" : "Set focus"
        let hasQueue = db.queueCount() > 0
        let info = preempting
            ? "This runs now; the current focus goes to the front of the queue. Or pick one from the queue."
            : (hasQueue ? "What's your one focus right now, and for how long? Or pick one from the queue."
                        : "What's your one focus right now, and for how long?")

        // When nested, offer to switch just this subtask (keeping the parent running)
        // vs. the whole task. Default: just this subtask. (Top-level → no checkbox.)
        var subtaskBox: NSButton? = nil
        if nested {
            let cb = NSButton(checkboxWithTitle: "Switch just this subtask (keep the parent running)", target: nil, action: nil)
            cb.state = .on
            cb.sizeToFit()   // width tracks the label so the accessory grows to fit it
            subtaskBox = cb
        }

        // Pre-empt is voluntary → cancellable (cancel leaves the current session
        // untouched) and can pull from the queue. Idle "Set focus" stays mandatory.
        var newFocus = "", newSeconds = 0
        var newOpenStart: Int? = nil
        var newTags: [String] = []
        var resumeId: Int64? = nil
        var subtaskMode = false
        prompt: while true {
            let entry = askFocusAndMinutes(title: title, info: info, confirm: "Start",
                                           cancellable: preempting, queuePick: true, extraTop: subtaskBox)
            subtaskMode = nested && (subtaskBox?.state == .on)   // read AFTER the modal
            switch entry {
            case .cancelled:
                return
            case .entered(let f, let s, let o, let tags):
                newFocus = f; newSeconds = s; newOpenStart = o; newTags = tags   // fresh task
                break prompt
            case .queuePick:
                if subtaskMode, let pid = parentId {
                    // Switch to a SIBLING subtask (another child of the parent, minus the
                    // current one): queued ones first, then unqueued-but-unfinished grayed
                    // — same picker as "Switch to subtask".
                    let sibs = resumableSubtasks(of: pid, excluding: taskId)
                    guard !sibs.isEmpty else {
                        let alert = makeAlert()
                        alert.messageText = "No other subtasks"
                        alert.informativeText = "This task has no other subtasks to switch to."
                        alert.addButton(withTitle: "OK")
                        alert.window.level = .floating
                        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                        _ = runFloatingAlert(alert)
                        continue prompt
                    }
                    let rows = sibs.map { SubtaskPickRow(choice: $0, duration: mmss($0.remaining)) }
                    var picked: SubtaskChoice?
                    let source = SubtaskPickSource(rows: rows) { c in picked = c; NSApp.stopModal() }
                    runPickerWindow(title: "Switch to subtask",
                                    info: "Pick a subtask to switch to — it runs under the same parent. Grayed rows aren't in the queue.",
                                    table: source.makeTable())
                    guard let pick = picked else { continue prompt }
                    if let rowId = pick.queueRowId { db.removeFromQueue(id: rowId) }   // no-op for unqueued
                    newFocus = pick.focus; newSeconds = max(1, pick.remaining); resumeId = pick.taskId
                    break prompt
                }
                // Whole-stack switch / Set focus → pick ANY queued item.
                guard db.queueCount() > 0 else {
                    let alert = makeAlert()
                    alert.messageText = "Nothing in the queue"
                    alert.informativeText = "There are no tasks in the queue to switch to."
                    alert.addButton(withTitle: "OK")
                    alert.window.level = .floating
                    alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    _ = runFloatingAlert(alert)
                    continue prompt
                }
                guard let item = pickFromQueue() else { continue prompt }
                // If the picked item is a subtask, offer going straight to it (default —
                // rebuilds its whole tree) or to its top-level root task instead.
                // ancestorTasks is [parent, …, root], so .last is the root.
                if let root = item.taskId.flatMap({ self.db.ancestorTasks(of: $0).last }) {
                    let choice = makeAlert()
                    choice.messageText = "Go to the subtask or its parent?"
                    choice.informativeText = "\(queueDisplayName(item))\n\nStart just this subtask, or focus its top-level task “\(root.focus)” instead (the subtask stays in the queue)."
                    choice.addButton(withTitle: "Go to the subtask")        // 0
                    choice.addButton(withTitle: "Focus the parent instead") // 1
                    choice.window.level = .floating
                    choice.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
                    if runFloatingAlert(choice) == 1 {
                        // Focus the root; leave the subtask queued (going to the parent
                        // doesn't complete it). beginSession resumes root as a top-level leaf.
                        newFocus = root.focus; newSeconds = item.seconds; resumeId = root.id
                        break prompt
                    }
                    // else fall through: go to the subtask (current behavior).
                }
                db.removeFromQueue(id: item.id)
                newFocus = item.focus; newSeconds = item.seconds; resumeId = item.taskId
                break prompt
            }
        }

        let preemptedInterval = intervalId
        if subtaskMode {
            // Suspend just this subtask (drops to the still-ticking parent), then run
            // the new sibling subtask under that parent.
            suspendLeaf()   // pre-empt → to the front (runs next)
            startSubtaskUnderLeaf(reason: "preempt", seconds: newSeconds, focus: newFocus,
                                  resumeId: resumeId, openStart: newOpenStart)
        } else {
            if preempting { suspendStack(toFront: true) }   // pre-empt whole stack → front
            beginSession(reason: preempting ? "preempt" : "manual", seconds: newSeconds, focus: newFocus,
                         resumeTaskId: resumeId, openSecondsStart: newOpenStart)
        }
        if resumeId == nil { applyTags(newTags, toNewTask: taskId) }   // tags for a freshly-typed focus
        if preempting { db.recordPreempt(preemptedSessionId: preemptedInterval, newSessionId: intervalId) }
    }

    // Insert a new focus at the FRONT of the queue — it jumps ahead of whatever
    // was queued next, without disturbing the running session. Records a pre-empt
    // (both ids NULL: nothing interrupted, nothing started yet — just a queue jump).
    @objc func preemptNextFocus() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        let entries = MultiFocusPrompt(
            title: "Add to front",
            info: "These go to the front of the queue — before whatever's queued next. Click + to add another.",
            confirm: "Add to front",
            defaultTags: defaultNewTaskTags().joined(separator: ", ")).run() ?? []
        guard !entries.isEmpty else { return }
        // Insert as a block preserving order: enqueue in reverse (each to the front) so
        // row 1 ends up frontmost.
        for e in entries.reversed() {
            applyTags(e.tags, toNewTask: db.enqueueTask(focus: e.focus, estimateSeconds: e.seconds, front: true))
        }
        db.recordPreempt(preemptedSessionId: nil, newSessionId: nil)
    }

    // Quit — but strict mode won't let you bail: no quitting until you turn it off
    // (Force Quit still works). Routed through here (not NSApp.terminate directly) so
    // the menu items grey out and Cmd-Q is caught too.
    @objc func quitFocus() {
        guard !strictModeEnabled else { return }
        NSApp.terminate(nil)
    }

    // Backstop for any other terminate path (Cmd-Q, dock, programmatic): cancel it
    // while strict mode is on.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        return strictModeEnabled ? .terminateCancel : .terminateNow
    }

    // Toggle the floating corner pill on/off (persisted). The menu-bar icon and
    // all timing/logging are unaffected — only the pill is suppressed.
    @objc func toggleShowPill() {
        showPillEnabled.toggle()
        tick()   // apply immediately: re-show or hide the pill
    }

    private enum AddTimeMode { case complete, spent, setSpent }

    // Wired only while the Add/remove-time prompt is up, so the radios can reset the field's
    // default (0 for "set spent to", 5 for the add/remove modes).
    private weak var addTimeField: NSTextField?
    private weak var addTimeSetSpentRadio: NSButton?

    // "Add/remove time" — one prompt, three modes (radio): add/subtract time *to complete*
    // (grows the estimate → more remaining, the default), add/subtract time *already spent*
    // (logs work → remaining shrinks), or *set* the total spent to an absolute value.
    @objc func addTimeToCurrent() {
        guard !showing, taskId != nil else { return }
        showing = true
        defer { showing = false }
        guard let (mode, seconds) = askAddTime() else { return }
        switch mode {
        case .complete:
            extendSession(by: seconds); extendAncestorsToCoverLeaf()
        case .spent:
            if !applySpentDelta(seconds) { showSpentFloorError() }
        case .setSpent:
            // Set the total spent directly to the target (re-syncs both spent clocks).
            if !setSpentTo(seconds) { showSpentFloorError(setMode: true) }
        }
    }

    // Reset the field to the newly-selected mode's default when a radio is clicked.
    @objc private func addTimeModeChanged(_ sender: NSButton) {
        addTimeField?.stringValue = (sender === addTimeSetSpentRadio) ? "0" : "5"
    }

    /// The merged "Add/remove time" prompt: a mode radio (to complete / already spent / set
    /// spent) over a duration field. Returns (mode, seconds), or nil if cancelled. Loops
    /// until the duration parses. Set-spent takes a non-negative value; the others are
    /// signed (negative to subtract).
    private func askAddTime() -> (mode: AddTimeMode, seconds: Int)? {
        let toComplete = NSButton(radioButtonWithTitle: "Add/subtract time to complete", target: self, action: #selector(addTimeModeChanged(_:)))
        let alreadySpent = NSButton(radioButtonWithTitle: "Add/subtract time already spent", target: self, action: #selector(addTimeModeChanged(_:)))
        let setSpent = NSButton(radioButtonWithTitle: "Set time spent to", target: self, action: #selector(addTimeModeChanged(_:)))
        toComplete.state = .on   // default
        toComplete.frame = NSRect(x: 0, y: 88, width: 260, height: 20)
        alreadySpent.frame = NSRect(x: 0, y: 64, width: 260, height: 20)
        setSpent.frame = NSRect(x: 0, y: 40, width: 260, height: 20)
        let field = NSTextField(frame: NSRect(x: 0, y: 4, width: 200, height: 24))
        field.placeholderString = "e.g. 15, 1:30, or -5"
        field.stringValue = "5"   // default for the add/remove modes
        addTimeField = field
        addTimeSetSpentRadio = setSpent
        defer { addTimeField = nil; addTimeSetSpentRadio = nil }
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 112))
        for v in [toComplete, alreadySpent, setSpent, field] { accessory.addSubview(v) }
        while true {
            let alert = makeAlert()
            alert.messageText = "Add/remove time"
            alert.informativeText = "Minutes (e.g. 15) or M:SS (e.g. 1:30); negative to subtract."
            alert.addButton(withTitle: "OK")       // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn
            alert.accessoryView = accessory
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertSecondButtonReturn { return nil }
            let mode: AddTimeMode = setSpent.state == .on ? .setSpent
                                  : (alreadySpent.state == .on ? .spent : .complete)
            if mode == .setSpent {
                // Absolute total; 0 is valid, negative is not.
                if let secs = parseDurationSeconds(field.stringValue), secs >= 0 { return (mode, secs) }
            } else if let secs = parseSignedDuration(field.stringValue) {
                return (mode, secs)
            }
        }
    }

    /// Grow (or shrink) the time recorded against the current open interval by `delta`
    /// seconds, by moving the interval's start earlier (durably, in the DB too, so it
    /// survives a restart); remaining shifts to match, since the estimate is unchanged.
    /// The current interval can't go below zero spent, so a subtraction larger than it holds
    /// is REJECTED (returns false without changing anything) rather than silently clamped —
    /// the caller reports the error. Returns true on success (including a no-op zero delta).
    @discardableResult
    private func applySpentDelta(_ delta: Int) -> Bool {
        guard let iid = intervalId, let tid = taskId, let start = intervalStart else { return false }
        let newStart = start.addingTimeInterval(Double(-delta))   // earlier for +, later for −
        if newStart > Date() { return false }                     // would drive this interval's spent < 0
        let applied = Int(start.timeIntervalSince(newStart).rounded())   // actual spent-seconds shifted
        guard applied != 0 else { return true }
        intervalStart = newStart
        let iso = isoParser.string(from: newStart)
        db.setIntervalStartedAt(id: iid, iso: iso)
        // Keep creation times consistent: a task — and every ancestor it runs under — can't
        // have been created after work on it now starts. Pull each one back to `newStart`
        // where it currently sits later, so a subtask never predates its parent.
        for t in [db.task(id: tid)].compactMap({ $0 }) + db.ancestorTasks(of: tid) {
            if let created = t.createdAt.flatMap(isoParser.date(from:)), newStart < created {
                db.setTaskCreatedAt(id: t.id, iso: iso)
            }
        }
        deadline = (deadline ?? Date()).addingTimeInterval(Double(-applied))   // remaining −applied
        tick()
        return true
    }

    /// Set the task's TOTAL spent time to `target` seconds (absolute). Unlike applySpentDelta
    /// (a relative shift), this re-derives BOTH the interval clock (`intervalStart`) and the
    /// deadline directly from `target`, so the two never drift — the elapsed-based spent and
    /// the deadline-based "estimate − remaining" both land exactly on `target`. Can't go
    /// below `spentBefore` (time already logged in earlier closed intervals); returns false
    /// then so the caller can explain.
    private func setSpentTo(_ target: Int) -> Bool {
        guard let iid = intervalId, intervalStart != nil else { return false }
        let before = spentBefore ?? 0
        guard target >= before else { return false }   // can't erase earlier sessions' time
        let ref = pausedAt ?? Date()                    // "now", frozen while paused
        let pausesClosed = db.totalPausedSeconds(sessionId: iid)
        // Want elapsedFocusSeconds() == target − before, i.e. ref − start − pausesClosed ==
        // target − before  →  start = ref − pausesClosed − (target − before).
        let newStart = ref.addingTimeInterval(-Double(pausesClosed + (target - before)))
        intervalStart = newStart
        let iso = isoParser.string(from: newStart)
        db.setIntervalStartedAt(id: iid, iso: iso)
        if let tid = taskId {   // keep created_at ≤ the (possibly earlier) interval start
            for t in [db.task(id: tid)].compactMap({ $0 }) + db.ancestorTasks(of: tid) {
                if let created = t.createdAt.flatMap(isoParser.date(from:)), newStart < created {
                    db.setTaskCreatedAt(id: t.id, iso: iso)
                }
            }
        }
        // remaining = estimate − target  →  deadline = ref + (estimate − target).
        deadline = ref.addingTimeInterval(Double((estimateSeconds ?? 0) - target))
        tick()
        return true
    }

    /// Explain why a spent-time reduction was rejected (would push spent below 0 / below the
    /// time already logged in this task's earlier sessions).
    private func showSpentFloorError(setMode: Bool = false) {
        let floor = spentBefore ?? 0
        // Advise per mode: "set" wants a minimum value; subtract wants a smaller reduction.
        let advice = setMode
            ? (floor > 0 ? "Enter a value of at least \(mmss(floor))." : "Enter 0 or more.")
            : "Enter a smaller reduction."
        let alert = makeAlert()
        alert.messageText = "Can't reduce time spent that far"
        alert.informativeText = (floor > 0
            ? "Time spent can't go below the \(mmss(floor)) already recorded in earlier sessions of this task. "
            : "Time spent can't go below zero. ") + advice
        alert.addButton(withTitle: "OK")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        _ = runFloatingAlert(alert)
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
        if pausedAt != nil {
            resumeStackIfPaused()   // shift every level's deadline, close each pause row
        } else {
            guard allowPauseEnabled else { return }   // pausing disabled in Settings
            // Optionally require a reason before pausing (cancel → don't pause).
            var reason: String? = nil
            if askPauseReasonEnabled {
                showing = true
                let r = promptPauseReason()
                showing = false
                guard let r = r else { return }   // cancelled → stay running
                reason = r
            }
            // Pause: freeze the whole stack. tick() stops all countdowns while paused.
            pausedAt = Date()
            db.startPause(sessionId: id, at: pausedAt!, reason: reason)
            for f in ancestors { db.startPause(sessionId: f.intervalId, at: pausedAt!, reason: reason) }
        }
        tick()   // repaint the pill (running ⇄ paused)
    }

    /// Ask for a required non-empty reason before pausing. Loops until non-empty; returns
    /// nil if cancelled (don't pause).
    private func promptPauseReason() -> String? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "e.g. meeting, break, interrupted…"
        while true {
            let alert = makeAlert()
            alert.messageText = "Pausing — what's the reason?"
            alert.informativeText = "Enter why you're pausing."
            alert.addButton(withTitle: "Pause")    // 0
            alert.addButton(withTitle: "Cancel")   // 1
            alert.accessoryView = field
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            if runFloatingAlert(alert, firstResponder: field) == 1 { return nil }
            let r = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !r.isEmpty { return r }   // require non-empty → otherwise loop
        }
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

    /// If the stack is paused, resume the WHOLE stack: shift every level's deadline
    /// forward by the pause and close every level's pause row. Called before any action
    /// taken mid-pause (end paths, suspend, add subtask) so nothing is left dangling and
    /// no level's time is mis-counted. No-op when running.
    private func resumeStackIfPaused() {
        guard let p = pausedAt else { return }
        let paused = max(0, Int(Date().timeIntervalSince(p).rounded()))
        if let id = intervalId {
            deadline = deadline?.addingTimeInterval(Double(paused))
            db.endPause(sessionId: id, seconds: paused)
        }
        for i in ancestors.indices {
            ancestors[i].deadline = ancestors[i].deadline.addingTimeInterval(Double(paused))
            db.endPause(sessionId: ancestors[i].intervalId, seconds: paused)
        }
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
        if hadParent { tick() } else { advanceAfterSession() }
    }

    // Abort the current task: rate it, mark interrupted (recording elapsed),
    // then advance to the next (queued or improvised).
    @objc func abortTask() {
        guard !showing, !strictModeEnabled,
              taskId != nil, intervalId != nil, let focus = currentFocus else { return }
        showing = true
        // Detach (returns to the parent, which keeps ticking behind the rating), then rate
        // and mark interrupted (recording the elapsed time).
        let d = detachLeafForFinish()
        let (rating, note, openSeconds, applyTime) = promptRating(focus: "\(focus) · \(mmss(d.elapsed))", title: "Rate this session")
        commitFinish(d, status: "interrupted", rating: rating, note: note, popup: (openSeconds, applyTime))
        showing = false
        if d.hadParent { tick() } else { advanceAfterSession() }
    }

    // Stop working on the current task without finishing it: suspend it (re-queued to
    // the END of the queue so it's resumable) and go idle — or, for a subtask, drop to
    // the still-ticking parent. No rating (it isn't done), unlike Abort.
    @objc func stopWorking() {
        guard !showing, taskId != nil else { return }
        // Strict mode → locked to the committed task; only a deeper subtask can be stopped.
        // Otherwise → a subtask drops to the parent (always ok); a top-level stop needs
        // pausing on. Force the subtask scope when the whole-stack option isn't reachable
        // (pausing off, or strict — where the whole stack includes the commitment).
        if strictModeEnabled {
            guard !lockedToCommitment else { return }
        } else {
            guard !ancestors.isEmpty || allowPauseEnabled else { return }
        }
        showing = true
        defer { showing = false }
        let (proceed, subtaskOnly) = promptStopScope(forceSubtaskOnly: !allowPauseEnabled || strictModeEnabled)
        guard proceed else { return }
        // Stop working parks the task at the END of the queue (not the front).
        if subtaskOnly { suspendLeaf(toFront: false) } else { suspendStack(toFront: false) }
        tick()   // subtask → shows the parent; whole task → hides the pill (idle)
    }

    /// Confirm "Stop working?" — when nested, a checkbox picks "just this subtask"
    /// (drop to the parent) vs the whole task (go idle). Returns (proceed, subtaskOnly).
    private func promptStopScope(forceSubtaskOnly: Bool = false) -> (proceed: Bool, subtaskOnly: Bool) {
        let nested = !ancestors.isEmpty
        let alert = makeAlert()
        alert.messageText = "Stop working?"
        alert.informativeText = nested
            ? "It goes to the end of the queue so you can resume it later."
            : "\(currentFocus ?? "This task") goes to the end of the queue so you can resume it later."
        // The scope checkbox is only offered when both scopes are available. With pausing
        // off (forceSubtaskOnly), the whole-task option is suppressed — subtask scope only.
        var box: NSButton? = nil
        if nested && !forceSubtaskOnly {
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
        let proceed = runFloatingAlert(alert) == 0
        return (proceed, forceSubtaskOnly ? true : (box?.state == .on))
    }

    // Menu actions that are guarded by `showing` (they open their own prompt), so
    // they do nothing while another prompt is already up — disabled in that case.
    private static let showingBlockedActions: Set<Selector> = [
        #selector(addNextFocus), #selector(completeTask), #selector(abortTask),
        #selector(addTimeToCurrent), #selector(changeFocus), #selector(addSubtask),
        #selector(stopWorking), #selector(switchToSubtask), #selector(renameTask), #selector(togglePause), #selector(preemptNextFocus),
        #selector(clearQueue), #selector(rateUnrated),   // showSettings handled explicitly (see validateMenuItem)
        #selector(deleteHistoryItems), #selector(abandonHistoryTask),
        #selector(resumeHistoryTask), #selector(addHistoryTaskToQueue), #selector(editHistoryTaskTags),
        #selector(workOnQueueItemNow), #selector(deleteQueuedTaskPermanently), #selector(editQueueItemTags),
        #selector(completeQueueItem),
    ]

    // Per-row queue mutations (right-click / Delete key) — frozen in strict mode.
    private static let queueEditActions: Set<Selector> = [
        #selector(moveQueueItemUp), #selector(moveQueueItemDown),
        #selector(moveQueueItemToTop), #selector(moveQueueItemToBottom),
        #selector(deleteClickedQueueItem), #selector(deleteQueuedTaskPermanently),
        #selector(completeQueueItem),
    ]

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // While a prompt is open, actions that would spawn another prompt are guarded
        // by `showing` and would silently no-op — disable them so the menu shows that.
        // (See history / See queue / Show current task / Quit still work.)
        if showing, let action = menuItem.action, Self.showingBlockedActions.contains(action) {
            return false
        }
        // "Switch to subtask" needs a running task with at least one resumable (never-
        // finished) subtask — whether it's parked in the queue or just exists unqueued.
        if menuItem.action == #selector(switchToSubtask) {
            guard let leaf = taskId else { return false }
            return !resumableSubtasks(of: leaf).isEmpty
        }
        // Complete / Abort / Stop / Rename / Add time / Add subtask act on a running session.
        if menuItem.action == #selector(completeTask)
            || menuItem.action == #selector(addTimeToCurrent) || menuItem.action == #selector(addSubtask)
            || menuItem.action == #selector(renameTask) {
            return currentFocus != nil
        }
        // Strict mode: the only way off the current task is to complete it — no aborting.
        if menuItem.action == #selector(abortTask) {
            return currentFocus != nil && !strictModeEnabled
        }
        // Stop working:
        //  • Strict mode → locked to the committed task: you can't stop it (top-level or
        //    subtask), but a deeper subtask you created below it can be stopped (drops
        //    back toward the commitment).
        //  • Otherwise → a subtask drops to the still-running parent (always allowed); a
        //    top-level task is a heavy pause, so it needs pausing enabled.
        if menuItem.action == #selector(stopWorking) {
            guard currentFocus != nil else { return false }
            if strictModeEnabled { return !lockedToCommitment }
            return !ancestors.isEmpty || allowPauseEnabled
        }
        if menuItem.action == #selector(togglePause) {
            menuItem.title = pausedAt != nil ? "Resume" : "Pause"
            // No task → disabled. Pausing disallowed → can't Pause, but can still Resume
            // an already-paused task (e.g. one restored paused after a quit).
            return currentFocus != nil && (allowPauseEnabled || pausedAt != nil)
        }
        if menuItem.action == #selector(deleteHistoryItems) {
            return !historyTargetNodes().isEmpty
        }
        if menuItem.action == #selector(abandonHistoryTask) {
            // Only meaningful on an in-progress (unfinished) task; never in strict mode
            // (giving up is a way off a task the queue committed you to).
            return !strictModeEnabled && historyTargetNodes().contains { $0.task.map { $0.endedAt == nil } ?? false }
        }
        // Resume/queue a task from history — task rows only, and never in strict mode.
        if menuItem.action == #selector(resumeHistoryTask) {
            return !strictModeEnabled && historyTargetNodes().compactMap { $0.task }.count == 1
        }
        if menuItem.action == #selector(addHistoryTaskToQueue) {
            return !strictModeEnabled && historyTargetNodes().contains { $0.task != nil }
        }
        if menuItem.action == #selector(editHistoryTaskTags) {
            return !historyTargetNodes().compactMap { $0.task }.isEmpty   // one or more task rows
        }
        if menuItem.action == #selector(toggleShowPill) {
            menuItem.state = showPillEnabled ? .on : .off
            return true
        }
        if menuItem.action == #selector(changeFocus) {
            menuItem.title = currentFocus != nil ? "Switch focus now" : "Set focus"
            // Strict mode: no switching away from the running task. (Idle "Set focus"
            // stays enabled — it routes through the strict, front-of-queue chooser.)
            if strictModeEnabled && currentFocus != nil { return false }
        }
        // Strict mode: "Add to front" jumps the queue order → disabled.
        if menuItem.action == #selector(preemptNextFocus) && strictModeEnabled {
            return false
        }
        // Strict mode: no bailing out — "Quit focus" is disabled until you turn it off.
        if menuItem.action == #selector(quitFocus) {
            return !strictModeEnabled
        }
        // Settings can be temporarily locked → disabled, with the countdown in its title
        // (the only place the remaining time is shown).
        if menuItem.action == #selector(showSettings) {
            if let remaining = settingsLockRemaining() {
                menuItem.title = "Settings (locked for \(mmss(remaining)))"
                return false
            }
            menuItem.title = "Settings"
            // Blocked while another prompt is up — except the non-app-modal "Ready to
            // focus?" chooser, over which Settings can be opened.
            return !showing || nextFocusOpen
        }
        if menuItem.action == #selector(showHistory) {
            menuItem.title = "See history (\(db.taskCount()))"
        }
        if menuItem.action == #selector(showQueue) {
            menuItem.title = "See queue (\(db.queueCount()))"
        }
        if menuItem.action == #selector(clearQueue) {
            // Strict mode: you can't wipe the plan you're required to follow.
            return db.queueCount() > 0 && !strictModeEnabled
        }
        if menuItem.action == #selector(rateUnrated) {
            let n = db.unratedTaskCount()
            menuItem.title = "Rate unrated sessions (\(n))"
            return n > 0
        }
        // Strict mode: the queue is frozen — no reordering or dropping individual items.
        if strictModeEnabled, let a = menuItem.action, Self.queueEditActions.contains(a) {
            return false
        }
        // Queue right-click move items: enable based on the clicked row's position.
        // Reordering works within the filtered view too (moves relative to visible rows,
        // leaving hidden ones in place). Strict mode still freezes it (queueEditActions).
        if menuItem.action == #selector(moveQueueItemUp) || menuItem.action == #selector(moveQueueItemToTop) {
            let r = queueTable?.clickedRow ?? -1
            return r > 0
        }
        if menuItem.action == #selector(moveQueueItemDown) || menuItem.action == #selector(moveQueueItemToBottom) {
            let r = queueTable?.clickedRow ?? -1
            return r >= 0 && r < queueRows.count - 1
        }
        if menuItem.action == #selector(deleteClickedQueueItem) || menuItem.action == #selector(completeQueueItem) {
            let r = queueTable?.clickedRow ?? -1
            return r >= 0 && r < queueRows.count   // (queueEditActions already froze these in strict mode)
        }
        // "Work on now": a valid clicked row, and not in strict mode (out-of-turn start).
        if menuItem.action == #selector(workOnQueueItemNow) {
            let r = queueTable?.clickedRow ?? -1
            return !strictModeEnabled && r >= 0 && r < queueRows.count
        }
        // "Edit tags…" (queue): any valid clicked row — allowed even in strict mode (tags
        // don't affect queue order).
        if menuItem.action == #selector(editQueueItemTags) {
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
        // Batch-add: each row (top-to-bottom) is appended in order.
        let entries = MultiFocusPrompt(
            title: "Add to queue",
            info: "Queue one or more focuses to run after the current one. Click + to add another.",
            confirm: "Add to queue",
            defaultTags: defaultNewTaskTags().joined(separator: ", ")).run() ?? []
        for e in entries {
            applyTags(e.tags, toNewTask: db.enqueueTask(focus: e.focus, estimateSeconds: e.seconds))
        }
    }

    /// A top-level task just finished. Normally roll on to the next focus — but in
    /// "One task only, then touch grass" mode, that finished task was the whole plan:
    /// congratulate, then lock the screen instead of prompting for another.
    private func advanceAfterSession() {
        if oneTaskOnlyEnabled { touchGrassAndLock() }
        else { promptNextFocus(startReason: "after-session") }
    }

    /// The "touch grass" send-off: a single-button modal, then lock the screen.
    private func touchGrassAndLock() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        NSApp.activate(ignoringOtherApps: true)
        hudWindow.orderOut(nil)   // hide the pill behind the send-off
        let alert = makeAlert()
        alert.messageText = "That was the one thing you were going to do!"
        alert.informativeText = "See you later — have fun in the actual world. 🌱"
        alert.addButton(withTitle: "OK")

        // 60s countdown → auto-clicks OK (locking the screen) if you don't first.
        let label = NSTextField(labelWithString: "")
        label.frame = NSRect(x: 0, y: 0, width: 340, height: 18)
        label.alignment = .center
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        alert.accessoryView = label
        var remaining = 60
        label.stringValue = "Locking the screen in \(remaining) seconds."
        // .common mode so it fires while the panel is up; panelResult = 0 ends the pump
        // exactly as an "OK" click would.
        let timer = Timer(timeInterval: 1, repeats: true) { t in
            remaining -= 1
            if remaining <= 0 {
                t.invalidate()
                self.panelResult = 0
            } else {
                label.stringValue = "Locking the screen in \(remaining) second\(remaining == 1 ? "" : "s")."
            }
        }
        RunLoop.main.add(timer, forMode: .common)

        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        _ = runFloatingAlert(alert)   // OK click or countdown — either way, lock
        timer.invalidate()
        lockScreen()
    }

    /// Bring the Mac to its Lock Screen. Uses login.framework's
    /// `SACLockScreenImmediate` (the same call the system's own Lock Screen uses);
    /// if that can't be resolved, falls back to sleeping the display, which locks
    /// when "require password after sleep" is set.
    private func lockScreen() {
        let path = "/System/Library/PrivateFrameworks/login.framework/Versions/Current/login"
        if let handle = dlopen(path, RTLD_NOW), let sym = dlsym(handle, "SACLockScreenImmediate") {
            typealias LockFn = @convention(c) () -> Int32
            _ = unsafeBitCast(sym, to: LockFn.self)()
            dlclose(handle)
            return
        }
        // Fallback: sleep the display.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["displaysleepnow"]
        try? p.run()
    }

    private enum NextOutcome { case started, closed, retry }

    /// The next-focus confirm for the front queued item: Start it, start a different
    /// (ad-hoc) focus, pick another queued item, or Close (go idle). Auto-proceeds after a
    /// 10s countdown when that preference is on. Strict mode shows Start only — no
    /// switching, no Close. Returns what happened so the caller can loop (retry) or stop.
    private func confirmQueued(_ item: QueueItem) -> NextOutcome {
        let confirmOpenedAt = Date()   // how long this confirm stays up → the queued session's open_seconds_start
        let alert = makeAlert()
        alert.messageText = "Ready to focus?"
        alert.informativeText = "Next up: \(queueDisplayName(item))\n\n\(mmss(item.seconds))"
        alert.addButton(withTitle: "Start")             // 0
        // Front task is the only option — no switching to a new or different queued focus,
        // and no closing — under strict mode OR auto-proceed (which is meant to roll on
        // hands-free). Otherwise offer the alternatives + Close.
        let proceedOnly = strictModeEnabled || autoProceedEnabled
        var differentIndex = -1, pickIndex = -1, closeIndex = -1
        if !proceedOnly {
            alert.addButton(withTitle: "Start a new focus"); differentIndex = alert.buttons.count - 1
            let pickButton = alert.addButton(withTitle: "Pick another queued focus…"); pickIndex = alert.buttons.count - 1
            pickButton.isEnabled = db.queueCount() > 1   // disabled when there's no other queued item
            alert.addButton(withTitle: "Close"); closeIndex = alert.buttons.count - 1
        }

        var autoTimer: Timer?
        var elapsedTimer: Timer?
        if autoProceedEnabled {
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
        let response = runFloatingAlert(alert)
        autoTimer?.invalidate()
        elapsedTimer?.invalidate()

        if nextFocusNeedsRerender { return .retry }    // Settings changed → rebuild
        if response == closeIndex { return .closed }   // go idle
        if response == differentIndex {
            // Start a different focus: leave the queued item where it is (still the front,
            // since we never removed it) and run an ad-hoc focus right now instead.
            if case let .entered(focus, seconds, openStart, tags) = askFocusAndMinutes(
                title: "Start a new focus",
                info: "This runs now; the queued focus stays next in line.",
                confirm: "Start", cancellable: true) {
                beginSession(reason: "preempt", seconds: seconds, focus: focus, openSecondsStart: openStart)
                applyTags(tags, toNewTask: taskId)
                // Nothing was underway → preempted_session_id is NULL.
                db.recordPreempt(preemptedSessionId: nil, newSessionId: intervalId)
                return .started
            }
            return .retry   // cancelled → back to the chooser
        }
        if response == pickIndex {
            // Pick another queued focus: start the chosen one now instead of the front
            // (which stays queued). Same as a normal front-fetch, just for the chosen item.
            if let chosen = pickFromQueue() {
                db.removeFromQueue(id: chosen.id)
                let openStart = Int(Date().timeIntervalSince(confirmOpenedAt).rounded())
                beginSession(reason: "queue", seconds: chosen.seconds, focus: chosen.focus,
                             resumeTaskId: chosen.taskId, openSecondsStart: openStart)
                db.recordPreempt(preemptedSessionId: nil, newSessionId: intervalId)
                return .started
            }
            return .retry   // cancelled the picker → back to the chooser
        }

        // Start (0), or the auto-proceed countdown fired → start the front item. If it's a
        // subtask whose completed parent(s) would be re-opened, confirm first.
        if let tid = item.taskId, !confirmReopenAncestors(of: tid) { return .retry }
        db.removeFromQueue(id: item.id)
        let queuedOpenStart = Int(Date().timeIntervalSince(confirmOpenedAt).rounded())
        beginSession(reason: "queue", seconds: item.seconds, focus: item.focus,
                     resumeTaskId: item.taskId, openSecondsStart: queuedOpenStart)
        return .started
    }

    /// Display name for a queued item: for a set-aside subtask, prefix its ancestor
    /// chain — "Root › … › Parent › this". Fresh or top-level items show just the focus.
    private func queueDisplayName(_ item: QueueItem) -> String {
        guard let tid = item.taskId else { return item.focus }
        let ancestors = db.ancestorTasks(of: tid)   // [parent, …, root]
        guard !ancestors.isEmpty else { return item.focus }
        return (ancestors.reversed().map { $0.focus } + [item.focus]).joined(separator: " › ")
    }

    /// Show a "See Queue"-style picker (in a floating modal) of all queued focuses,
    /// with the same Est. start/finish schedule. Returns the one the user clicks,
    /// or nil if they cancel.
    private func pickFromQueue(filter: ((QueueItem) -> Bool)? = nil, showParentChain: Bool = true) -> QueueItem? {
        // Default: honor the active queue tag filter (only eligible items are pickable).
        // A caller can pass its own predicate (e.g. subtask siblings) to override.
        let byTask = db.tagNamesByTask()
        let predicate = filter ?? { self.matchesQueueFilter($0, tagsByTask: byTask) }
        let items = db.queueItems().filter(predicate)
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
                                     finish: localClockFormatter.string(from: finish),
                                     focusDisplay: showParentChain ? queueDisplayName(item) : item.focus))
        }

        var chosen: QueueItem?
        let source = QueuePickSource(rows: rows) { item in
            chosen = item
            NSApp.stopModal()
        }
        runPickerWindow(title: "Pick another queued focus",
                        info: "Click a queued focus to start it now (it's removed from the queue; the others stay).",
                        table: source.makeTable())
        return chosen
    }

    /// Show `table` in a resizable floating modal (NSAlert can't resize) with an info
    /// line and a Cancel/Esc button. The table's row-click action should call
    /// NSApp.stopModal(); this returns once the modal ends (pick, Cancel, or Esc).
    private func runPickerWindow(title: String, info infoText: String, table: NSTableView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 380),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let content = window.contentView!

        let info = NSTextField(wrappingLabelWithString: infoText)
        info.frame = NSRect(x: 16, y: content.bounds.height - 44, width: content.bounds.width - 32, height: 34)
        info.autoresizingMask = [.width, .minYMargin]

        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelPickModal))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"   // Esc
        cancel.frame = NSRect(x: content.bounds.width - 96, y: 12, width: 80, height: 28)
        cancel.autoresizingMask = [.minXMargin, .maxYMargin]

        let scroll = NSScrollView(frame: NSRect(x: 16, y: 52, width: content.bounds.width - 32,
                                                height: content.bounds.height - 52 - 52))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .bezelBorder
        scroll.autoresizingMask = [.width, .height]

        content.addSubview(info)
        content.addSubview(scroll)
        content.addSubview(cancel)

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: window)   // row click / Cancel / Esc → stopModal
        window.orderOut(nil)
    }

    @objc private func cancelPickModal() { NSApp.stopModal() }

    private enum FocusEntry {
        case entered(focus: String, seconds: Int, openSeconds: Int, tags: [String])
        case queuePick            // user chose to pick an existing queued focus instead
        case cancelled
    }

    /// Tags a freshly-created task should default to — the active queue filter's tags, so a
    /// new task shows up under the filter you're working within. Empty when no filter.
    private func defaultNewTaskTags() -> [String] { queueFilterTags }

    /// Split a comma-separated tags field into trimmed, non-empty names.
    private func parseTagList(_ s: String) -> [String] {
        s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Set a freshly-created task's tags (no-op for an empty list or nil id).
    private func applyTags(_ names: [String], toNewTask taskId: Int64?) {
        guard let tid = taskId, !names.isEmpty else { return }
        db.setTags(taskId: tid, names: names)
    }

    /// Editable "focus + minutes" modal. The field takes whole minutes, or a
    /// "M:SS" value (e.g. "2:30" → 150s) if a colon is present; the returned
    /// duration is in seconds. Loops until valid. With `queuePick` (and a non-empty
    /// queue) it also offers a "Pick from queue…" button → `.queuePick`.
    private func askFocusAndMinutes(title: String, info: String, confirm: String,
                                    cancellable: Bool, queuePick: Bool = false,
                                    extraTop: NSView? = nil) -> FocusEntry {
        NSApp.activate(ignoringOtherApps: true)

        let focusField = NSTextField(frame: NSRect(x: 0, y: 64, width: 320, height: 24))
        focusField.placeholderString = "e.g. \(randomFocusSuggestion())"

        let tagsLabel = NSTextField(labelWithString: "Tags:")
        tagsLabel.frame = NSRect(x: 0, y: 34, width: 44, height: 24)
        let tagsField = NSTextField(frame: NSRect(x: 48, y: 34, width: 272, height: 24))
        tagsField.placeholderString = "comma-separated (optional)"
        tagsField.stringValue = defaultNewTaskTags().joined(separator: ", ")

        let minutesLabel = NSTextField(labelWithString: "Minutes:")
        minutesLabel.frame = NSRect(x: 0, y: 2, width: 60, height: 24)
        let minutesField = NSTextField(frame: NSRect(x: 62, y: 2, width: 70, height: 24))
        minutesField.stringValue = String(defaultMinutes)

        let elapsed = NSTextField(labelWithString: "")
        elapsed.frame = NSRect(x: 0, y: 92, width: 320, height: 18)
        elapsed.font = NSFont.systemFont(ofSize: 11)
        elapsed.textColor = .secondaryLabelColor

        let baseH: CGFloat = 114
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: baseH))
        accessory.addSubview(focusField)
        accessory.addSubview(tagsLabel)
        accessory.addSubview(tagsField)
        accessory.addSubview(minutesLabel)
        accessory.addSubview(minutesField)
        accessory.addSubview(elapsed)
        if let extra = extraTop {   // e.g. the Switch-mode radio group — sits on top
            // Grow the accessory (and stretch the fields) to fit the widest extra
            // content — otherwise wide radio/checkbox labels clip at the panel edge.
            let w = max(accessory.frame.width, extra.frame.width)
            focusField.setFrameSize(NSSize(width: w, height: focusField.frame.height))
            tagsField.setFrameSize(NSSize(width: w - 48, height: tagsField.frame.height))
            elapsed.setFrameSize(NSSize(width: w, height: elapsed.frame.height))
            extra.setFrameOrigin(NSPoint(x: 0, y: baseH + 6))
            accessory.setFrameSize(NSSize(width: w, height: baseH + 6 + extra.frame.height))
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

            // Settings (opened over the "Ready to focus?" chooser) changed → bail so the
            // caller can rebuild. Only ever set while that chooser is up.
            if nextFocusNeedsRerender { return .cancelled }
            if clicked == cancelIndex { return .cancelled }
            if clicked == queueIndex { return .queuePick }

            let answer = focusField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let seconds = parseDurationSeconds(minutesField.stringValue) ?? 0
            if !answer.isEmpty && seconds > 0 {
                return .entered(focus: answer, seconds: seconds, openSeconds: openSeconds(),
                                tags: parseTagList(tagsField.stringValue))
            }
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
                    // An ancestor whose clock is ticking again can't be "completed" — reopen
                    // its status so a finished parent doesn't stay marked done while running.
                    db.reopenTask(id: a.id)
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
        // A *primary* start (fresh top-level, or a queue-resume that rebuilds the stack)
        // is a new commitment; a subtask push (parentTaskId set, or a switch attaching
        // under a live parent) keeps the existing commitment.
        let isPrimaryStart = (resumeTaskId != nil) ? rebuildAncestors : (parentTaskId == nil)
        if isPrimaryStart { committedTaskId = taskId }
        if pushoverEnabled { sendPushover(title: "Focus started", message: "\(focus) — \(mmss(seconds))") }
        tick()
    }

    // Start a subtask under the current task: push the current leaf onto the ancestor
    // stack (it keeps ticking), then run a fresh child task now.
    @objc func addSubtask() {
        guard !showing, let parent = taskId else { return }
        showing = true
        defer { showing = false }
        guard case let .entered(focus, seconds, openStart, tags) = askFocusAndMinutes(
            title: "Add subtask",
            info: "Runs under the current task. If it's longer than the parent's remaining time, the parent is auto-extended so they finish together.",
            confirm: "Start", cancellable: true) else { return }
        resumeStackIfPaused()   // if paused, cleanly resume the stack before pushing
        // Push the parent and start the fresh subtask under it (auto-extends ancestors
        // to cover it, so they finish together).
        _ = parent
        startSubtaskUnderLeaf(reason: "subtask", seconds: seconds, focus: focus,
                              resumeId: nil, openStart: openStart)
        applyTags(tags, toNewTask: taskId)   // the new subtask is now the leaf
    }

    // Resume an existing set-aside subtask of the current task: pick one from the
    // queue (filtered to children of the current leaf) and run it under the current
    // task, which keeps ticking. The counterpart of Add subtask — existing vs new.
    @objc func switchToSubtask() {
        guard !showing, let leaf = taskId else { return }
        showing = true
        defer { showing = false }
        let candidates = resumableSubtasks(of: leaf)
        guard !candidates.isEmpty else { return }
        let rows = candidates.map { SubtaskPickRow(choice: $0, duration: mmss($0.remaining)) }
        var chosen: SubtaskChoice?
        let source = SubtaskPickSource(rows: rows) { c in chosen = c; NSApp.stopModal() }
        runPickerWindow(title: "Switch to subtask",
                        info: "Pick a subtask to work on now — it runs under the current task. Grayed rows aren't in the queue.",
                        table: source.makeTable())
        guard let pick = chosen else { return }
        if let rowId = pick.queueRowId { db.removeFromQueue(id: rowId) }   // no-op for non-queued ones
        resumeStackIfPaused()
        startSubtaskUnderLeaf(reason: "subtask", seconds: max(1, pick.remaining), focus: pick.focus,
                              resumeId: pick.taskId, openStart: nil)
    }

    /// Non-terminal children of `leaf` (status nil = never finished) that you can switch
    /// to: queued ones first (in queue order), then ones that exist but aren't queued
    /// (e.g. removed from the queue), which the picker grays out.
    private func resumableSubtasks(of leaf: Int64, excluding: Int64? = nil) -> [SubtaskChoice] {
        var queueRowForTask: [Int64: Int64] = [:]
        var orderForTask: [Int64: Int] = [:]
        for (i, q) in db.queueItems().enumerated() {
            if let t = q.taskId { queueRowForTask[t] = q.id; orderForTask[t] = i }
        }
        let choices = db.childTasks(of: leaf)
            .filter { $0.status == nil && $0.id != excluding }   // never finished; skip the current leaf
            .map { k in
                SubtaskChoice(taskId: k.id, focus: k.focus,
                              remaining: max(0, db.remainingSeconds(taskId: k.id)),
                              queueRowId: queueRowForTask[k.id])
            }
        return choices.sorted { a, b in
            switch (a.queueRowId, b.queueRowId) {
            case (.some, .none): return true                    // queued before non-queued
            case (.none, .some): return false
            case (.some, .some): return (orderForTask[a.taskId] ?? 0) < (orderForTask[b.taskId] ?? 0)
            case (.none, .none): return a.taskId > b.taskId     // non-queued: most recent first
            }
        }
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

            // Nest each task's intervals as dim child rows of the task.
            let ivCheck = NSButton(checkboxWithTitle: "Show intervals", target: self,
                                   action: #selector(historyIntervalsToggled(_:)))
            ivCheck.state = showIntervalsInTree ? .on : .off
            ivCheck.frame = NSRect(x: 12, y: container.bounds.height - 30, width: 140, height: 20)
            ivCheck.autoresizingMask = [.minYMargin, .maxXMargin]   // pin to top-left

            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: container.bounds.width,
                                                    height: container.bounds.height - 40))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true   // let wide columns (Focus/Task/Note) scroll
            scroll.borderType = .noBorder

            let outline = CopyableOutlineView()
            outline.dataSource = self
            outline.delegate = self
            outline.usesAlternatingRowBackgroundColors = true
            // Keep each column's natural width; total can exceed the window and
            // scroll horizontally, so wide columns aren't squeezed.
            outline.columnAutoresizingStyle = .noColumnAutoresizing
            outline.rowHeight = 22
            outline.indentationPerLevel = 14      // subtasks step in under their parent
            outline.allowsColumnResizing = true
            outline.allowsMultipleSelection = true   // Shift/⌘-click to select a range
            outline.style = .inset
            outline.onCopy = { [weak self] indexes in self?.copyHistoryRows(indexes) }
            // Right-click a row (or a selection) to give up / delete it.
            let histMenu = NSMenu()
            histMenu.addItem(withTitle: "Resume task", action: #selector(resumeHistoryTask), keyEquivalent: "")
            histMenu.addItem(withTitle: "Add to queue", action: #selector(addHistoryTaskToQueue), keyEquivalent: "")
            histMenu.addItem(withTitle: "Edit tags…", action: #selector(editHistoryTaskTags), keyEquivalent: "")
            histMenu.addItem(.separator())
            histMenu.addItem(withTitle: "Give up (abandon)", action: #selector(abandonHistoryTask), keyEquivalent: "")
            histMenu.addItem(withTitle: "Delete", action: #selector(deleteHistoryItems), keyEquivalent: "")
            for mi in histMenu.items { mi.target = self }
            outline.menu = histMenu

            scroll.documentView = outline
            container.addSubview(scroll)
            container.addSubview(ivCheck)
            window.contentView = container

            historyWindow = window
            historyOutline = outline
        }

        reloadHistory()
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func historyIntervalsToggled(_ sender: NSButton) {
        showIntervalsInTree = sender.state == .on
        reloadHistory()
    }

    /// Load the task rows, build the node tree, install columns, sort, refresh.
    private func reloadHistory() {
        historyRows = db.taskHistory()
        historyTags = db.tagNamesByTask()
        configureHistoryColumns()
        // Default sort: Ended desc (most-recently-worked, with in-progress on top).
        let current = historyOutline?.sortDescriptors.first?.key
        if current == nil || !historyColumnKeys().contains(current!) {
            historyOutline?.sortDescriptors = [NSSortDescriptor(key: "ended", ascending: false)]
        }
        rebuildHistoryNodes()
        applyHistorySort()
        historyOutline?.reloadData()
        historyOutline?.expandItem(nil, expandChildren: true)   // reveal subtasks
    }

    // Build the outline's root nodes: a task tree (subtasks nested under their parent),
    // optionally with each task's own intervals attached as dim child rows.
    private func rebuildHistoryNodes() {
        var byId: [Int64: HistoryNode] = [:]
        for r in historyRows { byId[r.id] = HistoryNode(task: r) }
        // Optionally attach each task's own intervals as child rows.
        if showIntervalsInTree {
            var ivsByTask: [Int64: [IntervalHistoryRow]] = [:]
            for iv in db.intervalHistory() { ivsByTask[iv.taskId, default: []].append(iv) }
            for (tid, node) in byId {
                for iv in ivsByTask[tid] ?? [] { node.children.append(HistoryNode(interval: iv)) }
            }
        }
        // Nest subtasks under their parent (alongside any interval children).
        var roots: [HistoryNode] = []
        for r in historyRows {
            let node = byId[r.id]!
            if let pid = r.parentTaskId, let parent = byId[pid] { parent.children.append(node) }
            else { roots.append(node) }   // top-level, or orphan whose parent isn't loaded
        }
        historyNodes = roots
    }

    // Sort keys valid for the task columns.
    private func historyColumnKeys() -> Set<String> {
        ["when", "ended", "min", "origmin", "ivs", "rating", "status", "focus", "tags", "note"]
    }

    // Sort the tree: top-level tasks by the clicked column; a task's children
    // (subtasks + any intervals) chronologically by start, so each task reads like a
    // timeline. Without intervals shown, children are subtasks and follow the column.
    private func applyHistorySort() {
        guard let d = historyOutline?.sortDescriptors.first, let key = d.key else { return }
        sortHistoryNodes(&historyNodes, key: key, ascending: d.ascending, top: true)
    }

    private func sortHistoryNodes(_ nodes: inout [HistoryNode], key: String, ascending: Bool, top: Bool) {
        if !top && showIntervalsInTree {
            // Interleave subtasks + intervals chronologically, following the sort direction
            // (descending default → newest at top, matching the Intervals-off column view).
            nodes.sort { ascending ? nodeStart($0) < nodeStart($1) : nodeStart($0) > nodeStart($1) }
        } else {
            nodes.sort { a, b in
                if let ta = a.task, let tb = b.task { return taskLess(ta, tb, key: key, ascending: ascending) }
                return false
            }
        }
        for node in nodes { sortHistoryNodes(&node.children, key: key, ascending: ascending, top: false) }
    }

    private func nodeStart(_ n: HistoryNode) -> String { n.task?.startedAt ?? n.interval?.startedAt ?? "" }

    func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        applyHistorySort()
        outlineView.reloadData()
    }

    private func dir<T: Comparable>(_ a: T, _ b: T, _ ascending: Bool) -> Bool { ascending ? a < b : a > b }

    private func taskLess(_ a: TaskHistoryRow, _ b: TaskHistoryRow, key: String, ascending: Bool) -> Bool {
        switch key {
        case "when":    return dir(a.startedAt ?? "", b.startedAt ?? "", ascending)
        case "ended":
            // Primary: finish time — unfinished (nil Ended) float to the top via the
            // sentinel. Tie-break by start time, so same-ended rows and the all-active
            // group (which all share the sentinel) order by when they began — showing
            // newest first, the most-recently-started leads.
            let ae = a.endedAt ?? "\u{FFFF}", be = b.endedAt ?? "\u{FFFF}"
            return ae == be ? dir(a.startedAt ?? "", b.startedAt ?? "", ascending)
                            : dir(ae, be, ascending)
        case "min":     return dir(a.actualSeconds, b.actualSeconds, ascending)
        case "origmin": return dir(a.originalEstimateSeconds ?? -1, b.originalEstimateSeconds ?? -1, ascending)
        case "ivs":     return dir(a.intervalCount, b.intervalCount, ascending)
        case "rating":  return dir(a.rating ?? -1, b.rating ?? -1, ascending)
        case "status":  return dir(a.status ?? "", b.status ?? "", ascending)
        case "focus":   return dir(a.focus.lowercased(), b.focus.lowercased(), ascending)
        case "tags":    return dir((historyTags[a.id] ?? []).joined(separator: ", ").lowercased(),
                                    (historyTags[b.id] ?? []).joined(separator: ", ").lowercased(), ascending)
        case "note":    return dir(a.note ?? "", b.note ?? "", ascending)
        default:        return dir(a.id, b.id, ascending)
        }
    }

    private func configureHistoryColumns() {
        guard let outline = historyOutline else { return }
        // NSOutlineView refuses to removeTableColumn its current outlineTableColumn (and
        // setting it to nil just snaps back to a real column). So park the outline role
        // on a throwaway placeholder, clear the real columns, rebuild, then drop it.
        let placeholder = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("__ph__"))
        outline.addTableColumn(placeholder)
        outline.outlineTableColumn = placeholder
        for col in outline.tableColumns where col !== placeholder { outline.removeTableColumn(col) }
        var first: NSTableColumn?
        func add(_ id: String, _ title: String, width: CGFloat, min: CGFloat, align: NSTextAlignment = .left) {
            let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            col.title = title; col.width = width; col.minWidth = min; col.headerCell.alignment = align
            col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)   // click header to sort
            outline.addTableColumn(col)
            if first == nil { first = col }
        }
        // Focus is the outline column, so subtasks indent under their parent here.
        add("focus", "Focus", width: 340, min: 180)
        add("when", "Started", width: 140, min: 120)
        add("ended", "Ended", width: 140, min: 120)
        add("min", "Actual", width: 70, min: 56, align: .right)
        add("origmin", "Est (orig)", width: 78, min: 60, align: .right)
        add("ivs", "Intervals", width: 70, min: 56, align: .right)
        add("rating", "Rating", width: 60, min: 50, align: .right)
        add("status", "Status", width: 95, min: 70)
        add("tags", "Tags", width: 160, min: 80)
        add("note", "Note", width: 320, min: 100)
        outline.outlineTableColumn = first   // disclosure triangles + indentation live here
        outline.removeTableColumn(placeholder)   // now safe — no longer the outline column
    }

    // Copy the selected history rows to the clipboard as TSV (with a header).
    private func copyHistoryRows(_ indexes: IndexSet) {
        guard let outline = historyOutline, !indexes.isEmpty else { return }
        let nodes = indexes.compactMap { outline.item(atRow: $0) as? HistoryNode }
        var lines = ["Started\tEnded\tActual (s)\tOrig est (s)\tIntervals\tRating\tStatus\tFocus\tTags\tNote"]
        for node in nodes {
            guard let r = node.task else { continue }
            let indent = String(repeating: "  ", count: outline.level(forItem: node))   // subtask depth
            let fields: [String] = [
                r.startedAt.map(whenLabel) ?? "",
                r.endedAt.map(whenLabel) ?? "",
                "\(r.actualSeconds)",
                r.originalEstimateSeconds.map { "\($0)" } ?? "",
                "\(r.intervalCount)",
                r.rating.map { "\($0)" } ?? "",
                historyStatusLabel(r, placeholder: ""),
                indent + r.focus,
                (historyTags[r.id] ?? []).joined(separator: ", "),
                r.note ?? "",
            ]
            lines.append(fields.map(tsvClean).joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    // Nodes a history right-click acts on: the current selection if the clicked row
    // is part of it, otherwise just the clicked row.
    private func historyTargetNodes() -> [HistoryNode] {
        guard let outline = historyOutline else { return [] }
        let clicked = outline.clickedRow
        let selected = outline.selectedRowIndexes
        let rows: IndexSet
        if clicked >= 0 && selected.contains(clicked) { rows = selected }
        else if clicked >= 0 { rows = IndexSet(integer: clicked) }
        else { rows = selected }
        return rows.compactMap { outline.item(atRow: $0) as? HistoryNode }
    }

    /// Reopen the task's whole chain (itself + any terminal ancestors) so it — and the
    /// parents it runs under — are active again, not stuck "completed".
    private func reopenTaskChain(_ tid: Int64) {
        db.reopenTask(id: tid)
        for a in db.ancestorTasks(of: tid) { db.reopenTask(id: a.id) }
    }

    /// Ancestors of `tid` that are already finished — the ones that would be re-opened by
    /// starting it (nearest first).
    private func finishedAncestors(of tid: Int64) -> [TaskRow] {
        db.ancestorTasks(of: tid).filter { $0.status != nil }
    }

    /// If starting `tid` would re-open finished parent task(s), confirm first. Returns true
    /// to proceed (or when there's nothing to warn about), false if the user cancels.
    private func confirmReopenAncestors(of tid: Int64) -> Bool {
        let finished = finishedAncestors(of: tid)
        guard !finished.isEmpty else { return true }
        let plural = finished.count == 1 ? "" : "s"
        let list = finished.map { "• \($0.focus)" }.joined(separator: "\n")
        let alert = makeAlert()
        alert.messageText = "Re-open completed parent task\(plural)?"
        alert.informativeText = "Working on this subtask will also re-open the following completed task\(plural):\n\n\(list)"
        alert.addButton(withTitle: "Re-open & continue")   // 0
        alert.addButton(withTitle: "Cancel")               // 1
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        return runFloatingAlert(alert) == 0
    }

    /// Start working on `tid` right now: reopen its chain (so a completed task and its
    /// ancestors go active again), pull it from the queue if parked there, suspend any
    /// running stack to the front so it isn't orphaned, then begin the session — rebuilding
    /// the ancestor stack for a subtask. Shared by See History "Resume task" and See Queue
    /// "Work on now". Warns first if a completed parent would be re-opened; returns false if
    /// the user cancels. Callers hold `showing` and refresh their own window afterward.
    @discardableResult
    private func startWorkingOn(taskId tid: Int64, focus: String) -> Bool {
        guard confirmReopenAncestors(of: tid) else { return false }
        reopenTaskChain(tid)
        if let qid = db.queueItems().first(where: { $0.taskId == tid })?.id { db.removeFromQueue(id: qid) }
        if taskId != nil { suspendStack(toFront: true) }
        beginSession(reason: "resume", seconds: max(1, db.remainingSeconds(taskId: tid)),
                     focus: focus, resumeTaskId: tid)
        return true
    }

    // "Resume task" from See History: pick the selected task back up and start working on
    // it now. Reopens it if it was completed, rebuilds its parent stack if it's a subtask,
    // and suspends whatever's currently running (to the front of the queue) first.
    @objc func resumeHistoryTask() {
        guard !showing, !strictModeEnabled else { return }
        let tasks = historyTargetNodes().compactMap { $0.task }
        guard tasks.count == 1, let t = tasks.first else { return }
        showing = true
        defer { showing = false }
        // A completed task has no time left — reopening it would be instantly "done" again.
        // Ask how much time to add to its estimate first (cancel aborts the resume).
        if t.status == "completed" {
            guard let added = askResumeAddTime(focus: t.focus) else { return }
            db.addTimeToTask(id: t.id, seconds: added)
        }
        if startWorkingOn(taskId: t.id, focus: t.focus) { reloadHistory() }
    }

    /// Ask how much time to add to a completed task's estimate before reopening it
    /// (minutes or M:SS). Loops until valid; returns seconds, or nil if cancelled.
    private func askResumeAddTime(focus: String) -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        field.stringValue = "5"
        while true {
            let alert = makeAlert()
            alert.messageText = "Resume \u{201C}\(focus)\u{201D}"
            alert.informativeText = "This task is complete. How much time to add before reopening it?\n\nMinutes (e.g. 15) or M:SS (e.g. 1:30)."
            alert.addButton(withTitle: "Add & resume")   // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")          // .alertSecondButtonReturn
            alert.accessoryView = field
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertSecondButtonReturn { return nil }
            if let secs = parseDuration(field.stringValue) { return secs }
        }
    }

    // "Work on now" from See Queue (context menu or double-click): start the clicked queued
    // item immediately, out of turn. Disabled in strict mode (that would jump the order).
    // Context-menu "Work on now" — a deliberate choice, so no confirm.
    @objc func workOnQueueItemNow() { workOnClickedQueueRow(confirm: false) }

    // Double-click a queue row — easy to trigger by accident, so confirm first.
    @objc func workOnQueueItemDoubleClicked() { workOnClickedQueueRow(confirm: true) }

    private func workOnClickedQueueRow(confirm: Bool) {
        let row = queueTable?.clickedRow ?? -1
        guard !showing, !strictModeEnabled, row >= 0, row < queueRows.count else { return }
        let item = queueRows[row]
        guard let tid = item.taskId else { return }
        showing = true
        defer { showing = false }
        if confirm {
            let alert = makeAlert()
            alert.messageText = "Work on now?"
            alert.informativeText = "Start \u{201C}\(queueDisplayName(item))\u{201D} now."
            alert.addButton(withTitle: "OK")       // 0
            alert.addButton(withTitle: "Cancel")   // 1
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            guard runFloatingAlert(alert) == 0 else { return }
        }
        guard startWorkingOn(taskId: tid, focus: item.focus) else { return }
        queueWindow?.close()   // we're now working on it — close the queue
    }

    // Queue rows a right-click acts on: the whole selection if the clicked row is part of
    // it, otherwise just the clicked row (matching See History's targeting).
    private func queueTargetItems() -> [QueueItem] {
        guard let table = queueTable else { return [] }
        let clicked = table.clickedRow
        let selected = table.selectedRowIndexes
        let rows: IndexSet
        if clicked >= 0 && selected.contains(clicked) { rows = selected }
        else if clicked >= 0 { rows = IndexSet(integer: clicked) }
        else { rows = selected }
        return rows.compactMap { $0 < queueRows.count ? queueRows[$0] : nil }
    }

    // "Edit tags…" from See Queue: one row → replace its tags; multiple → bulk add/remove.
    @objc func editQueueItemTags() {
        guard !showing else { return }
        let items = queueTargetItems()
        guard !items.isEmpty else { return }
        showing = true
        defer { showing = false }
        func refresh() { reloadQueueData(); queueTable?.reloadData() }
        if items.count == 1, let tid = items[0].taskId {
            if promptEditTags(taskId: tid, focus: items[0].focus) { refresh() }
        } else if let decision = promptBulkTags(count: items.count) {
            applyBulkTags(decision, to: items.compactMap { $0.taskId })
            refresh()
        }
    }

    // "Complete task" from See Queue: mark the clicked queued task completed — rate it (the
    // same rating flow as the menu's Complete task), then drop it from the queue. Used when
    // you finished (or no longer need to actively work) a queued item.
    @objc func completeQueueItem() {
        let row = queueTable?.clickedRow ?? -1
        guard !showing, row >= 0, row < queueRows.count else { return }
        let item = queueRows[row]
        guard let tid = item.taskId else { return }
        showing = true
        defer { showing = false }
        let (rating, note, _, _) = promptRating(focus: item.focus, title: "Rate this session")
        // A never-started queued task has no intervals, so History's Ended (= MAX interval
        // end) would be blank. Stamp a zero-length interval so completion has a real
        // timestamp (Ended = now, Actual unchanged). Set-aside tasks keep their real intervals.
        if db.intervals(forTask: tid).isEmpty, let iid = db.startInterval(taskId: tid, reason: "completed") {
            db.endInterval(id: iid, elapsedSeconds: 0)
        }
        db.finishTask(id: tid, status: "completed", rating: rating, note: note)
        db.removeFromQueue(id: item.id)
        reloadQueueData()
        queueTable?.reloadData()
        updateQueueFilterUI()
    }

    // "Add to queue" from See History: park the selected task(s) at the end of the queue
    // to work on later. Reopens completed ones (they become live pending tasks) and skips
    // any already queued, to avoid duplicates.
    @objc func addHistoryTaskToQueue() {
        guard !showing, !strictModeEnabled else { return }
        let tasks = historyTargetNodes().compactMap { $0.task }
        guard !tasks.isEmpty else { return }
        showing = true
        defer { showing = false }
        let queuedTaskIds = Set(db.queueItems().compactMap { $0.taskId })
        for t in tasks where !queuedTaskIds.contains(t.id) {
            reopenTaskChain(t.id)
            _ = db.enqueueTask(focus: t.focus, estimateSeconds: max(1, db.remainingSeconds(taskId: t.id)),
                               taskId: t.id, front: false)
        }
        reloadHistory()
    }

    // "Edit tags…" from See History: edit the selected task's tags.
    @objc func editHistoryTaskTags() {
        guard !showing else { return }
        let tasks = historyTargetNodes().compactMap { $0.task }
        guard !tasks.isEmpty else { return }
        showing = true
        defer { showing = false }
        if tasks.count == 1 {
            if promptEditTags(taskId: tasks[0].id, focus: tasks[0].focus) { reloadHistory() }
        } else if let decision = promptBulkTags(count: tasks.count) {
            applyBulkTags(decision, to: tasks.map { $0.id })
            reloadHistory()
        }
    }

    /// Shared "Edit tags…" prompt: a comma-separated field pre-filled with the task's
    /// current tags. On Save, replaces the task's tags (empty clears them). Returns whether
    /// it was applied (false on Cancel). Caller holds `showing` and refreshes its window.
    @discardableResult
    private func promptEditTags(taskId: Int64, focus: String) -> Bool {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.stringValue = db.tags(forTask: taskId).map { $0.name }.joined(separator: ", ")
        field.placeholderString = "comma-separated, e.g. work, urgent"
        let alert = makeAlert()
        alert.messageText = "Tags for \u{201C}\(focus)\u{201D}"
        alert.informativeText = "Comma-separated tags. Leave empty to clear."
        alert.addButton(withTitle: "Save")     // 0
        alert.addButton(withTitle: "Cancel")   // 1
        alert.accessoryView = field
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard runFloatingAlert(alert, firstResponder: field) == 0 else { return false }
        db.setTags(taskId: taskId, names: field.stringValue.split(separator: ",").map(String.init))
        return true
    }

    @objc private func radioNoop() {}   // shared action so a pair of radios group

    /// Bulk "Edit tags…" prompt for a MULTI-row selection: an Add / Remove radio (Add is
    /// the default) over an empty comma-separated field. Existing tags aren't shown (the
    /// rows may differ). Returns (add, names), or nil if cancelled or the field is empty.
    private func promptBulkTags(count: Int) -> (add: Bool, names: [String])? {
        let addRadio = NSButton(radioButtonWithTitle: "Add tags", target: self, action: #selector(radioNoop))
        let removeRadio = NSButton(radioButtonWithTitle: "Remove tags", target: self, action: #selector(radioNoop))
        addRadio.state = .on   // default
        addRadio.frame = NSRect(x: 0, y: 32, width: 140, height: 20)
        removeRadio.frame = NSRect(x: 0, y: 8, width: 140, height: 20)
        let field = NSTextField(frame: NSRect(x: 150, y: 8, width: 190, height: 24))
        field.placeholderString = "comma-separated"
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 56))
        accessory.addSubview(addRadio); accessory.addSubview(removeRadio); accessory.addSubview(field)

        let alert = makeAlert()
        alert.messageText = "Edit tags — \(count) tasks"
        alert.informativeText = "Add or remove these tags on all \(count) selected tasks."
        alert.addButton(withTitle: "Apply")    // 0
        alert.addButton(withTitle: "Cancel")   // 1
        alert.accessoryView = accessory
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard runFloatingAlert(alert, firstResponder: field) == 0 else { return nil }
        let names = field.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !names.isEmpty else { return nil }
        return (addRadio.state == .on, names)
    }

    /// Apply a bulk add/remove to a set of task ids.
    private func applyBulkTags(_ decision: (add: Bool, names: [String]), to taskIds: [Int64]) {
        for tid in taskIds {
            if decision.add { db.addTags(taskId: tid, names: decision.names) }
            else { db.removeTags(taskId: tid, names: decision.names) }
        }
    }

    // Delete the right-clicked (or selected) history sessions, after confirming.
    @objc func deleteHistoryItems() {
        guard !showing else { return }
        let nodes = historyTargetNodes()
        guard !nodes.isEmpty else { return }
        let n = nodes.count
        // In Tasks mode the selection can now include interval child rows.
        let allTasks = nodes.allSatisfy { $0.task != nil }
        let allIntervals = nodes.allSatisfy { $0.interval != nil }
        let noun = allIntervals ? "interval" : (allTasks ? "task" : "item")

        showing = true
        defer { showing = false }
        let alert = makeAlert()
        alert.messageText = "Delete \(n) \(noun)\(n == 1 ? "" : "s")?"
        alert.informativeText = allIntervals
            ? "This permanently removes \(n == 1 ? "this interval" : "these intervals") — the parent task's totals shrink. This can't be undone."
            : "This permanently removes the selected \(noun)\(n == 1 ? "" : "s") — tasks take their subtasks and intervals with them. This can't be undone."
        alert.addButton(withTitle: "Delete")   // .alertFirstButtonReturn
        alert.addButton(withTitle: "Cancel")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        var taskIds: Set<Int64> = []
        var ivIds: [Int64] = []
        for node in nodes {
            if node.task != nil { collectSubtreeTaskIds(node, into: &taskIds) }
            else if let iv = node.interval { ivIds.append(iv.id) }
        }
        if !ivIds.isEmpty { db.deleteIntervals(ids: ivIds) }
        if !taskIds.isEmpty { db.deleteTasks(ids: Array(taskIds)) }
        reloadHistory()
    }

    private func collectSubtreeTaskIds(_ node: HistoryNode, into ids: inout Set<Int64>) {
        guard let t = node.task else { return }
        ids.insert(t.id)
        for c in node.children { collectSubtreeTaskIds(c, into: &ids) }
    }

    // "Give up" on selected in-progress task(s) from See History: mark them
    // abandoned (a terminal status — kept in history with time worked so far, no
    // rating) and drop them from the queue, so they stop floating at the top.
    @objc func abandonHistoryTask() {
        guard !showing, !strictModeEnabled else { return }
        let ids = historyTargetNodes().compactMap { $0.task }.filter { $0.endedAt == nil }.map { $0.id }   // in-progress only
        guard !ids.isEmpty else { return }

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
            resumeStackIfPaused()
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
        queueTags = db.tagNamesByTask()
        // Apply the active tag filter to what's shown (and thus what reorder/remove act on).
        queueRows = db.queueItems().filter { matchesQueueFilter($0, tagsByTask: queueTags) }
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
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 400),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered, defer: false)
            window.title = "Focus queue"
            window.isReleasedWhenClosed = false
            window.center()

            let container = NSView(frame: window.contentView!.bounds)
            container.autoresizingMask = [.width, .height]

            // Footer hint (bottom, full width) — surfaces the reorder shortcut.
            let hintH: CGFloat = 22
            let hint = NSTextField(labelWithString: "Tip: ⌘↑ / ⌘↓ move the selected item up or down. Right-click for more.")
            hint.font = NSFont.systemFont(ofSize: 11)
            hint.textColor = .secondaryLabelColor
            hint.frame = NSRect(x: 10, y: 3, width: container.bounds.width - 20, height: hintH - 4)
            hint.autoresizingMask = [.width, .maxYMargin]

            // Top bar: tag filter control.
            let topBarH: CGFloat = 34
            let barY = container.bounds.height - topBarH + 5
            let addToQueueButton = NSButton(title: "+ Add to queue", target: self, action: #selector(addToQueueFromWindow))
            addToQueueButton.bezelStyle = .rounded
            addToQueueButton.frame = NSRect(x: 10, y: barY, width: 130, height: 24)
            addToQueueButton.autoresizingMask = [.minYMargin]
            let filterButton = NSButton(title: "Filter by tags…", target: self, action: #selector(editQueueFilter))
            filterButton.bezelStyle = .rounded
            filterButton.frame = NSRect(x: 150, y: barY, width: 140, height: 24)
            filterButton.autoresizingMask = [.minYMargin]
            let filterLabel = NSTextField(labelWithString: "")
            filterLabel.font = NSFont.systemFont(ofSize: 11)
            filterLabel.textColor = .secondaryLabelColor
            filterLabel.lineBreakMode = .byTruncatingTail
            filterLabel.frame = NSRect(x: 300, y: container.bounds.height - topBarH + 8, width: container.bounds.width - 300 - 100, height: 18)
            filterLabel.autoresizingMask = [.width, .minYMargin]
            let clearButton = NSButton(title: "Clear", target: self, action: #selector(clearQueueFilter))
            clearButton.bezelStyle = .rounded
            clearButton.frame = NSRect(x: container.bounds.width - 90, y: container.bounds.height - topBarH + 5, width: 80, height: 24)
            clearButton.autoresizingMask = [.minXMargin, .minYMargin]
            queueFilterLabel = filterLabel
            queueFilterClearButton = clearButton

            let scroll = NSScrollView(frame: NSRect(x: 0, y: hintH, width: container.bounds.width,
                                                    height: container.bounds.height - hintH - topBarH))
            scroll.autoresizingMask = [.width, .height]
            scroll.hasVerticalScroller = true
            scroll.hasHorizontalScroller = true   // long "Parent › Subtask" chains can scroll
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
            table.onMove = { [weak self] delta in self?.moveSelectedQueueRow(by: delta) }
            // Double-click a row → work on it now (same as the context-menu item).
            table.target = self
            table.doubleAction = #selector(workOnQueueItemDoubleClicked)
            // Right-click a row to work on it now, re-order it within the queue, or remove it.
            let rowMenu = NSMenu()
            rowMenu.addItem(withTitle: "Work on now", action: #selector(workOnQueueItemNow), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Complete task", action: #selector(completeQueueItem), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Edit tags…", action: #selector(editQueueItemTags), keyEquivalent: "")
            rowMenu.addItem(.separator())
            rowMenu.addItem(withTitle: "Move up", action: #selector(moveQueueItemUp), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Move down", action: #selector(moveQueueItemDown), keyEquivalent: "")
            rowMenu.addItem(.separator())
            rowMenu.addItem(withTitle: "Move to top", action: #selector(moveQueueItemToTop), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Move to bottom", action: #selector(moveQueueItemToBottom), keyEquivalent: "")
            rowMenu.addItem(.separator())
            rowMenu.addItem(withTitle: "Remove from queue", action: #selector(deleteClickedQueueItem), keyEquivalent: "")
            rowMenu.addItem(withTitle: "Delete permanently", action: #selector(deleteQueuedTaskPermanently), keyEquivalent: "")
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
            addColumn("focus", "Focus (next up first)", width: 400, min: 220)
            addColumn("tags", "Tags", width: 160, min: 80)

            scroll.documentView = table
            container.addSubview(scroll)
            container.addSubview(hint)
            container.addSubview(addToQueueButton)
            container.addSubview(filterButton)
            container.addSubview(filterLabel)
            container.addSubview(clearButton)
            window.contentView = container

            queueWindow = window
            queueTable = table
        }

        updateQueueFilterUI()
        queueTable?.reloadData()
        NSApp.activate(ignoringOtherApps: true)
        queueWindow?.makeKeyAndOrderFront(nil)
    }

    /// Refresh the See Queue top bar to reflect the active filter.
    private func updateQueueFilterUI() {
        if queueFilterActive() {
            queueFilterLabel?.stringValue = "Filter: \(queueFilterTags.joined(separator: ", "))  (showing \(queueRows.count) of \(db.queueCount()))"
            queueFilterClearButton?.isHidden = false
        } else {
            queueFilterLabel?.stringValue = "No filter — showing all queued items."
            queueFilterClearButton?.isHidden = true
        }
    }

    // "Filter by tags…" — pick which tags the queue is filtered to (0 = no filter).
    @objc func editQueueFilter() {
        guard !showing else { return }
        showing = true
        defer { showing = false }
        let tags = db.allTags().map { $0.name }
        guard !tags.isEmpty else {
            let alert = makeAlert()
            alert.messageText = "No tags yet"
            alert.informativeText = "Tag some tasks first (right-click a task → Edit tags…), then you can filter the queue by tag."
            alert.addButton(withTitle: "OK")
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            _ = runFloatingAlert(alert)
            return
        }
        let current = Set(queueFilterTags.map { $0.lowercased() })
        // A checkbox per tag, in a scroll view (tags can be many).
        let rowH: CGFloat = 22, viewW: CGFloat = 300
        let inner = NSView(frame: NSRect(x: 0, y: 0, width: viewW, height: CGFloat(tags.count) * rowH))
        var boxes: [NSButton] = []
        for (i, name) in tags.enumerated() {
            let cb = NSButton(checkboxWithTitle: name, target: nil, action: nil)
            cb.frame = NSRect(x: 4, y: inner.frame.height - CGFloat(i + 1) * rowH, width: viewW - 8, height: rowH - 2)
            cb.state = current.contains(name.lowercased()) ? .on : .off
            inner.addSubview(cb); boxes.append(cb)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: viewW, height: min(220, CGFloat(tags.count) * rowH)))
        scroll.documentView = inner
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let alert = makeAlert()
        alert.messageText = "Filter queue by tags"
        alert.informativeText = "Show only queued items with at least one checked tag. Check none to show everything."
        alert.addButton(withTitle: "Apply")    // 0
        alert.addButton(withTitle: "Cancel")   // 1
        alert.accessoryView = scroll
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard runFloatingAlert(alert) == 0 else { return }
        queueFilterTags = zip(tags, boxes).filter { $0.1.state == .on }.map { $0.0 }
        reloadQueueData()
        queueTable?.reloadData()
        updateQueueFilterUI()
    }

    @objc func clearQueueFilter() {
        queueFilterTags = []
        reloadQueueData()
        queueTable?.reloadData()
        updateQueueFilterUI()
    }

    // See Queue "+ Add to queue" button — same as the menu's Add to queue, then refresh the
    // open window (which the menu action doesn't do on its own).
    @objc func addToQueueFromWindow() {
        addNextFocus()
        reloadQueueData()
        queueTable?.reloadData()
        updateQueueFilterUI()
    }

    @objc func clearQueue() {
        guard !showing, !strictModeEnabled else { return }   // strict mode: can't wipe the plan
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

    // The queue window is the only remaining NSTableView; History is an outline.
    func numberOfRows(in tableView: NSTableView) -> Int {
        tableView === queueTable ? queueRows.count : 0
    }

    // ---- History outline data source (tree of tasks, optional interval child rows) ----
    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? HistoryNode)?.children.count ?? historyNodes.count
    }
    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? HistoryNode)?.children[index] ?? historyNodes[index]
    }
    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? HistoryNode)?.children.isEmpty ?? true)
    }
    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? HistoryNode, let id = tableColumn?.identifier.rawValue else { return nil }
        if let t = node.task {
            let c = taskCellText(t, id)
            // Completed tasks read in a soft, comforting green (the whole row).
            let color: NSColor = t.status == "completed" ? Self.completedGreen : .labelColor
            return historyCell(outlineView, id: id, text: c.0, align: c.1, color: color)
        }
        if let iv = node.interval {
            // An interval is a dim child row rendered in the task columns.
            let c = intervalInTaskColumns(iv, id)
            return historyCell(outlineView, id: id, text: c.0, align: c.1, color: .secondaryLabelColor)
        }
        return nil
    }

    // An interval rendered under its task (Tasks mode): reason label + start/end/
    // duration/rating; the task-only columns are blank.
    private func intervalInTaskColumns(_ r: IntervalHistoryRow, _ id: String) -> (String, NSTextAlignment) {
        switch id {
        case "focus":
            // "50m" for a minute or more, else "37s" (don't round sub-minute down to "0m").
            let dur = r.seconds < 60 ? "\(r.seconds)s" : "\(Int((Double(r.seconds) / 60).rounded()))m"
            let label = "Interval: \(dur)"
            return (r.reason.map { "\(label) - \($0)" } ?? label, .left)          // "… - preempt"
        case "when":   return (whenLabel(r.startedAt), .left)
        case "ended":  return (r.endedAt.map(whenLabel) ?? "—", .left)
        case "min":    return (mmss(r.seconds), .right)
        case "rating": return (r.rating.map { "\($0)/10" } ?? "—", .right)
        default:       return ("", .left)
        }
    }

    /// Status label for a task row. Terminal status wins; an unfinished task (nil status,
    /// no finish time) is "active" ONLY if it's the task currently being worked on (the
    /// leaf) — every other unfinished task (set aside, queued-and-started, an ancestor) is
    /// merely "open".
    private func historyStatusLabel(_ r: TaskHistoryRow, placeholder: String) -> String {
        if let s = r.status { return s }
        guard r.endedAt == nil else { return placeholder }
        return r.id == taskId ? "active" : "open"
    }

    private func taskCellText(_ r: TaskHistoryRow, _ id: String) -> (String, NSTextAlignment) {
        switch id {
        case "when":    return (r.startedAt.map(whenLabel) ?? "—", .left)
        case "ended":   return (r.endedAt.map(whenLabel) ?? "—", .left)
        case "min":     return (mmss(r.actualSeconds), .right)
        case "origmin": return (r.originalEstimateSeconds.map { mmss($0) } ?? "—", .right)
        case "ivs":     return ("\(r.intervalCount)", .right)
        case "rating":  return (r.rating.map { "\($0)/10" } ?? "—", .right)
        case "status":  return (historyStatusLabel(r, placeholder: "—"), .left)
        case "tags":    return ((historyTags[r.id] ?? []).joined(separator: ", "), .left)
        case "note":    return (r.note ?? "", .left)
        default:        return (r.focus, .left)
        }
    }
    // ---- queue reordering (right-click menu on the queue table) ----
    @objc func moveQueueItemUp()      { moveQueueRow(at: queueTable?.clickedRow ?? -1) { $0 - 1 } }
    @objc func moveQueueItemDown()    { moveQueueRow(at: queueTable?.clickedRow ?? -1) { $0 + 1 } }
    @objc func moveQueueItemToTop()   { moveQueueRow(at: queueTable?.clickedRow ?? -1) { _ in 0 } }
    @objc func moveQueueItemToBottom(){ moveQueueRow(at: queueTable?.clickedRow ?? -1) { _ in Int.max } }

    /// Move the queue row at `src` to a new index (computed from its current one), then
    /// persist the new order and refresh. Returns the row the moved item lands on, or nil
    /// if nothing moved — the keyboard path uses it to keep the selection with the item.
    @discardableResult
    private func moveQueueRow(at src: Int, _ destination: (Int) -> Int) -> Int? {
        guard !strictModeEnabled, let table = queueTable else { return nil }
        guard src >= 0, src < queueRows.count else { return nil }
        let target = min(max(destination(src), 0), queueRows.count - 1)   // index in the VISIBLE list
        guard target != src else { return nil }
        let moved = queueRows[src]

        // Splice within the FULL queue so hidden (filtered-out) items keep their places.
        // `queueRows` is the visible list, so move relative to the visible neighbor. With no
        // filter active, queueRows == the full queue and this reduces to a plain move.
        var full = db.queueItems().map { $0.id }
        guard let fullMovedIdx = full.firstIndex(of: moved.id) else { return nil }
        full.remove(at: fullMovedIdx)
        let insertIdx: Int
        if target <= 0 {
            insertIdx = 0                                              // to the front
        } else if target >= queueRows.count - 1 {
            insertIdx = full.count                                    // to the back
        } else if target < src {
            insertIdx = full.firstIndex(of: queueRows[target].id) ?? 0            // just before that visible item
        } else {
            insertIdx = full.firstIndex(of: queueRows[target].id).map { $0 + 1 } ?? full.count  // just after it
        }
        full.insert(moved.id, at: min(insertIdx, full.count))
        db.reorderQueue(ids: full)
        reloadQueueData()
        table.reloadData()
        return queueRows.firstIndex(where: { $0.id == moved.id })     // new visible index of the moved item
    }

    // Move the SELECTED queue row(s) by one (⌘↑ / ⌘↓) — all selected rows shift together as a
    // block, keeping their relative order and staying selected so you can chain moves. No-op
    // in strict mode (the queue is frozen).
    private func moveSelectedQueueRow(by delta: Int) {
        guard !strictModeEnabled, let table = queueTable else { return }
        let sel = table.selectedRowIndexes.filter { $0 >= 0 && $0 < queueRows.count }.sorted()
        guard let first = sel.first, let last = sel.last else { return }
        // The block is already against the edge it's moving toward → nothing to do.
        if delta < 0 && first == 0 { return }
        if delta > 0 && last == queueRows.count - 1 { return }

        let movedIds = Set(sel.map { queueRows[$0].id })
        // Standard block move: shift each selected item past the adjacent UNselected item,
        // among the VISIBLE rows. Top-to-bottom for up, bottom-to-top for down.
        var ids = queueRows.map { $0.id }
        var selSet = Set(sel)
        if delta < 0 {
            for i in 1..<ids.count where selSet.contains(i) && !selSet.contains(i - 1) {
                ids.swapAt(i, i - 1); selSet.remove(i); selSet.insert(i - 1)
            }
        } else {
            for i in stride(from: ids.count - 2, through: 0, by: -1) where selSet.contains(i) && !selSet.contains(i + 1) {
                ids.swapAt(i, i + 1); selSet.remove(i); selSet.insert(i + 1)
            }
        }
        // Slot the reordered visible ids back into the visible positions of the FULL queue,
        // leaving hidden (filtered-out) items in place.
        let visibleSet = Set(queueRows.map { $0.id })
        var it = ids.makeIterator()
        let newFull = db.queueItems().map { $0.id }.map { visibleSet.contains($0) ? (it.next() ?? $0) : $0 }
        db.reorderQueue(ids: newFull)
        reloadQueueData()
        table.reloadData()
        // Re-select the moved rows at their new positions.
        let newSel = IndexSet(queueRows.indices.filter { movedIds.contains(queueRows[$0].id) })
        table.selectRowIndexes(newSel, byExtendingSelection: false)
    }

    // Remove the right-clicked queue row (menu), or the selected row (Delete key).
    @objc func deleteClickedQueueItem() { deleteQueueRow(at: queueTable?.clickedRow ?? -1) }

    // "Remove from queue": drop the queue row. A never-started plan (its task exists but
    // has no intervals) is kept as an abandoned record rather than vanishing — durable
    // identity for queue items. A started set-aside task just leaves the queue.
    private func deleteQueueRow(at row: Int) {
        guard !strictModeEnabled, row >= 0, row < queueRows.count else { return }
        let item = queueRows[row]
        db.removeFromQueue(id: item.id)
        if let tid = item.taskId, db.task(id: tid)?.status == "queued" {
            db.finishTask(id: tid, status: "abandoned")
        }
        reloadQueueData()
        queueTable?.reloadData()
    }

    // "Delete permanently": remove the row AND delete the task + its history entirely.
    @objc func deleteQueuedTaskPermanently() {
        let row = queueTable?.clickedRow ?? -1
        guard !showing, !strictModeEnabled, row >= 0, row < queueRows.count else { return }
        showing = true
        defer { showing = false }
        let item = queueRows[row]
        let alert = makeAlert()
        alert.messageText = "Delete permanently?"
        alert.informativeText = "\(queueDisplayName(item)) — removes it from the queue and deletes the task and its history. Can't be undone."
        alert.addButton(withTitle: "Delete")   // 0
        alert.addButton(withTitle: "Cancel")   // 1
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        guard runFloatingAlert(alert) == 0 else { return }
        db.removeFromQueue(id: item.id)
        if let tid = item.taskId { db.deleteTasks(ids: [tid]) }
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
                queueDisplayName(q),
            ].map(tsvClean)
            lines.append(fields.joined(separator: "\t"))
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        // Only the queue table remains (History moved to an outline).
        guard tableView === queueTable, let id = tableColumn?.identifier.rawValue, row < queueRows.count else { return nil }
        let q = queueRows[row]
        let text: String
        var align: NSTextAlignment = .left
        let est = row < queueEstimates.count ? queueEstimates[row] : nil
        switch id {
        case "pos":    text = "\(row + 1)"; align = .right
        case "min":    text = mmss(q.seconds); align = .right
        case "start":  text = est.map { localClockFormatter.string(from: $0.start) } ?? ""; align = .right
        case "finish": text = est.map { localClockFormatter.string(from: $0.finish) } ?? ""; align = .right
        case "tags":   text = q.taskId.flatMap { queueTags[$0] }?.joined(separator: ", ") ?? ""
        default:       text = queueDisplayName(q)
        }
        return historyCell(tableView, id: id, text: text, align: align)
    }

    // A soft, comforting green for completed rows — muted forest on light, gentle mint on
    // dark, so it reassures without shouting in either theme.
    private static let completedGreen = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(red: 0.56, green: 0.80, blue: 0.60, alpha: 1)
            : NSColor(red: 0.19, green: 0.51, blue: 0.30, alpha: 1)
    }

    private func historyCell(_ table: NSTableView, id: String, text: String,
                             align: NSTextAlignment, color: NSColor = .labelColor) -> NSTableCellView {
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
        cell.textField?.textColor = color   // reset every time — cells are reused across dim/normal rows
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

        // While the pill is being dragged (primary button held), don't re-render its text.
        // layoutHUD() no-ops mid-drag, so its forced full redraw is skipped — updating the
        // text anyway invalidates the field without repainting it cleanly, which can leave
        // the tail (the total) unpainted until the drag ends. It refreshes on release.
        if (NSEvent.pressedMouseButtons & 1) == 0 {
            hudLabel.attributedStringValue = pillAttributedString()
            layoutHUD()
        }
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
            let timeStr: String
            if pillShowsSpentEnabled {
                // Time spent = estimate − remaining (grows past the estimate when over).
                let spent = estimate - rem
                timeStr = showTotalOnPillEnabled ? "\(mmss(spent)) / \(mmss(estimate))" : mmss(spent)
            } else {
                timeStr = over ? "+\(mmss(-rem))"
                                : (showTotalOnPillEnabled ? "\(mmss(rem)) / \(mmss(estimate))" : mmss(rem))
            }
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
    private var pillShowsSpentEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "pillShowsSpent") }                   // default off (show remaining)
        set { UserDefaults.standard.set(newValue, forKey: "pillShowsSpent") }
    }
    private var oneTaskOnlyEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "oneTaskOnly") }                     // default off
        set { UserDefaults.standard.set(newValue, forKey: "oneTaskOnly") }
    }
    private var strictModeEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "strictMode") }                      // default off
        set { UserDefaults.standard.set(newValue, forKey: "strictMode") }
    }
    private var allowPauseEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "allowPause") as? Bool ?? true }   // default on
        set { UserDefaults.standard.set(newValue, forKey: "allowPause") }
    }
    private var askPauseReasonEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "askPauseReason") }                  // default off
        set { UserDefaults.standard.set(newValue, forKey: "askPauseReason") }
    }

    // Settings can be temporarily locked (a commitment device): Settings is disabled
    // until this moment. Persisted (as a wall-clock instant) so it survives quit/relaunch
    // — you can't quit-and-relaunch to get back in early.
    private var settingsLockedUntil: Date? {
        get { let t = UserDefaults.standard.double(forKey: "settingsLockedUntil"); return t > 0 ? Date(timeIntervalSinceReferenceDate: t) : nil }
        set { UserDefaults.standard.set(newValue?.timeIntervalSinceReferenceDate ?? 0, forKey: "settingsLockedUntil") }
    }
    /// Seconds left on the settings lock, or nil if unlocked. Clears an expired lock.
    private func settingsLockRemaining() -> Int? {
        guard let until = settingsLockedUntil else { return nil }
        let secs = Int(until.timeIntervalSinceNow.rounded())
        if secs <= 0 { settingsLockedUntil = nil; return nil }
        return secs
    }

    /// The global preference checkboxes, initialized from the stored values,
    /// for the Settings dialog.
    private func preferenceCheckboxes() -> (sound: NSButton, pushover: NSButton, auto: NSButton, total: NSButton, spent: NSButton, oneTask: NSButton, strict: NSButton, allowPause: NSButton, pauseReason: NSButton) {
        let sound = NSButton(checkboxWithTitle: "Play sound when time's up", target: nil, action: nil)
        sound.state = playSoundEnabled ? .on : .off
        let pushover = NSButton(checkboxWithTitle: "Send Pushover notification at start and end of sessions", target: nil, action: nil)
        pushover.state = pushoverEnabled ? .on : .off
        let auto = NSButton(checkboxWithTitle: "Auto-proceed with next queued task", target: nil, action: nil)
        auto.state = autoProceedEnabled ? .on : .off
        let total = NSButton(checkboxWithTitle: "Show total session time after remaining time", target: nil, action: nil)
        total.state = showTotalOnPillEnabled ? .on : .off
        let spent = NSButton(checkboxWithTitle: "Show time spent instead of time remaining", target: nil, action: nil)
        spent.state = pillShowsSpentEnabled ? .on : .off
        let oneTask = NSButton(checkboxWithTitle: "One task only, then touch grass (finish, then lock the screen)", target: nil, action: nil)
        oneTask.state = oneTaskOnlyEnabled ? .on : .off
        let strict = NSButton(checkboxWithTitle: "Strict mode: Must do tasks in queue order, no switching", target: nil, action: nil)
        strict.state = strictModeEnabled ? .on : .off
        let allowPause = NSButton(checkboxWithTitle: "Allow pausing the current task", target: nil, action: nil)
        allowPause.state = allowPauseEnabled ? .on : .off
        let pauseReason = NSButton(checkboxWithTitle: "Ask for reason when pausing", target: nil, action: nil)
        pauseReason.state = askPauseReasonEnabled ? .on : .off
        return (sound, pushover, auto, total, spent, oneTask, strict, allowPause, pauseReason)
    }

    private func persistPreferences(_ sound: NSButton, _ pushover: NSButton, _ auto: NSButton, _ total: NSButton, _ spent: NSButton, _ oneTask: NSButton, _ strict: NSButton, _ allowPause: NSButton, _ pauseReason: NSButton) {
        playSoundEnabled = sound.state == .on
        pushoverEnabled = pushover.state == .on
        autoProceedEnabled = auto.state == .on
        showTotalOnPillEnabled = total.state == .on
        pillShowsSpentEnabled = spent.state == .on
        oneTaskOnlyEnabled = oneTask.state == .on
        strictModeEnabled = strict.state == .on
        allowPauseEnabled = allowPause.state == .on
        askPauseReasonEnabled = pauseReason.state == .on
    }

    // Standalone Settings dialog for the global preferences.
    @objc func showSettings() {
        guard settingsLockRemaining() == nil else { return }   // locked → can't open
        // Blocked while another prompt is up, except the "Ready to focus?" chooser, over
        // which Settings may open. Save/restore `showing` so closing Settings doesn't clear
        // the chooser's own `showing` guard.
        guard !showing || nextFocusOpen else { return }
        let wasShowing = showing
        showing = true
        defer { showing = wasShowing }
        NSApp.activate(ignoringOtherApps: true)

        let (sound, pushover, auto, total, spent, oneTask, strict, allowPause, pauseReason) = preferenceCheckboxes()
        total.frame = NSRect(x: 0, y: 208, width: 460, height: 20)
        spent.frame = NSRect(x: 0, y: 182, width: 460, height: 20)
        sound.frame = NSRect(x: 0, y: 156, width: 460, height: 20)
        pushover.frame = NSRect(x: 0, y: 130, width: 460, height: 20)
        auto.frame = NSRect(x: 0, y: 104, width: 460, height: 20)
        oneTask.frame = NSRect(x: 0, y: 78, width: 460, height: 20)
        strict.frame = NSRect(x: 0, y: 52, width: 460, height: 20)
        allowPause.frame = NSRect(x: 0, y: 26, width: 460, height: 20)
        pauseReason.frame = NSRect(x: 0, y: 0, width: 460, height: 20)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 234))
        accessory.addSubview(total)
        accessory.addSubview(spent)
        accessory.addSubview(sound)
        accessory.addSubview(pushover)
        accessory.addSubview(auto)
        accessory.addSubview(oneTask)
        accessory.addSubview(strict)
        accessory.addSubview(allowPause)
        accessory.addSubview(pauseReason)

        let alert = makeAlert()
        alert.messageText = "Settings"
        alert.informativeText = "These apply to every session."
        alert.addButton(withTitle: "Done")             // .alertFirstButtonReturn
        alert.addButton(withTitle: "Lock settings…")   // .alertSecondButtonReturn
        alert.accessoryView = accessory
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let clicked = alert.runModal()

        // Persist whatever's set now — a lock keeps the settings you just chose.
        persistPreferences(sound, pushover, auto, total, spent, oneTask, strict, allowPause, pauseReason)
        if clicked == .alertSecondButtonReturn, let secs = askLockDuration() {
            settingsLockedUntil = Date().addingTimeInterval(Double(secs))
        }
        // If Settings was opened over the "Ready to focus?" chooser, make it rebuild so it
        // reflects the changes (e.g. strict mode toggled): flag it and break the chooser's
        // event pump (Int.min ends runFloatingAlert; the flag is what's actually read).
        if nextFocusOpen {
            nextFocusNeedsRerender = true
            panelResult = Int.min
        }
        tick()   // apply the pill's remaining/total toggle immediately
    }

    /// Ask how long to lock Settings — minutes (e.g. "25") or M:SS (e.g. "2:30").
    /// Loops until a valid duration or Cancel. Returns seconds, or nil if cancelled.
    private func askLockDuration() -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        field.placeholderString = "e.g. 25 or 25:00"
        while true {
            let alert = makeAlert()
            alert.messageText = "Lock settings"
            alert.informativeText = "Settings stay locked and can't be opened until the timer's up.\nEnter minutes (e.g. 25) or M:SS (e.g. 2:30)."
            alert.addButton(withTitle: "Lock")     // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")   // .alertSecondButtonReturn
            alert.accessoryView = field
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = field
            if alert.runModal() == .alertSecondButtonReturn { return nil }
            if let secs = parseDuration(field.stringValue) { return secs }
        }
    }

    /// Parse a positive duration — plain minutes or "M:SS" — into seconds, or nil if it
    /// can't be parsed or is zero. Delegates to `parseDurationSeconds` (the single, tested
    /// duration rule shared with the session-setup field) so every duration input in the
    /// app accepts the same syntax; this wrapper just additionally rejects zero.
    private func parseDuration(_ s: String) -> Int? {
        guard let secs = parseDurationSeconds(s), secs > 0 else { return nil }
        return secs
    }

    /// Like `parseDuration` but signed: a leading "-" (or "+") applies to whole minutes or
    /// M:SS. Returns nil for empty, malformed, or zero.
    private func parseSignedDuration(_ s: String) -> Int? {
        var t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        var sign = 1
        if t.hasPrefix("-") { sign = -1; t.removeFirst() }
        else if t.hasPrefix("+") { t.removeFirst() }
        guard let magnitude = parseDuration(t.trimmingCharacters(in: .whitespaces)) else { return nil }
        return sign * magnitude
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
            let d = detachLeafForFinish()
            commitFinish(d, status: "completed")   // no popup; rating deferred to "Rate unrated"
            showing = false
            if d.hadParent { tick() } else { advanceAfterSession() }
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
            let d = detachLeafForFinish()
            commitFinish(d, status: "completed", rating: rating, note: note, popup: (openSeconds, applyTime))
            // Back to the parent subtask (if any) or on to the next focus.
            showing = false
            if d.hadParent { tick() } else { advanceAfterSession() }
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
            if let rating = parseRating(ratingField.stringValue) {
                return .rate(rating: rating,
                             note: noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                             openSeconds: openSeconds(), applyTime: apply.state == .on)
            }
            // invalid rating → parseRating explained why; loop back to the modal
        }
    }

    /// "Add time" prompt (cancellable) — the time's-up variant. Add-only (you're deciding
    /// whether to give yourself more time to keep working), so it takes a POSITIVE minutes
    /// or M:SS value and returns seconds, or nil if cancelled.
    private func askMinutes() -> Int? {
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 24))
        field.stringValue = "5"
        while true {
            let alert = makeAlert()
            alert.messageText = "Add time"
            alert.informativeText = "Minutes (e.g. 15) or M:SS (e.g. 1:30)."
            alert.addButton(withTitle: "Add")       // .alertFirstButtonReturn
            alert.addButton(withTitle: "Cancel")    // .alertSecondButtonReturn
            alert.accessoryView = field
            alert.window.level = .floating
            alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            alert.window.initialFirstResponder = field
            let response = alert.runModal()
            if response == .alertSecondButtonReturn { return nil }
            if let secs = parseDuration(field.stringValue) { return secs }   // positive only
        }
    }

    private struct DetachedLeaf { let taskId: Int64?; let intervalId: Int64?; let elapsed: Int; let hadParent: Bool }

    /// Detach the current leaf so it can be finished: snapshot its focus time (BEFORE any
    /// pause is folded away), resume the stack if paused, pop to the parent (or clear the
    /// leaf if top-level), and hide the pill. The caller then prompts for a rating — with
    /// the parent showing behind — and calls `commitFinish` with the snapshot. Splitting it
    /// this way keeps the delicate ordering (elapsed-before-resume, pop/clear-before-prompt)
    /// in ONE place for every end path.
    private func detachLeafForFinish() -> DetachedLeaf {
        let tid = taskId, iid = intervalId
        let elapsed = elapsedFocusSeconds()   // excludes pause time
        resumeStackIfPaused()
        let hadParent = popAncestorToLeaf()
        if !hadParent { clearSessionState() }
        hudWindow.orderOut(nil)
        return DetachedLeaf(taskId: tid, intervalId: iid, elapsed: elapsed, hadParent: hadParent)
    }

    /// Close a detached leaf's interval and mark its task finished. `popup` is the rating
    /// modal's popup-open accounting (split to the interval's duration when applyTime, else
    /// banked as end-open); pass nil when there was no rating popup (auto-proceed).
    private func commitFinish(_ d: DetachedLeaf, status: String, rating: Int? = nil,
                              note: String = "", popup: (openSeconds: Int, applyTime: Bool)? = nil) {
        if let iid = d.intervalId {
            if let p = popup {
                db.endInterval(id: iid, elapsedSeconds: d.elapsed, openSecondsEnd: p.applyTime ? nil : p.openSeconds)
                if p.applyTime { db.addToInterval(id: iid, seconds: p.openSeconds) }
            } else {
                db.endInterval(id: iid, elapsedSeconds: d.elapsed)
            }
        }
        if let tid = d.taskId { db.finishTask(id: tid, status: status, rating: rating, note: note) }
    }

    /// Force a rating, close the leaf as completed, and pop back to the parent (if a
    /// subtask) or clear the leaf. Returns whether a parent was popped. Caller holds
    /// `showing`. Completing early records the time actually used as the interval's.
    @discardableResult
    private func rateAndComplete() -> Bool {
        guard taskId != nil, intervalId != nil, let focus = currentFocus else { return false }
        let d = detachLeafForFinish()
        let (rating, note, openSeconds, applyTime) = promptRating(focus: focus, title: "Rate this session")
        commitFinish(d, status: "completed", rating: rating, note: note, popup: (openSeconds, applyTime))
        return d.hadParent
    }

    /// A rating (1–10) field over an optional note field, for the rating modals,
    /// with the "Open for M:SS" timer on top and an "apply this time" checkbox below it.
    private func ratingAccessory() -> (view: NSView, rating: NSTextField, note: NSTextField, elapsed: NSTextField, apply: NSButton) {
        let ratingField = NSTextField(frame: NSRect(x: 0, y: 34, width: 80, height: 24))
        ratingField.placeholderString = "1–10"
        ratingField.stringValue = "7"   // default rating
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
    /// Parse the rating field: a whole number 1–10. Returns it, or shows an explanatory
    /// alert and returns nil (so the caller re-prompts) — instead of failing silently on a
    /// decimal / out-of-range / empty value.
    private func parseRating(_ s: String) -> Int? {
        let t = s.trimmingCharacters(in: .whitespaces)
        if let n = Int(t), (1...10).contains(n) { return n }
        let alert = makeAlert()
        alert.messageText = "Enter a rating from 1 to 10"
        alert.informativeText = t.isEmpty
            ? "Type a whole number from 1 to 10 to rate this session."
            : "\u{201C}\(t)\u{201D} isn't a whole number from 1 to 10 (no decimals). Please try again."
        alert.addButton(withTitle: "OK")
        alert.window.level = .floating
        alert.window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        _ = runFloatingAlert(alert)
        return nil
    }

    private func promptRating(focus: String, title: String) -> (rating: Int, note: String, openSeconds: Int, applyTime: Bool) {
        NSApp.activate(ignoringOtherApps: true)
        let (accessory, ratingField, noteField, elapsed, apply) = ratingAccessory()
        let (timer, openSeconds, _) = startElapsedTimer(elapsed)
        defer { timer.invalidate() }
        while true {
            let alert = makeAlert()
            alert.messageText = title
            alert.informativeText = "Focus: \(focus)\n\nRate it 1–10 (optional note):"
            alert.addButton(withTitle: "Save")
            alert.accessoryView = accessory
            // Non-app-modal so the 🎯 menu stays usable while the prompt is up.
            _ = runFloatingAlert(alert, firstResponder: ratingField)
            if let rating = parseRating(ratingField.stringValue) {
                return (rating, noteField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines),
                        openSeconds(), apply.state == .on)
            }
        }
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
        let quitItem = appMenu.addItem(withTitle: "Quit focus",
                                       action: #selector(quitFocus), keyEquivalent: "q")
        quitItem.target = self   // so validateMenuItem can grey it out in strict mode
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
        menu.addItem(withTitle: "Add/subtract time", action: #selector(addTimeToCurrent), keyEquivalent: "")
        menu.addItem(withTitle: "Rename task", action: #selector(renameTask), keyEquivalent: "")
        menu.addItem(withTitle: "Abort task", action: #selector(abortTask), keyEquivalent: "")
        menu.addItem(withTitle: "Stop working", action: #selector(stopWorking), keyEquivalent: "")
        menu.addItem(withTitle: "Switch focus now", action: #selector(changeFocus), keyEquivalent: "")
        menu.addItem(.separator())
        // Subtasks (of the current task).
        menu.addItem(withTitle: "Add subtask", action: #selector(addSubtask), keyEquivalent: "")
        menu.addItem(withTitle: "Switch to subtask…", action: #selector(switchToSubtask), keyEquivalent: "")
        menu.addItem(.separator())
        // The queue.
        menu.addItem(withTitle: "See queue", action: #selector(showQueue), keyEquivalent: "")
        menu.addItem(withTitle: "Add to queue", action: #selector(addNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Add to front", action: #selector(preemptNextFocus), keyEquivalent: "")
        menu.addItem(withTitle: "Clear queue", action: #selector(clearQueue), keyEquivalent: "")
        menu.addItem(.separator())
        // Review.
        menu.addItem(withTitle: "See history", action: #selector(showHistory), keyEquivalent: "")
        menu.addItem(withTitle: "Rate unrated sessions", action: #selector(rateUnrated), keyEquivalent: "")
        menu.addItem(.separator())
        // App.
        menu.addItem(withTitle: "Show current task", action: #selector(toggleShowPill), keyEquivalent: "")
        menu.addItem(withTitle: "Settings", action: #selector(showSettings), keyEquivalent: "")
        menu.addItem(withTitle: "Quit focus", action: #selector(quitFocus), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }

    private func buildHUD() {
        hudWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 34),
                             styleMask: .borderless, backing: .buffered, defer: false)
        hudWindow.isOpaque = false
        hudWindow.backgroundColor = .clear
        hudWindow.hasShadow = true
        // Dragging is handled inside PillView (click vs. drag), not by the window, so a
        // click can resume a paused task without moving the pill.
        hudWindow.delegate = self                      // to notice user drags (windowDidMove)
        hudWindow.level = .statusBar                   // above normal windows
        hudWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let blur = PillView(frame: hudWindow.contentView!.bounds)
        blur.onResumeClick = { [weak self] in
            // Click the ⏸ icon to resume — only when paused (a click never pauses a running task).
            guard let self, self.pausedAt != nil else { return }
            self.togglePause()
        }
        hudPill = blur
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

        // The ⏸ icon sits at the left of the leaf line (the bottom line of the label). While
        // paused, make just that glyph the resume target — a generous box around it — so a
        // click there resumes, but clicks elsewhere on the pill only drag.
        if pausedAt != nil {
            let iconFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
            let g = ("⏸" as NSString).size(withAttributes: [.font: iconFont])
            hudPill.resumeHitRect = NSRect(x: padX - 4, y: padY - 3, width: g.width + 12, height: g.height + 6)
        } else {
            hudPill.resumeHitRect = nil
        }

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
