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
- **Quit-while-paused → relaunch stays paused** (restart detects the leaf's still-open
  pause via `openPauseStart` and restores the frozen state; hitting Resume then folds
  the whole downtime into the pause). Previously it auto-resumed.
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
  - [x] **1c-2 (cleanup)** — deleted the ~21 dead old-session DB methods
    (startSession/endSession/markInterrupted/markDeferred/addTime/addToDuration/
    plannedSecondsAtStart/renameSession/recent/openSessions/setRating/… + enqueue/
    enqueueFront) and the SessionRow/ActiveSession structs + continuedName. Kept a
    small `insertLegacySession` fixture writer for the migration tests. FocusCore
    dropped ~300 lines; redundant old behavioral tests removed. 139 assertions pass.
- [~] **2 — display.** History rollup columns (Actual/Estimate/Intervals) done in
  1c. Added a **Tasks ⇄ Intervals** toggle to See History: Intervals shows the
  global chronological interval timeline (Started/Duration/Rating/Reason/Task),
  with interval-level copy + delete. Queue-remaining display still TODO.
- [~] **3 (separate) — subtasks** via `parent_task_id` — design locked (below).

## Subtasks — locked design

A **subtask is a task with `parent_task_id` set**, running with **concurrent
clocks**: starting a subtask does NOT pause the parent — both count down at once.

- **Start**: "Add subtask" while a task is active → prompt focus + duration; it
  pushes onto an in-memory **stack** (parent → subtask → sub-subtask…). The
  deepest (leaf) task is what you're actively doing.
- **Time accounting**: the parent's own interval keeps running through the
  subtask, so it already *contains* the subtask time. Therefore **parent actual =
  total effort incl. subtasks — do NOT sum parent + child** (that double-counts the
  overlap). Subtasks are a breakdown *within* the parent's total.
- **Parent time's-up mid-subtask**: the parent does NOT interrupt — its pill goes
  into **overtime (red, counting up)**; its rating prompt fires when the subtask
  finishes and you return to it.
- **Pills**: the main task pill on top; the active subtask as a **smaller / tinted
  pill below** it. Both tick.
- **Pause** freezes the whole stack. **Restart** reconstructs the running stack by
  taking the newest open interval as the leaf and **walking `parent_task_id`
  upward**; every task in the chain has its own open interval to resume. Open
  intervals not in the chain are swept as orphans.
- **Finish / Abandon a subtask** → pop to the parent (which keeps ticking), not the
  idle "what's next?" prompt.
- **Leaving the current leaf** — a small family sharing one primitive ("suspend the
  leaf/stack, re-queuing with parent links so it's resumable"):
  - **Switch focus now** — suspend + start a replacement. When nested, a checkbox
    picks *just this subtask* (drop to the still-ticking parent, new focus is a
    **sibling** under it; queue-pick filtered to that parent's set-aside subtasks) vs
    *the whole task* (suspend the entire stack, new focus is top-level). Top-level =
    no checkbox.
  - **Stop working** — the *no-replacement* sibling of Switch: suspend and go idle,
    or (subtask scope) drop to the parent. No rating.
  - Suspending re-queues the **leaf** (not the root); resume rebuilds the stack via
    the `parent_task_id` walk (which goes *up*). Resuming a set-aside subtask while
    its parent is already live **attaches** under it (`rebuildAncestors: false`)
    rather than duplicating the parent.
  - **Complete / Abort** still finish the leaf and pop to the parent.
- **Queue**: subtasks are started ad-hoc and are not queued individually. Rating
  lives on the child task.

### Implementation stages
- [ ] **S1 — FocusCore reads**: `ancestorTasks(of:)` (the parent_task_id walk),
  `childTasks(of:)`, tests. Safe/additive.
- [x] **S2 — controller stack** (built; needs live testing). Leaf stays in the
  existing state vars; ancestors ride an `ancestors: [Frame]` stack. "Add subtask"
  pushes the leaf and starts a concurrent child. The pill is now a multi-line
  attributed string (root on top, subtask leaf prominent below, ancestors tinted,
  overtime in red "+M:SS"). Pause freezes/resumes the whole stack. Complete/Abort/
  time's-up close the leaf then pop to the parent (which keeps ticking; overtime
  fires on return). Restart rebuilds the whole stack via the `parent_task_id` walk
  (single task keeps the Resume prompt; a subtask stack auto-adopts). Switch-during-
  subtask is disabled (S3). *Known edges: add-subtask-while-paused; abort-while-
  paused-with-stack.*
- [x] **S3 — whole-stack pre-empt + stack-rebuilding resume** (needs live testing).
  "Switch focus now" is re-enabled inside a subtask: it closes every level's
  interval, re-queues the leaf, and starts the new focus. `beginSession(resumeTaskId:)`
  now rebuilds the ancestor stack (reopens each ancestor as a running frame via the
  `parent_task_id` walk), so resuming a suspended stack from the queue restores the
  whole thing ticking. Restart already rebuilt from open intervals (S2).
- [x] **S4 — History**: the Tasks view is now an `NSOutlineView` — top-level tasks
  with subtasks nested underneath (Focus is the outline column, so subtasks indent
  and get a ▸). Degrades to a flat list for tasks with no subtasks. Sort works per
  level; copy indents subtasks; delete removes a task's whole subtree; give-up/
  abandon operate on the selected task nodes. Intervals mode is the same outline
  rendered flat. Parent Actual = total incl. subtasks (children are a breakdown,
  not additive). — `taskHistory` now returns `parent_task_id`.

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
