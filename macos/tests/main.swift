import Foundation

// Headless tests for the FocusCore data layer. Compiled WITHOUT main.swift (which
// would launch the app) — just FocusCore.swift + this file:
//     swiftc FocusCore.swift tests/main.swift -o <bin> && <bin>
// or simply: ./run-tests.sh
//
// These are deliberately written as *behavioral outcome* assertions ("interrupting
// records elapsed but preserves the original estimate") rather than assertions about
// SQL/column shape, so they survive the upcoming tasks+intervals refactor: only the
// thin read-helpers below would be re-pointed at the new schema, not the expectations.

// MARK: - Tiny assertion harness

var passed = 0
var failed = 0

func ok(_ cond: Bool, _ msg: String) {
    if cond { passed += 1 } else { failed += 1; print("  ✗ \(msg)") }
}

func eq<T: Equatable>(_ got: T, _ want: T, _ msg: String) {
    if got == want { passed += 1 }
    else { failed += 1; print("  ✗ \(msg): got \(got), want \(want)") }
}

// Assert an approximate integer (for wall-clock-derived durations).
func near(_ got: Int, _ want: Int, _ tol: Int, _ msg: String) {
    if abs(got - want) <= tol { passed += 1 }
    else { failed += 1; print("  ✗ \(msg): got \(got), want \(want)±\(tol)") }
}

func section(_ name: String, _ body: () -> Void) {
    print("• \(name)")
    body()
}

func freshDB() -> DB {
    let path = NSTemporaryDirectory() + "focus-test-\(UUID().uuidString).db"
    return DB(path: path)
}

// The session with the given id (tests create few rows, so a scan of recent() is fine).
func row(_ db: DB, _ id: Int64) -> SessionRow {
    if let r = db.recent().first(where: { $0.id == id }) { return r }
    fatalError("no session row with id \(id)")
}

// MARK: - Pure helpers

section("mmss") {
    eq(mmss(0), "0:00", "zero")
    eq(mmss(5), "0:05", "single digit seconds zero-padded")
    eq(mmss(65), "1:05", "minutes and seconds")
    eq(mmss(600), "10:00", "ten minutes")
    eq(mmss(3599), "59:59", "just under an hour")
    eq(mmss(3600), "60:00", "an hour stays MM:SS (no HH)")
    eq(mmss(-3), "0:00", "negative clamps to zero")
}

section("continuedName") {
    eq(continuedName("Write docs"), "Write docs (continued)", "first continuation")
    eq(continuedName("Write docs (continued)"), "Write docs (continued 2)", "second continuation")
    eq(continuedName("Write docs (continued 2)"), "Write docs (continued 3)", "third continuation")
    eq(continuedName("Ship (continued 10)"), "Ship (continued 11)", "double-digit increments")
    eq(continuedName(""), " (continued)", "empty focus")
}

section("parseDurationSeconds (plain minutes, or M:SS when a colon is present)") {
    // Plain number = whole minutes.
    eq(parseDurationSeconds("25") ?? -1, 1500, "plain minutes")
    eq(parseDurationSeconds("90") ?? -1, 5400, "plain minutes over an hour")
    eq(parseDurationSeconds("0") ?? -1, 0, "zero minutes parses (caller guards > 0)")
    eq(parseDurationSeconds("  3 ") ?? -1, 180, "surrounding whitespace trimmed")
    // Colon = minutes:seconds.
    eq(parseDurationSeconds("2:30") ?? -1, 150, "the requested case: 2:30 -> 150")
    eq(parseDurationSeconds("1:05") ?? -1, 65, "1:05 -> 65")
    eq(parseDurationSeconds("0:45") ?? -1, 45, "0:45 -> 45")
    eq(parseDurationSeconds(":30") ?? -1, 30, "leading colon means 0 minutes")
    eq(parseDurationSeconds("2:") ?? -1, 120, "trailing colon means 0 seconds")
    eq(parseDurationSeconds(" 2:05 ") ?? -1, 125, "whitespace around a M:SS value trimmed")
    eq(parseDurationSeconds("2:90") ?? -1, 210, "seconds aren't capped (m*60 + s)")
    // Unparseable -> nil.
    ok(parseDurationSeconds("") == nil, "empty is nil")
    ok(parseDurationSeconds("abc") == nil, "non-numeric is nil")
    ok(parseDurationSeconds("-5") == nil, "negative minutes rejected")
    ok(parseDurationSeconds("2:-5") == nil, "negative seconds rejected")
    ok(parseDurationSeconds("1:2:3") == nil, "two colons rejected")
    ok(parseDurationSeconds("2:xx") == nil, "non-numeric seconds rejected")
}

section("focus suggestions (random placeholder)") {
    ok(!focusSuggestions.isEmpty, "suggestion list is non-empty")
    ok(focusSuggestions.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }, "no blank suggestions")
    eq(Set(focusSuggestions).count, focusSuggestions.count, "no duplicate suggestions")
    let draws = (0..<200).map { _ in randomFocusSuggestion() }
    ok(draws.allSatisfy { focusSuggestions.contains($0) }, "every random pick is from the list")
    ok(Set(draws).count > 1, "random picks vary across draws")
}

// MARK: - Sessions: create / read

section("startSession stamps original == planned and leaves it active") {
    let db = freshDB()
    guard let id = db.startSession(reason: "launch", seconds: 1500, focus: "Write tests", originalSessionId: nil) else {
        ok(false, "startSession returned an id"); return
    }
    eq(db.sessionCount(), 1, "one session recorded")
    let r = row(db, id)
    eq(r.focus, "Write tests", "focus stored")
    eq(r.seconds, 1500, "planned seconds stored")
    eq(r.originalSeconds ?? -1, 1500, "original_seconds stamped equal to planned")
    ok(r.status == nil, "status NULL while active")
    ok(r.rating == nil, "no rating while active")
    ok(r.endedAt == nil, "not ended while active")
    ok(r.openSecondsStart == nil && r.openSecondsEnd == nil, "popup-open columns start NULL")
}

// MARK: - Add time vs. original estimate

section("Add time bumps planned seconds but never the original estimate") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.addTime(sessionId: id, seconds: 300)
    eq(row(db, id).seconds, 1800, "planned bumped by 300")
    eq(row(db, id).originalSeconds ?? -1, 1500, "original unchanged after first add")
    db.addTime(sessionId: id, seconds: 120)
    eq(row(db, id).seconds, 1920, "planned bumped again")
    eq(row(db, id).originalSeconds ?? -1, 1500, "original still the creation estimate")
    eq(db.plannedSecondsAtStart(id: id), 1500, "plannedSecondsAtStart returns the original")
}

section("Apply-time (addToDuration) adds to duration without touching original") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.addToDuration(id: id, seconds: 42)
    eq(row(db, id).seconds, 1542, "duration includes applied popup span")
    eq(row(db, id).originalSeconds ?? -1, 1500, "original unaffected by apply-time")
}

// MARK: - End paths

section("Interrupt records actual elapsed as duration but preserves the estimate") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.markInterrupted(id: id, elapsedSeconds: 640, rating: 7, note: "stopped early", openSecondsEnd: 12)
    let r = row(db, id)
    eq(r.seconds, 640, "duration overwritten with actual elapsed")
    eq(r.originalSeconds ?? -1, 1500, "original estimate preserved through interrupt")
    eq(r.status ?? "", "interrupted", "status = interrupted")
    eq(r.rating ?? -1, 7, "rating recorded")
    eq(r.note ?? "", "stopped early", "note recorded")
    eq(r.openSecondsEnd ?? -1, 12, "end popup-open seconds recorded")
    ok(r.endedAt != nil, "ended_at set")
}

section("Defer re-queues with the FULL original duration, not elapsed or the added total") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "Long task", originalSessionId: nil)!
    db.addTime(sessionId: id, seconds: 300)          // planned now 1800
    db.markDeferred(id: id, elapsedSeconds: 900)     // actually worked 15 min
    let r = row(db, id)
    eq(r.seconds, 900, "deferred row records actual elapsed")
    eq(r.status ?? "", "deferred", "status = deferred")
    eq(r.originalSeconds ?? -1, 1500, "original still the creation estimate")
    // The continuation is queued with the original estimate (1500), not 900 or 1800.
    let full = db.plannedSecondsAtStart(id: id)
    eq(full, 1500, "re-queue duration = full original")
    db.enqueue(focus: continuedName(r.focus), seconds: full, originalSessionId: id)
    let q = db.frontOfQueue()!
    eq(q.focus, "Long task (continued)", "continuation name")
    eq(q.seconds, 1500, "continuation carries the full original duration")
    eq(q.originalSessionId ?? -1, id, "continuation carries the chain root")
}

section("Complete via endSession records rating/note/end-popup") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.endSession(id: id, status: "completed", rating: 9, note: "nailed it", openSecondsEnd: 8, elapsedSeconds: 1490)
    let r = row(db, id)
    eq(r.status ?? "", "completed", "status = completed")
    eq(r.rating ?? -1, 9, "rating stored")
    eq(r.note ?? "", "nailed it", "note stored")
    eq(r.seconds, 1490, "actual elapsed stored as duration")
    eq(r.originalSeconds ?? -1, 1500, "original preserved through completion")
    eq(r.openSecondsEnd ?? -1, 8, "end popup-open recorded")
}

// MARK: - Popup-open accumulation

section("Popup-open seconds accumulate; columns are independent; unset stays NULL") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.addOpenSecondsStart(id: id, seconds: 5)
    db.addOpenSecondsStart(id: id, seconds: 3)
    eq(row(db, id).openSecondsStart ?? -1, 8, "start popup-open accumulates (5+3)")
    ok(row(db, id).openSecondsEnd == nil, "end popup-open still NULL")
    db.addOpenSecondsEnd(id: id, seconds: 10)
    db.addOpenSecondsEnd(id: id, seconds: 4)
    eq(row(db, id).openSecondsEnd ?? -1, 14, "end popup-open accumulates (10+4)")
    eq(row(db, id).openSecondsStart ?? -1, 8, "start unchanged by end writes")
}

// MARK: - Pauses

section("Pauses sum closed spans; open pauses are excluded; per-session") {
    let db = freshDB()
    let a = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    let b = db.startSession(reason: "launch", seconds: 1500, focus: "B", originalSessionId: nil)!
    eq(db.totalPausedSeconds(sessionId: a), 0, "no pauses yet")
    db.startPause(sessionId: a, at: Date()); db.endPause(sessionId: a, seconds: 120)
    eq(db.totalPausedSeconds(sessionId: a), 120, "first pause counted")
    db.startPause(sessionId: a, at: Date()); db.endPause(sessionId: a, seconds: 45)
    eq(db.totalPausedSeconds(sessionId: a), 165, "closed pauses sum")
    // An open pause (not yet resumed) is not counted.
    db.startPause(sessionId: b, at: Date())
    eq(db.totalPausedSeconds(sessionId: b), 0, "open pause excluded from total")
    eq(db.totalPausedSeconds(sessionId: a), 165, "pauses are per-session (A unaffected by B)")
}

section("closeOpenPause reconstructs a mid-pause crash from timestamps") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.startPause(sessionId: id, at: Date().addingTimeInterval(-200))  // paused 200s ago, process "died"
    eq(db.totalPausedSeconds(sessionId: id), 0, "open pause not yet counted")
    db.closeOpenPause(sessionId: id)
    near(db.totalPausedSeconds(sessionId: id), 200, 2, "closed pause ≈ elapsed wall time (ROUND, not truncate)")
    db.closeOpenPause(sessionId: id)  // idempotent: nothing open now
    near(db.totalPausedSeconds(sessionId: id), 200, 2, "second close is a no-op")
}

// MARK: - Queue ordering

section("Queue: enqueue / front / enqueueFront / reorder / remove / clear") {
    let db = freshDB()
    eq(db.queueCount(), 0, "empty to start")
    ok(db.frontOfQueue() == nil, "no front when empty")
    db.enqueue(focus: "A", seconds: 600)
    db.enqueue(focus: "B", seconds: 300)
    db.enqueue(focus: "C", seconds: 900)
    eq(db.queueItems().map { $0.focus }, ["A", "B", "C"], "FIFO order preserved")
    eq(db.queueCount(), 3, "three queued")
    eq(db.frontOfQueue()?.focus ?? "", "A", "front is the first enqueued")

    db.enqueueFront(focus: "Urgent", seconds: 120, originalSessionId: nil)
    eq(db.queueItems().map { $0.focus }, ["Urgent", "A", "B", "C"], "enqueueFront jumps to the front")
    eq(db.frontOfQueue()?.focus ?? "", "Urgent", "front now Urgent")

    let items = db.queueItems()
    let byName = Dictionary(uniqueKeysWithValues: items.map { ($0.focus, $0.id) })
    db.reorderQueue(ids: [byName["C"]!, byName["A"]!, byName["B"]!, byName["Urgent"]!])
    eq(db.queueItems().map { $0.focus }, ["C", "A", "B", "Urgent"], "reorder persists new order")

    db.removeFromQueue(id: byName["A"]!)
    eq(db.queueItems().map { $0.focus }, ["C", "B", "Urgent"], "remove drops one item, order intact")

    db.clearQueue()
    eq(db.queueCount(), 0, "clear empties the queue")
    ok(db.frontOfQueue() == nil, "no front after clear")
}

// MARK: - Persistence / migration idempotency

section("Data persists across reopen; reopening re-runs migrations harmlessly") {
    let path = NSTemporaryDirectory() + "focus-persist-\(UUID().uuidString).db"
    var id: Int64 = 0
    do {
        let db = DB(path: path)
        id = db.startSession(reason: "launch", seconds: 1500, focus: "Persisted", originalSessionId: nil)!
        db.endSession(id: id, status: "completed", rating: 6, note: "", elapsedSeconds: 1500)
    }  // first connection closed here (deinit)
    let db2 = DB(path: path)  // re-opens, re-runs all CREATE/ALTER migrations
    eq(db2.sessionCount(), 1, "row survived reopen")
    let r = row(db2, id)
    eq(r.focus, "Persisted", "focus survived")
    eq(r.rating ?? -1, 6, "rating survived")
    eq(r.originalSeconds ?? -1, 1500, "original survived")
}

// MARK: - New-model write API (Stage 1b): tasks + intervals lifecycle

section("startTask opens a task with one live interval; spent/remaining are right") {
    let db = freshDB()
    guard let (tid, iid) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Write tests") else {
        ok(false, "startTask returned ids"); return
    }
    let t = db.task(id: tid)
    ok(t != nil, "task exists")
    eq(t?.focus ?? "", "Write tests", "focus stored")
    eq(t?.estimateSeconds ?? -1, 1500, "estimate stored")
    ok(t?.status == nil, "status NULL while active")
    ok(t?.rating == nil, "no rating while active")
    eq(db.intervals(forTask: tid).count, 1, "one interval")
    ok(db.openInterval(taskId: tid)?.id == iid, "the interval is open (underway)")
    eq(db.spentSeconds(taskId: tid), 0, "spent 0 until an interval closes")
    eq(db.remainingSeconds(taskId: tid), 1500, "remaining = full estimate")
}

section("Add time bumps the TASK estimate (remaining), not spent") {
    let db = freshDB()
    let (tid, _) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "A")!
    db.addTimeToTask(id: tid, seconds: 300)
    eq(db.task(id: tid)?.estimateSeconds ?? -1, 1800, "estimate bumped by 300")
    eq(db.remainingSeconds(taskId: tid), 1800, "remaining grows with estimate")
    eq(db.spentSeconds(taskId: tid), 0, "spent unaffected by add-time")
}

section("Working across intervals accumulates on the same task (cohesion)") {
    let db = freshDB()
    let (tid, i1) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Deep work")!
    db.endInterval(id: i1, elapsedSeconds: 600)          // first chunk
    eq(db.spentSeconds(taskId: tid), 600, "spent = first chunk")
    eq(db.remainingSeconds(taskId: tid), 900, "remaining = estimate − spent")
    ok(db.openInterval(taskId: tid) == nil, "no open interval between chunks (paused/queued)")
    let i2 = db.startInterval(taskId: tid, reason: "resume")!  // resume same task
    eq(db.intervals(forTask: tid).count, 2, "two intervals, one task — no new (continued) task")
    db.endInterval(id: i2, elapsedSeconds: 800)
    eq(db.spentSeconds(taskId: tid), 1400, "spent sums both chunks")
    eq(db.remainingSeconds(taskId: tid), 100, "remaining reflects both chunks")
}

section("Complete / interrupt / defer set the task's headline rating (not per-interval)") {
    let db = freshDB()
    let c = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "C")!
    db.endInterval(id: c.intervalId, elapsedSeconds: 1490, openSecondsEnd: 8)
    db.finishTask(id: c.taskId, status: "completed", rating: 9, note: "nailed it")
    let ct = db.task(id: c.taskId)
    eq(ct?.status ?? "", "completed", "completed status")
    eq(ct?.rating ?? -1, 9, "task rating set")
    eq(ct?.note ?? "", "nailed it", "task note set")
    eq(db.openInterval(taskId: c.taskId)?.id ?? -1, -1, "interval closed")
    eq(db.intervals(forTask: c.taskId).first?.openSecondsEnd ?? -1, 8, "end popup-open recorded on interval")

    let a = db.startTask(reason: "launch", estimateSeconds: 900, focus: "Abort me")!
    db.endInterval(id: a.intervalId, elapsedSeconds: 120)
    db.finishTask(id: a.taskId, status: "interrupted", rating: 3, note: "gave up")
    eq(db.task(id: a.taskId)?.rating ?? -1, 3, "abort can still carry a task rating")

    let d = db.startTask(reason: "launch", estimateSeconds: 900, focus: "Defer me")!
    db.endInterval(id: d.intervalId, elapsedSeconds: 200)
    db.finishTask(id: d.taskId, status: "deferred")
    eq(db.task(id: d.taskId)?.status ?? "", "deferred", "deferred status")
    ok(db.task(id: d.taskId)?.rating == nil, "defer leaves rating unset")
}

section("Apply-time credits an interval; rename edits the task") {
    let db = freshDB()
    let (tid, iid) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Old name")!
    db.endInterval(id: iid, elapsedSeconds: 600)
    db.addToInterval(id: iid, seconds: 42)
    eq(db.spentSeconds(taskId: tid), 642, "apply-time adds to the interval's actual")
    db.renameTask(id: tid, focus: "New name")
    eq(db.task(id: tid)?.focus ?? "", "New name", "rename updates the task focus")
}

section("enqueueTask: fresh items mint a task later, deferred items carry task_id") {
    let db = freshDB()
    db.enqueueTask(focus: "Fresh A", estimateSeconds: 600)                 // no task yet
    db.enqueueTask(focus: "Fresh B", estimateSeconds: 300)
    db.enqueueTask(focus: "Resume me", estimateSeconds: 1500, taskId: 42)  // resume existing task 42
    eq(db.queueItems().map { $0.focus }, ["Fresh A", "Fresh B", "Resume me"], "FIFO order")
    ok(db.queueItems()[0].taskId == nil, "fresh item has no task_id")
    eq(db.queueItems()[2].taskId ?? -1, 42, "deferred item carries its task_id")
    db.enqueueTask(focus: "Urgent", estimateSeconds: 120, front: true)
    eq(db.queueItems().map { $0.focus }, ["Urgent", "Fresh A", "Fresh B", "Resume me"], "front: jumps the queue")
    eq(db.frontOfQueue()?.focus ?? "", "Urgent", "front is Urgent")
    ok(db.frontOfQueue()?.taskId == nil, "front carries its (nil) task_id")
}

section("taskHistory rolls up one row per task with actual/interval-count/span") {
    let db = freshDB()
    // A two-interval task and a one-interval task.
    let (t1, i1) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Big task")!
    db.endInterval(id: i1, elapsedSeconds: 600)
    let i1b = db.startInterval(taskId: t1, reason: "resume")!
    db.endInterval(id: i1b, elapsedSeconds: 800)
    db.finishTask(id: t1, status: "completed", rating: 8, note: "done")
    let (t2, i2) = db.startTask(reason: "launch", estimateSeconds: 1200, focus: "Small task")!
    db.endInterval(id: i2, elapsedSeconds: 1100)
    db.finishTask(id: t2, status: "completed", rating: 6)

    let hist = db.taskHistory()
    eq(hist.count, 2, "one row per task")
    guard let big = hist.first(where: { $0.id == t1 }) else { ok(false, "big task in history"); return }
    eq(big.focus, "Big task", "focus")
    eq(big.estimateSeconds ?? -1, 1500, "estimate")
    eq(big.actualSeconds, 1400, "actual = sum of both intervals (600+800)")
    eq(big.intervalCount, 2, "interval count")
    eq(big.rating ?? -1, 8, "task rating")
    ok(big.startedAt != nil && big.endedAt != nil, "has a start/end span")
    guard let small = hist.first(where: { $0.id == t2 }) else { ok(false, "small task in history"); return }
    eq(small.actualSeconds, 1100, "single-interval actual")
    eq(small.intervalCount, 1, "single interval")
}

// MARK: - Migration: sessions -> tasks + intervals

section("migrateSessionsToTasks merges a continued chain into one task") {
    let db = freshDB()
    // Seed a legacy shape via the current API: a two-fragment chain + a standalone.
    let f1 = db.startSession(reason: "launch", seconds: 1500, focus: "Deep work", originalSessionId: nil)!
    db.markInterrupted(id: f1, elapsedSeconds: 600, rating: 4, note: "got interrupted")
    let f2 = db.startSession(reason: "resume", seconds: 1500, focus: "Deep work (continued)", originalSessionId: f1)!
    db.addTime(sessionId: f2, seconds: 300)   // bumps planned; original stays 1500
    db.endSession(id: f2, status: "completed", rating: 9, note: "done", openSecondsEnd: 5, elapsedSeconds: 800)
    let s1 = db.startSession(reason: "launch", seconds: 1200, focus: "Quick email", originalSessionId: nil)!
    db.endSession(id: s1, status: "completed", rating: 7, note: "", elapsedSeconds: 1100)

    db.migrateSessionsToTasks()

    eq(db.allTasks().count, 2, "two tasks (chain collapsed to one) + standalone")
    eq(db.intervalCount(), 3, "three intervals total")

    let tasks = db.allTasks()
    guard let chain = tasks.first(where: { $0.id == f1 }) else { ok(false, "chain task exists"); return }
    eq(chain.focus, "Deep work", "task focus = clean original name (no '(continued)')")
    eq(chain.estimateSeconds ?? -1, 1500, "estimate = original, not the add-time-bumped total")
    eq(chain.status ?? "", "completed", "status from the LAST fragment")
    eq(chain.rating ?? -1, 9, "rating collapsed to the last fragment's (9, not 4)")
    eq(chain.note ?? "", "done", "note from the last fragment")

    let iv = db.intervals(forTask: f1)
    eq(iv.map { $0.seconds }, [600, 800], "two intervals, actual elapsed each, earliest first")
    eq(iv.first?.reason ?? "", "launch", "interval keeps its reason")
    eq(iv.last?.openSecondsEnd ?? -1, 5, "interval keeps its popup-open seconds")
    // Per-fragment ratings are preserved losslessly on the intervals, even though the
    // task's headline rating is the last fragment's.
    eq(iv.first?.rating ?? -1, 4, "first interval keeps its own rating (4)")
    eq(iv.last?.rating ?? -1, 9, "last interval keeps its own rating (9)")

    guard let solo = tasks.first(where: { $0.id == s1 }) else { ok(false, "standalone task exists"); return }
    eq(solo.focus, "Quick email", "standalone focus")
    eq(solo.estimateSeconds ?? -1, 1200, "standalone estimate")
    eq(solo.rating ?? -1, 7, "standalone rating")
    eq(db.intervals(forTask: s1).map { $0.seconds }, [1100], "standalone has one interval")
}

section("migrateSessionsToTasks is idempotent") {
    let db = freshDB()
    let id = db.startSession(reason: "launch", seconds: 1500, focus: "A", originalSessionId: nil)!
    db.endSession(id: id, status: "completed", rating: 5, note: "", elapsedSeconds: 1500)
    db.migrateSessionsToTasks()
    db.migrateSessionsToTasks()   // second call must not duplicate
    eq(db.allTasks().count, 1, "still one task after re-running")
    eq(db.intervalCount(), 1, "still one interval after re-running")
}

// MARK: - Summary

print("")
if failed == 0 {
    print("✓ all \(passed) assertions passed")
    exit(0)
} else {
    print("✗ \(failed) failed, \(passed) passed")
    exit(1)
}
