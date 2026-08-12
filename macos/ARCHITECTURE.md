# focus — code walkthrough

A tour of how the macOS app works, top to bottom. Everything lives in one file,
[`main.swift`](main.swift) (~1,800 lines), compiled with `swiftc` and run as a
LaunchAgent — no Xcode, no app bundle, no external dependencies beyond the system
frameworks (`AppKit`, `SQLite3`).

> If you just want to *use* the app, see [README.md](../README.md). This document
> is about how the code is put together.

---

## 1. The 30-second mental model

The app is a tiny **state machine around "one current focus"** plus a **SQLite
log** of everything that happens.

- At any moment there is either **a session running** (`currentFocus != nil`) or
  **nothing** (idle).
- Three things watch the world and can start/stop a session: **system events**
  (login/wake/unlock), a **once-a-second timer**, and **menu clicks**.
- Every state change is written to `~/focus/focus.db`.
- The user sees three surfaces: **blocking modals** (NSAlert), an always-on-top
  **pill** (a borderless window), and a **menu-bar item** (🎯).

```
              ┌─────────────── system events (login / wake / unlock)
              │                        │
              ▼                        ▼
        [ IDLE ] ──start focus──▶ [ SESSION RUNNING ] ──timer hits 0──▶ [ TIME'S UP ]
           ▲                          │  │  │  │                              │
           │                          │  │  │  └─ Add time ──────────────┐    │
           └──── complete / abort ────┘  │  └─ Defer  (→ back of queue)  │    │
                 / defer / pre-empt       └─ Pre-empt (→ front of queue)  │    │
                                                                          ▼    ▼
                                                              rate 1–10, log, chain to next
```

---

## 2. File layout

`main.swift` has three top-level types and a handful of free functions:

| Part | Lines (approx.) | Role |
|------|------|------|
| Free helpers | top | `mmss()`, `isoNow()`, `emojiImage()`, `SQLITE_TRANSIENT` |
| `final class DB` | `// MARK: - Storage` | Everything SQLite: schema, migrations, all queries |
| `struct QueueItem / ActiveSession / SessionRow` | — | Plain row structs the DB hands back |
| `CopyableTableView` / `QueueTableView` | — | `NSTableView` subclasses adding ⌘C and the Delete key |
| `final class AppController` | `// MARK: - App` | The whole UI + behavior; `NSApplicationDelegate` |
| Bootstrap | bottom | 5 lines: make the app `.accessory`, set the delegate, `run()` |

The bootstrap at the very bottom is the entry point:

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // background app: no Dock icon, but can own a status item
let controller = AppController()
app.delegate = controller
app.run()
```

`.accessory` is what makes it a menu-bar-only app.

---

## 3. Startup — `applicationDidFinishLaunching`

When the process launches (the LaunchAgent starts it at login and relaunches it
if it dies), AppKit calls `applicationDidFinishLaunching`, which:

1. Sets the 🎯 app icon (so modals show a target, not a generic icon).
2. Builds the three UI surfaces: `buildMainMenu()` (an Edit menu so ⌘C/⌘V work in
   modals — an `.accessory` app has no menu bar otherwise), `buildStatusItem()`
   (the 🎯 menu), `buildHUD()` (the floating pill window).
3. Registers **observers** for the events that mean "the user came back":
   - `NSWorkspace.sessionDidBecomeActiveNotification` → `onReturn("session")`
   - `NSWorkspace.didWakeNotification` → `onReturn("wake")`
   - the distributed `com.apple.screenIsUnlocked` notification → `onReturn("unlock")`
4. Starts the **1-second `uiTimer`** that calls `tick()`. Crucially it's added to
   the run loop in **`.common` mode**, so it keeps firing even while a menu is
   open or a modal is up (default-mode timers freeze during those).
5. Calls `restoreOrPrompt()` to deal with any session that was still open when the
   process last died.

---

## 4. The storage layer — `class DB`

A thin wrapper over the SQLite C API (`sqlite3_prepare_v2` / `bind` / `step` /
`finalize`). A few conventions to know:

- **`SQLITE_TRANSIENT`** is passed to every `bind_text` so SQLite copies the
  string (safe to pass temporary Swift strings).
- **`exec()`** runs a statement and *ignores errors*. This is deliberate — it's
  how migrations stay idempotent (see below).
- Times are stored as **ISO-8601 UTC text** (`isoNow()`), rendered to local time
  only for display (`whenLabel()` / `localClockFormatter`).
- Durations are stored as **integer seconds** everywhere.

### Schema (created in `init`)

- **`sessions`** — one row per focus session. Key columns:
  - `seconds` — planned duration; **bumped by "Add time"**, and overwritten with
    *elapsed* time when a session is interrupted/deferred/completed-early.
  - `original_seconds` — planned duration **stamped once at creation**, never
    changed. (This is why history can show `Duration 9:12 / Original 25:00`.)
  - `rating` (1–10, nullable), `status`, `note`, `original_session_id`
    (the chain root for continued tasks), `open_seconds_start` / `open_seconds_end`
    (how long the start / rating popups stayed open, accumulated).
- **`queue`** — pending focuses, ordered by a `position` column (not `id`).
- **`time_additions`** — one row per "Add time" event.
- **`preempts`** — one row per pre-empt.

**Status values:** `completed`, `interrupted`, `deferred`, or `NULL` (still
running / "active"). Older DBs may carry retired `cleared` / `superseded`.

### Migrations — the idempotent pattern

Because `exec()` swallows errors, every migration is written to run on *every*
launch and simply no-op once applied:

```swift
exec("ALTER TABLE sessions ADD COLUMN original_seconds INTEGER;")  // errors "duplicate column" after first run — ignored
exec("UPDATE sessions SET original_seconds = ... WHERE original_seconds IS NULL AND ...;")  // WHERE guard makes it a no-op after backfill
```

The `minutes → seconds` switch and the `original_seconds` backfill both use this
"add column, back-fill once with a `WHERE ... IS NULL` guard, (maybe) drop the old
column" recipe.

---

## 5. A session's life

### Starting — `beginSession`

```swift
private func beginSession(reason:seconds:focus:originalSessionId:openSecondsStart:)
```

Sets the in-memory state (`currentFocus`, `deadline = now + seconds`,
`sessionStart`, `sessionSeconds`, `sessionOriginalId`), inserts the DB row via
`startSession` (which stamps both `seconds` and `original_seconds`), records the
start-popup-open time, optionally sends a Pushover "started" ping, and calls
`tick()` to paint the pill immediately.

The **deadline is a wall-clock `Date`** (`now + seconds`), *not* a countdown
integer. That's why lock / sleep / closing the lid don't disturb the timer — when
the machine wakes, `remaining = deadline - now` is simply correct.

### Ticking — `tick()` (once a second)

```swift
if let focus = currentFocus, let dl = deadline {
    let remaining = Int(dl.timeIntervalSinceNow.rounded())
    if remaining <= 0 { timeUp(focus: focus); return }
    hudLabel.stringValue = "🎯 \(focus)   \(remaining) / \(total)"   // total optional (Settings)
    ...
} else { hudWindow.orderOut(nil) }   // idle → hide pill
```

So the timer both **drives the display** and **detects time's up**.

### Time's up — `timeUp` → `promptTimeUp`

At zero, `timeUp` plays the chime, optionally pings Pushover, then:
- **Auto-proceed on** → close the session `completed` with no rating (deferred to
  "Rate unrated sessions") and chain straight to the next focus.
- **Auto-proceed off** → show `promptTimeUp`, a mandatory modal that either
  returns `.rate(rating, note, openSeconds)` (→ close completed) or
  `.addTime(added, openSeconds)` (→ `extendSession`, keep going).

### The five ways a session ends (menu actions)

| Action | Method | Status written | Duration recorded | Continuation |
|--------|--------|----------------|-------------------|--------------|
| **Complete** | `completeTask` → `rateAndComplete` | `completed` | **elapsed** (early finish) | — |
| **Abort** | `abortTask` | `interrupted` | elapsed | — |
| **Defer** | `deferTask` | `deferred` | elapsed | **full original** → back of queue |
| **Pre-empt this** | `changeFocus` | `interrupted` | elapsed | **remaining** → front of queue, start new now |
| **Time's up → rate** | `timeUp` | `completed` | planned | — |

After ending, most paths call `promptForFocus("after-session")` to **chain into
the next focus** (front of queue, or a fresh prompt).

---

## 6. The queue

The queue is a FIFO ordered by an explicit **`position`** column so it can be
reordered:

- `enqueue` appends at `MAX(position)+1`; `enqueueFront` inserts at `MIN(position)-1`.
- `frontOfQueue` / `queueItems` read `ORDER BY position, id`.
- `reorderQueue(ids:)` rewrites `position = 0,1,2,…` in one transaction (used by
  the right-click **Move up/down/to top/to bottom** menu).
- `removeFromQueue` / the Delete key / "Delete from queue" remove one item.

`originalSessionId` threads a task's **lineage root** through the queue: when a
task is deferred or pre-empted, its "(continued)" copy carries the original id, so
`COALESCE(original_session_id, id)` groups a whole chain in history.

`confirmQueued` is the non-editable "Next focus" screen shown when a session pulls
the next queued item; with **auto-proceed** on and eligible, it auto-starts after
a 10-second cancelable countdown.

---

## 7. Coming back — `onReturn` and resume

`onReturn(reason)` is the single funnel for login/wake/unlock/launch. It:
- **Debounces** (a 10-second `cooldown`, since wake+unlock+session often fire
  together) and guards on `showing` (never stack modals).
- Does nothing if a session is already running (`currentFocus != nil`).
- Otherwise calls `promptForFocus`, which shows the next queued item or an
  editable "Welcome back" prompt.

`restoreOrPrompt` (run once at launch) handles a session that was still open when
the process died. If its wall-clock deadline is still in the future it calls
`offerResume`, a **three-button** modal:

- **Resume** → `adopt` the row back into memory and continue.
- **Pre-empt…** → `adopt` it, then reuse `changeFocus` (re-queue remaining time to
  the front, start a new focus now).
- **Start fresh…** → abandon it, optionally clear the queue (shared
  `confirmClearQueue()` confirmation), then prompt for a new focus.

If the deadline already passed while away, it's adopted and `tick()` immediately
runs `timeUp` (finish + rate).

---

## 8. The modals — one shared shape

Every prompt is an application-modal `NSAlert` built via `makeAlert()` (which
forces the 🎯 icon). Common tricks:

- `alert.window.level = .floating` + `collectionBehavior = [.canJoinAllSpaces, …]`
  so prompts sit above everything and follow you across Spaces.
- **Accessory views** carry text fields / checkboxes (`askFocusAndMinutes`,
  `ratingAccessory`, the Settings checkboxes).
- **"Open for M:SS" timers** — `startElapsedTimer` returns both a `Timer` (added in
  `.common` mode so it ticks under the modal) and an `openSeconds()` closure the
  caller reads at close time to log how long the popup was open.
- **Field editor loop** — `ratingField.nextKeyView = noteField` (and back) so Tab
  cycles the rating and note fields.

Inputs are always **minutes**, converted to seconds (`× 60`) right at the return
of `askFocusAndMinutes` / `askMinutes`; everything downstream is seconds.

---

## 9. The tables — history & queue windows

`AppController` is the `NSTableViewDataSource` / `Delegate` for **both** windows,
disambiguated by `tableView === queueTable`:

- `numberOfRows` / `viewFor` read from `historyRows` / `queueRows` (loaded via
  `db.recent()` / `db.queueItems()`); cells are built by `historyCell`.
- **History** uses `CopyableTableView` (⌘C → `copyHistoryRows`, which emits TSV).
- **Queue** uses `QueueTableView` (Delete key → `deleteQueueRow`) plus a
  right-click menu for reordering/deleting, and shows **Est. start / finish**
  columns computed by chaining each item's duration from the current deadline
  (`reloadQueueData`).

---

## 10. Preferences, Settings, Pushover

- Four **global** prefs live in `UserDefaults`: `playSound`, `pushover`,
  `autoProceed`, `showTotalOnPill`. Accessed via computed properties
  (`playSoundEnabled`, …).
- `showSettings` shows them as checkboxes (`preferenceCheckboxes` /
  `persistPreferences`); "Show current task" (the pill toggle) is a separate
  checkmark item on the status menu (`toggleShowPill`).
- `sendPushover` is fire-and-forget `URLSession`, reading credentials from
  `~/focus/pushover.json` (kept out of the repo).

---

## 11. Files on disk

| Path | What |
|------|------|
| `~/focus/focus.db` | the SQLite database |
| `~/focus/pushover.json` | Pushover credentials (you create it) |
| `~/Library/LaunchAgents/com.murftown.focus.plist` | the LaunchAgent (RunAtLoad + KeepAlive) |
| `~/Library/Preferences/…` | the four checkbox prefs (`UserDefaults`) |
| `/tmp/focus.err.log`, `/tmp/focus.out.log` | agent stderr / stdout |

---

## 12. Gotchas worth remembering

- **Timers must be `.common` mode** or they freeze whenever a menu/modal is open —
  the pill countdown, auto-proceed countdown, and "Open for M:SS" all rely on this.
- **Wall-clock deadlines** (a `Date`, not a counter) are what make the timer
  survive sleep/lock and let a resumed session compute correct remaining time.
- **`exec()` ignoring errors** is load-bearing for migrations; don't "fix" it.
- **`seconds` vs `original_seconds`**: `seconds` mutates (add-time, elapsed on
  early-finish); `original_seconds` is immutable. Interrupted/deferred rows lose
  their true original (`seconds` was overwritten), so old ones show `—`.
- **`showing`** guards against stacking modals; **`cooldown`** debounces the
  return events.
- One process, one DB, one user — no concurrency, no locking concerns.
