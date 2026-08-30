# Refactor: `sessions` → `tasks` + `intervals`

Splitting the conflated `sessions` table into two concepts:

- **`tasks`** — the unit of *identity*: focus, estimate, rating, note, status, and
  `parent_task_id` (the hook for subtasks later). One per logical task.
- **`intervals`** — one *timed chunk* of work on a task (today's `sessions` row):
  `started_at`, `ended_at`, actual `seconds`, `reason`, popup-open seconds.

`remaining = estimate − Σ interval.seconds`. A continued/pre-empted task stops
spawning `(continued)` chains — resuming just adds another interval to the same
task. That "one cohesive task" is the whole point, and it's the foundation the
Subtasks feature builds on.

## Decisions (locked)

- **Conservative core**, not full unification: `pauses` / `preempts` /
  `time_additions` keep their tables (pauses stay sub-interval spans, not folded
  into gaps); the queue is not turned into a task-status. Smallest blast radius.
- **Refactor first, subtasks later.**
- **Ids preserved** across migration (`task.id` = chain-root session id,
  `interval.id` = old session id) so the aux tables keep referencing by the same
  ids without a repoint.
- **Rating**: the headline rating lives on the **task** (one per task — you set it
  once at completion; interrupt/defer/pre-empt never stop to ask). But
  `intervals.rating` is kept as a nullable, UI-unused column so the migration is
  **lossless** (each old fragment's rating rides its interval) and per-interval
  rating stays a future option with no further migration. `tasks.rating` is
  seeded from the *last* fragment's rating/note/status.
- **Resume = continue from remaining** (`estimate − spent`), not a fresh full timer.
  Defer/pre-empt/queue all resume the same task's remaining; an over-spent task
  resumes at 0:00 (Add time / Complete). Timer and the queue's "remaining" agree.
- **Quit-while-paused → relaunch auto-resumes** (unchanged from today).
- **Estimate** for migrated tasks = the earliest fragment's `original_seconds`
  (the original plan; add-time is not folded in for legacy rows). New tasks bump
  `tasks.estimate_seconds` directly.

## Staging

- [x] **1a — schema + migration, isolated.** Add `tasks`/`intervals` (additive,
  empty), `migrateSessionsToTasks()` (not yet wired into `init`), read helpers,
  tests. App untouched. *Verified on a copy of the real DB: 425 sessions → 352
  tasks + 425 intervals, 38 merged chains.* — commit `0a67440`
- [x] **1b — port the DB API** to tasks+intervals (still additive, app untouched).
  Part 1: lifecycle (startTask / startInterval / endInterval / addToInterval /
  finishTask / addTimeToTask / renameTask + task/spent/remaining/openInterval reads).
  Part 2: queue-by-task (`enqueueTask`, `queue.task_id`, `QueueItem.taskId`) and
  history-by-task (`taskHistory` → one row per task with actual/interval-count/span).
  Pauses reuse the existing id-agnostic methods (keyed to the interval id in 1c).
  New API re-asserts today's outcomes. — commits `c44701e`, `<this>`
- [x] **1c — wire it live.** Migration runs from `init` (`1c-0`, `29fcb2b`).
  FocusCore reads for the controller (`1c prep`, `6c582c3`). `AppController`
  rewired to track a current **task + open interval**: beginSession creates a task
  or resumes one (new interval, countdown from remaining), all four end-paths →
  endInterval + finishTask, defer/pre-empt re-queue the same task by `task_id`,
  pauses key off the interval, restart reconstructs from the open interval, and
  See History renders `taskHistory()` (one row per task: Actual / Estimate /
  Intervals / Rating / Status / Focus / Note). `(continued)` naming is gone. App
  compiles + all 157 FocusCore tests pass. **Caveat: the controller rewire itself
  isn't unit-tested — needs a live run.** — commit `<this>`
  - [ ] **1c-2 (cleanup)** — delete the now-unused old session methods + their
    tests once a live run confirms the flip.
- [ ] **2 — display.** History/Queue columns: Estimate / Actual / Remaining;
  queue shows remaining; optional interval/subtask drill-down.
- [ ] **3 (separate) — subtasks** via `parent_task_id`: second pill, per-subtask
  timer/rating.

## Safety

- Live DB backed up: `~/focus/focus.db.bak-2026-08-29`.
- Migration is idempotent (`intervalCount()==0` guard) and wrapped in a
  transaction.
- Every stage lands on a branch with `./run-tests.sh` green before merge.

## Known migration edges (acceptable)

- Orphan continuations (root fragment deleted) take the earliest *surviving*
  fragment's focus, which may still carry `(continued)`. Rare.
- Per-fragment ratings are preserved on `intervals.rating`; the task's headline
  rating is the last fragment's.
- Pre-existing bad data (e.g. a session left running for ~24h) carries over as an
  outsized interval — a data-cleanup matter, not a migration bug.
