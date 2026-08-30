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
- **Estimate** for migrated tasks = the earliest fragment's `original_seconds`
  (the original plan; add-time is not folded in for legacy rows). New tasks bump
  `tasks.estimate_seconds` directly.

## Staging

- [x] **1a — schema + migration, isolated.** Add `tasks`/`intervals` (additive,
  empty), `migrateSessionsToTasks()` (not yet wired into `init`), read helpers,
  tests. App untouched. *Verified on a copy of the real DB: 425 sessions → 352
  tasks + 425 intervals, 38 merged chains.* — commit `0a67440`
- [ ] **1b — port the DB API** to tasks+intervals (start task / attach interval /
  end paths / queue / history / pauses), preserving observable behavior. Rewrite
  the test suite against the new API using the current outcomes as the spec.
- [ ] **1c — wire it live.** Call the migration from `init` behind the
  `intervalCount()==0` guard; rewire `AppController` (beginSession/adopt/end
  paths/restore) so a continuation attaches an interval to the *same* task.
  History shows one row per task; `(continued)` naming goes away.
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
