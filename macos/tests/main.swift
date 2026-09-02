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

// MARK: - Pauses

section("Pauses sum closed spans; open pauses are excluded; per-interval") {
    let db = freshDB()
    let (_, a) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "A")!
    let (_, b) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "B")!
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
    let (_, id) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "A")!
    db.startPause(sessionId: id, at: Date().addingTimeInterval(-200))  // paused 200s ago, process "died"
    eq(db.totalPausedSeconds(sessionId: id), 0, "open pause not yet counted")
    db.closeOpenPause(sessionId: id)
    near(db.totalPausedSeconds(sessionId: id), 200, 2, "closed pause ≈ elapsed wall time (ROUND, not truncate)")
    db.closeOpenPause(sessionId: id)  // idempotent: nothing open now
    near(db.totalPausedSeconds(sessionId: id), 200, 2, "second close is a no-op")
}

section("openPauseStart: the open pause's start, nil when running (restart keeps paused)") {
    let db = freshDB()
    let (_, id) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "A")!
    ok(db.openPauseStart(sessionId: id) == nil, "not paused → nil")
    let at = Date().addingTimeInterval(-200)   // paused 200s ago, then process "died"
    db.startPause(sessionId: id, at: at)
    if let started = db.openPauseStart(sessionId: id) {
        near(Int(started.timeIntervalSince(at).rounded()), 0, 2, "returns the open pause's started_at")
    } else {
        ok(false, "open pause should have a start")
    }
    db.endPause(sessionId: id, seconds: 200)
    ok(db.openPauseStart(sessionId: id) == nil, "closed pause → nil (would auto-resume)")
}

// MARK: - Queue ordering

section("Queue: enqueueTask / front / reorder / remove / clear") {
    let db = freshDB()
    eq(db.queueCount(), 0, "empty to start")
    ok(db.frontOfQueue() == nil, "no front when empty")
    db.enqueueTask(focus: "A", estimateSeconds: 600)
    db.enqueueTask(focus: "B", estimateSeconds: 300)
    db.enqueueTask(focus: "C", estimateSeconds: 900)
    eq(db.queueItems().map { $0.focus }, ["A", "B", "C"], "FIFO order preserved")
    eq(db.queueCount(), 3, "three queued")
    eq(db.frontOfQueue()?.focus ?? "", "A", "front is the first enqueued")

    db.enqueueTask(focus: "Urgent", estimateSeconds: 120, front: true)
    eq(db.queueItems().map { $0.focus }, ["Urgent", "A", "B", "C"], "front: jumps to the front")
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
    var tid: Int64 = 0
    do {
        let db = DB(path: path)
        let started = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Persisted")!
        tid = started.taskId
        db.endInterval(id: started.intervalId, elapsedSeconds: 1500)
        db.finishTask(id: tid, status: "completed", rating: 6)
    }  // first connection closed here (deinit)
    let db2 = DB(path: path)  // re-opens, re-runs all CREATE/ALTER migrations
    eq(db2.taskCount(), 1, "task survived reopen")
    let t = db2.task(id: tid)
    eq(t?.focus ?? "", "Persisted", "focus survived")
    eq(t?.rating ?? -1, 6, "rating survived")
    eq(t?.estimateSeconds ?? -1, 1500, "estimate survived")
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

section("enqueueTask: fresh items mint a queued task now, deferred items carry task_id") {
    let db = freshDB()
    db.enqueueTask(focus: "Fresh A", estimateSeconds: 600)                 // mints a queued task
    db.enqueueTask(focus: "Fresh B", estimateSeconds: 300)
    db.enqueueTask(focus: "Resume me", estimateSeconds: 1500, taskId: 42)  // resume existing task 42
    let items = db.queueItems()
    eq(items.count, 3, "three rows, FIFO")
    // Every fresh item now references a real task from creation; focus is read from it.
    guard let aTid = items[0].taskId else { ok(false, "fresh item has a task_id"); return }
    eq(items[0].focus, "Fresh A", "fresh item's focus comes from its task (via JOIN)")
    eq(items[1].focus, "Fresh B", "fresh item's focus comes from its task (via JOIN)")
    eq(db.task(id: aTid)?.status ?? "", "queued", "fresh item's task is 'queued' (never started)")
    eq(db.task(id: aTid)?.estimateSeconds ?? -1, 600, "estimate stamped on the queued task")
    eq(items[2].taskId ?? -1, 42, "deferred item carries its task_id")
    ok(db.taskHistory().isEmpty, "queued (never-started) plans stay out of history")
    db.enqueueTask(focus: "Urgent", estimateSeconds: 120, front: true)
    eq(db.frontOfQueue()?.focus ?? "", "Urgent", "front is Urgent (focus via task)")
    ok(db.frontOfQueue()?.taskId != nil, "front carries its minted task_id")
}

section("Queued task: starting it clears 'queued' and it enters history; remove abandons") {
    let db = freshDB()
    let tid = db.enqueueTask(focus: "Plan it", estimateSeconds: 600)!
    eq(db.task(id: tid)?.status ?? "", "queued", "starts life queued")
    // Start it: first interval clears the queued status.
    let iid = db.startInterval(taskId: tid, reason: "queue")!
    ok(db.task(id: tid)?.status == nil, "starting clears 'queued' → active")
    eq(db.taskHistory().count, 1, "now visible in history")
    db.endInterval(id: iid, elapsedSeconds: 120)

    // A second, never-started plan that we clear → abandoned, still in history.
    let tid2 = db.enqueueTask(focus: "Bail on it", estimateSeconds: 300)!
    db.clearQueue()
    eq(db.task(id: tid2)?.status ?? "", "abandoned", "clearQueue abandons never-started plans")
    eq(db.queueItems().count, 0, "queue emptied")
    ok(db.taskHistory().contains { $0.id == tid2 }, "abandoned plan shows in history")
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

section("intervalHistory: flat timeline joined to task focus; deleteIntervals") {
    let db = freshDB()
    let (t1, i1) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Alpha")!
    db.endInterval(id: i1, elapsedSeconds: 600)
    let i2 = db.startInterval(taskId: t1, reason: "resume")!
    db.endInterval(id: i2, elapsedSeconds: 300)
    let (_, i3) = db.startTask(reason: "launch", estimateSeconds: 1200, focus: "Beta")!
    db.endInterval(id: i3, elapsedSeconds: 900)

    let hist = db.intervalHistory()
    eq(hist.count, 3, "one row per interval (not per task)")
    // Newest first: i3 (Beta) then i2 then i1 (all created in ascending id order).
    eq(hist.first?.id ?? -1, i3, "newest interval first")
    eq(hist.first?.taskFocus ?? "", "Beta", "interval carries its task's focus")
    ok(hist.contains { $0.id == i1 && $0.taskFocus == "Alpha" }, "Alpha's first interval present with its focus")
    eq(hist.map { $0.seconds }.reduce(0, +), 1800, "durations are the per-interval actuals")

    db.deleteIntervals(ids: [i2])
    eq(db.intervalHistory().count, 2, "deleteIntervals removes just that interval")
    eq(db.spentSeconds(taskId: t1), 600, "task rollup shrinks to the remaining interval")
    ok(db.task(id: t1) != nil, "the task itself is untouched")
}

section("taskHistory Ended = finish time only ('—' while in progress)") {
    let db = freshDB()
    // Finished task → Ended set.
    let done = db.startTask(reason: "launch", estimateSeconds: 600, focus: "Done")!
    db.endInterval(id: done.intervalId, elapsedSeconds: 500)
    db.finishTask(id: done.taskId, status: "completed", rating: 8)
    // Closed interval but NOT finished (deferred / paused-in-queue) → still no Ended.
    let (prog, pi) = db.startTask(reason: "launch", estimateSeconds: 600, focus: "InProgress")!
    db.endInterval(id: pi, elapsedSeconds: 200)
    // Running task (open interval).
    let (run, _) = db.startTask(reason: "launch", estimateSeconds: 600, focus: "Running")!

    let hist = db.taskHistory()
    func th(_ id: Int64) -> TaskHistoryRow { hist.first { $0.id == id }! }
    ok(th(done.taskId).endedAt != nil, "finished task has an Ended (finish) time")
    ok(th(prog).endedAt == nil, "closed-interval-but-unfinished task shows no Ended")
    ok(th(prog).lastActivity != nil, "…but has a lastActivity (for recency sorting)")
    ok(th(run).endedAt == nil, "running task shows no Ended")
    ok(th(run).lastActivity != nil, "running task still has a lastActivity")
}

section("Give up: abandoned task gets a finish time and leaves the queue") {
    let db = freshDB()
    let (tid, iid) = db.startTask(reason: "launch", estimateSeconds: 600, focus: "Stale")!
    db.endInterval(id: iid, elapsedSeconds: 120)                 // worked a bit, then...
    db.enqueueTask(focus: "Stale", estimateSeconds: 480, taskId: tid)  // ...deferred into the queue
    ok(db.taskHistory().first { $0.id == tid }?.endedAt == nil, "in-progress → no Ended (floats)")

    // Give up: mark abandoned + drop from queue (what the controller's abandon() does).
    db.finishTask(id: tid, status: "abandoned")
    db.removeQueuedTask(taskId: tid)

    let row = db.taskHistory().first { $0.id == tid }
    ok(row?.endedAt != nil, "abandoned task now has an Ended (finish) time → sorts down")
    eq(row?.status ?? "", "abandoned", "status shows abandoned")
    eq(row?.actualSeconds ?? -1, 120, "time worked so far is preserved")
    ok(db.queueItems().first { $0.taskId == tid } == nil, "removed from the queue")
}

section("subtasks: ancestorTasks walks parent_task_id; childTasks lists children") {
    let db = freshDB()
    let (a, _) = db.startTask(reason: "launch", estimateSeconds: 3600, focus: "A")!
    let (b, _) = db.startTask(reason: "sub", estimateSeconds: 600, focus: "B", parentTaskId: a)!
    let (c, _) = db.startTask(reason: "sub", estimateSeconds: 300, focus: "C", parentTaskId: b)!
    let (b2, _) = db.startTask(reason: "sub", estimateSeconds: 200, focus: "B2", parentTaskId: a)!

    eq(db.task(id: b)?.parentTaskId ?? -1, a, "B's parent is A")
    eq(db.task(id: c)?.parentTaskId ?? -1, b, "C's parent is B")
    // Ancestors of the deepest task, nearest-first up to the root (the restart walk).
    eq(db.ancestorTasks(of: c).map { $0.focus }, ["B", "A"], "ancestors of C = [B, A]")
    eq(db.ancestorTasks(of: a).count, 0, "top-level task has no ancestors")
    eq(db.ancestorTasks(of: b2).map { $0.focus }, ["A"], "ancestors of B2 = [A]")
    // Direct children.
    eq(db.childTasks(of: a).map { $0.focus }, ["B", "B2"], "A's direct children, oldest first")
    eq(db.childTasks(of: b).map { $0.focus }, ["C"], "B's child")
    eq(db.childTasks(of: c).count, 0, "leaf has no children")
}

section("Original estimate is stamped at creation and never drifts (add-time grows only the working estimate)") {
    let db = freshDB()
    let (tid, _) = db.startTask(reason: "launch", estimateSeconds: 1500, focus: "Calibrate me")!
    func hist() -> TaskHistoryRow { db.taskHistory().first { $0.id == tid }! }
    eq(hist().estimateSeconds ?? -1, 1500, "working estimate = 1500 at start")
    eq(hist().originalEstimateSeconds ?? -1, 1500, "original stamped = 1500 at start")
    db.addTimeToTask(id: tid, seconds: 600)
    eq(hist().estimateSeconds ?? -1, 2100, "add-time grows the working estimate")
    eq(hist().originalEstimateSeconds ?? -1, 1500, "…but the original is frozen (calibration baseline)")
}

section("Migration backfills the original estimate from the old original_seconds") {
    let db = freshDB()
    let s = db.insertLegacySession(seconds: 900, focus: "Legacy", originalSeconds: 1500, status: "completed", rating: 8)
    db.migrateSessionsToTasks()
    let row = db.taskHistory().first { $0.id == s }
    eq(row?.estimateSeconds ?? -1, 1500, "working estimate from old original_seconds")
    eq(row?.originalEstimateSeconds ?? -1, 1500, "original estimate backfilled to match")
    eq(row?.actualSeconds ?? -1, 900, "actual is the elapsed")
}

// MARK: - Migration: sessions -> tasks + intervals

section("migrateSessionsToTasks merges a continued chain into one task") {
    let db = freshDB()
    // Seed a legacy shape via the current API: a two-fragment chain + a standalone.
    let f1 = db.insertLegacySession(seconds: 600, focus: "Deep work", originalSeconds: 1500,
                                    status: "interrupted", rating: 4, note: "got interrupted")
    let f2 = db.insertLegacySession(seconds: 800, focus: "Deep work (continued)", originalSeconds: 1500,
                                    status: "completed", rating: 9, note: "done",
                                    originalSessionId: f1, openSecondsEnd: 5)
    _ = f2
    let s1 = db.insertLegacySession(seconds: 1100, focus: "Quick email", originalSeconds: 1200,
                                    status: "completed", rating: 7)

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
    db.insertLegacySession(seconds: 1500, focus: "A", originalSeconds: 1500, status: "completed", rating: 5)
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
