# Code review — duplication & high-value refactors

Whole-repo review of `macos/main.swift` (~2,950 lines) and `macos/FocusCore.swift`
(~890 lines), focused on **code duplication and cleanup leverage** (not a bug hunt).
Findings are ranked by leverage; one also carries a latent correctness inconsistency.

_Captured 2026-09-08 to tackle later. Line numbers are approximate and will drift as
the files change — treat them as starting points, not exact anchors._

---

## The one actual bug (not just duplication)

### Two duration parsers with different rules

Two functions parse the same-looking "minutes or M:SS" input, with **different validation**:

- **`parseDurationSeconds`** (`FocusCore.swift:27`) — used by the **Start a focus / Add
  subtask** duration field. Lenient: accepts `1:90` → 150s, `0:75` → 75s, `:30`, `2:`,
  and zero.
- **`parseDuration`** (`main.swift`) — used by **Add time**, **time's-up Add time**, and
  **Lock settings** (the latter two via `parseSignedDuration`, which wraps `parseDuration`).
  Strict: rejects seconds ≥ 60 and non-positive.

**Effect:** typing `1:90` starts a 2:30 focus but is rejected as invalid in Add time.
Same-shaped input box, two behaviors. Low-severity (edge input), but a genuine
inconsistency worth collapsing onto **one documented rule**. Consolidating also removes a
duplicated parser.

---

## High-value refactors (duplication)

Ranked by how much they de-risk future edits.

### 1. Four copy-pasted `SELECT … FROM tasks` queries + row-building loops — _highest leverage_

`FocusCore.swift`: `allTasks` (~374), `task` (~557), `childTasks` (~588),
`unratedCompletedTasks` (~705). Same column list
(`id, parent_task_id, created_at, focus, estimate_seconds, status, rating, note`) and the
same `TaskRow(...)` construction, four times.

**Risk:** add or reorder a task column → edit all four; easy to update three and miss one,
silently mis-mapping a field. **This is schema-change risk.**

**Fix:** a `TaskRow(from: stmt)` initializer + a single `queryTasks(_ sql:, bind:)` runner;
all four collapse to one line each.

### 2. Three end-a-task sequences — _correctness-adjacent_

`main.swift`: `rateAndComplete` (~2729), `abortTask` (~975), and the `.rate` branch of
`timeUp` (~2643). Each replicates the same delicate ordering:

- `elapsedFocusSeconds()` **before** `resumeStackIfPaused()`
- `popAncestorToLeaf()` / `clearSessionState()`
- `endInterval` with the `applyTime` / `openSecondsEnd` split
- `addToInterval`, then `finishTask`
- advance (pop to parent vs. clear + next)

**Risk:** a fix to the time-accounting in one (e.g. the applyTime split) can be forgotten
in the others.

**Fix:** extract one `finishLeaf(status:rating:note:openSeconds:applyTime:) -> hadParent`
used by all three.

### 3. Column-reader helpers redeclared 8× — _mechanical_

`intOrNil` / `int64OrNil` / `text` are re-declared verbatim inside eight DB methods
(`FocusCore.swift` ~379, 403, 563, 594, 633, 657, 710, 800) — ~24 duplicated lines.

**Fix:** hoist to free functions taking `(OpaquePointer?, Int32)` (or a tiny `Row`
wrapper) so every query reads columns through one implementation.

### 4. `QueuePickSource` ≈ `SubtaskPickSource`

`main.swift` ~125 and ~197 — two near-identical `NSTableViewDataSource`/`Delegate` classes
(~130 lines) differing only in columns and the picked type. Same `makeTable`, `clicked(_:)`,
`viewFor`.

**Fix:** one generic picker source parameterized by column specs + a row→text closure;
removes a whole class.

### 5. Three duration-prompt modals

`askAddTime` (~822), `askMinutes` (~2706), `askLockDuration` (~2533). `askMinutes` and the
add-time branch of `askAddTime` are functionally the same prompt and even share the exact
informative text. Same floating-alert scaffolding + parse-and-loop.

**Fix:** one `askDuration(title:info:signed:default:)` helper. **Folds in the parser-bug
fix above.**

---

## Low-effort, satisfying wins

- **~15 alerts repeat** `window.level = .floating` + `collectionBehavior = [.canJoinAllSpaces,
  .fullScreenAuxiliary]` (e.g. `main.swift` ~701, 723, 738, 840, 1038, 1109, 1941, 2109,
  2512, 2716). Move into the existing `makeAlert()` factory (or a `floatingAlert()` helper)
  and delete ~30 scattered lines. Also prevents the "forgot to set the level" bug on the
  next new modal.

- **Cell-building Auto Layout block written 3×** — `QueuePickSource.viewFor`,
  `SubtaskPickSource.viewFor`, and `historyCell` (~2298). The two picker copies don't even
  reuse cells (no `makeView` identifier) while `historyCell` does, so behavior already
  diverges. Factor a single `makeLabelCell(text:align:color:)`.

- **11 UserDefaults Bool prefs + an 8-field tuple** threaded through `preferenceCheckboxes`,
  `persistPreferences`, and `showSettings` (`main.swift` ~2390–2517). Adding one setting
  means ~5 lockstep edits and keeping the tuple order aligned by hand across three
  signatures. A small `Pref(key:default:)` type + an array of descriptors makes adding a
  preference a one-line change (and removes the "wire the checkbox to the wrong default"
  hazard hit several times).

- **Queue schedule walk duplicated** — the "cursor = max(now, running deadline), then chain
  each `item.seconds` into start/finish" computation is in both `reloadQueueData` (~2008)
  and `pickFromQueue` (~1379). Extract one `queueSchedule(_ items:) -> [(start: Date,
  finish: Date)]` so the See-Queue window and the pick-from-queue modal can't show
  different times for the same items.

---

## Recommendation

For a single focused pass: **#1 + #2 + the parser bug** — those three carry real
correctness risk (schema mismatch, forgotten time-accounting fix, inconsistent parsing).
The rest is ergonomics and can be done piecemeal.

Each item is independently testable against the existing test suite (`./run-tests.sh`,
currently 137 assertions) — though note the controller-side items (#2, #5, the alert/pref
wins) are AppKit code the headless tests don't cover, so those want a live run too.
