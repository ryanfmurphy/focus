# focus

A personal macOS focus/timer app that lives in the menu bar. You name one focus,
give it a number of minutes, and it keeps that focus in front of you — as an
always-on-top pill and a menu-bar countdown — until the timer runs out, at which
point you rate the session. Everything is logged to SQLite so you can review how
you actually spend your time.

It also prompts you whenever you **return to the Mac** (login, wake, or unlock),
so sitting back down means declaring a focus.

> Built for one user, on one Mac. It's a single Swift file compiled with the
> command-line tools and run as a LaunchAgent — no Xcode, no app bundle.

There's also an early **iPhone** port (SwiftUI + Live Activity) scaffolded under
[`ios/`](ios/README.md); the rest of this document is about the macOS app.

## What it does

- **Return prompt** — on login / fast-user-switch, wake from sleep, and screen
  unlock, a blocking modal asks "what's your one focus, and for how long?"
  (debounced so a single return doesn't stack multiple prompts).
- **Always-present focus** — a floating pill in the top-right of the screen shows
  `🎯 <focus>  MM:SS / MM:SS` (time remaining / session total), above other windows
  and across all Spaces; **drag it** anywhere to reposition (it stays put for the
  rest of the session), or **double-click it** to rename the current focus inline
  (Enter saves, Esc cancels); plus a `🎯` menu-bar item.
- **Timer** — counts down (wall-clock based, so it survives sleep/lock); at zero
  it chimes, optionally sends a phone notification, and asks you to rate the
  session 1–10 (with an optional free-text **note**). You can **add more time**
  instead of finishing.
- **A queue** — line up future focuses; each session start pulls the next queued
  item (a confirm screen), or asks you to improvise if the queue is empty.
- **Complete / abort / defer / switch** — end or hand off the running task in the
  way that fits (see [Menu reference](#menu-reference)).
- **History & review** — browse every past session (and the pending queue) in
  native table windows; batch-rate any sessions whose rating you deferred.

## Requirements

- macOS (developed on Ventura 13.x).
- Xcode **Command Line Tools** (`xcode-select --install`) — provides `swiftc`.
  No full Xcode needed.

## Install

```sh
cd macos
./install.sh
```

This compiles `main.swift` to `macos/focus`, copies the LaunchAgent to
`~/Library/LaunchAgents/com.murftown.focus.plist`, and (re)loads it. The agent
has `RunAtLoad` + a conditional `KeepAlive`, so it starts at login and relaunches
if it *crashes* — but a clean quit (Cmd-Q) stays closed (see
[Quitting & reopening](#quitting--reopening)). The focus prompt appears
immediately (launching counts as a return).

To update after editing `main.swift`, just re-run `./install.sh` — it kills the
old instance and loads the rebuilt binary cleanly.

## Uninstall

```sh
cd macos
./uninstall.sh
```

Stops and unloads the agent. Your data in `~/focus/` is left untouched.

## Quitting & reopening

**Cmd-Q** or **Quit focus** quits the app and it *stays* closed. The agent's
`KeepAlive` is conditional (`SuccessfulExit = false`), so a clean quit (exit 0) is
not relaunched, while a crash or kill still respawns it. It will, however, come
back on your **next login** (`RunAtLoad`).

To reopen it before then (or after a clean quit):

```sh
cd macos
./open.sh          # relaunches the still-loaded agent (falls back to install.sh)
```

To stop it **and** keep it from returning at next login, unload the agent
entirely (this also works while a modal is up, since prompts are app-modal):

```sh
launchctl bootout gui/$(id -u)/com.murftown.focus
```

### A clickable launcher icon (Applications / Dock)

The app itself is a menu-bar-only LaunchAgent binary (no Dock icon). To get a
🎯 icon you can click to launch it — handy after a clean quit — build a small
launcher bundle:

```sh
cd macos
./make-app.sh                # builds ./Focus.app (drag it into /Applications)
./make-app.sh /Applications  # …or build and install straight to /Applications
```

`Focus.app` doesn't run the app itself; clicking it just tells launchd to start
the managed agent (so you never get a second instance — if it's already running,
the click is a no-op). Drag it to the Dock to keep it one click away. Re-run
`make-app.sh` if you ever want to regenerate it.

## Menu reference

Click the `🎯` menu-bar icon. Items are context-sensitive (disabled/renamed
based on state):

| Item | When | What it does |
|------|------|--------------|
| *— the running task (greyed out when idle) —* | | |
| **Complete task** | session active | Mark completed, rate 1–10, record the elapsed time as its duration (Original Duration is kept), advance to the next focus |
| **Add time** | session active | Add N minutes to the running session (same as "Add time" at time's up) |
| **Defer task** | session active | Mark the current one **deferred** ("to be continued") and append a fresh "… (continued)" copy — with its **full original duration** — to the **back** of the queue, then advance to the next focus |
| **Abort task** | session active | Rate it, mark interrupted (records elapsed time), advance |
| **Switch focus now** | session active | Interrupt the current one (its remaining time is re-queued to the front as "… (continued)") and start a new focus now |
| **Set focus** | idle | Start an ad-hoc focus (same item as Switch focus now, relabeled) |
| *— the queue —* | | |
| **Add to queue** | always | Append a focus to the end of the queue |
| **Add focus to front** | always | Add a new focus to the **front** of the queue (jumps ahead of whatever's queued next) without disturbing the running session; also logs a pre-empt |
| **See queue (N)** | always | Table of pending queued focuses, next-up first; right-click a row to move it up / down / to top / to bottom or delete it, select a row and press Delete to remove it, or select rows and ⌘C to copy them (duration · focus) as TSV (N = current length) |
| **Clear queue** | queue non-empty | Empty the queue (with confirmation) |
| *— review —* | | |
| **See history (N)** | always | Table of past sessions (time · duration · original · rating · status · focus · start/end popup-open · note); select rows and ⌘C to copy as TSV, or right-click to **Delete** them (with confirmation); N = total recorded |
| **Rate unrated sessions (N)** | N > 0 | Loop through deferred/unrated completed sessions oldest-first and rate each |
| *— app —* | | |
| **Show current task** | always | Checkbox — toggles the floating corner pill on/off (persisted). Menu-bar icon and all timing/logging are unaffected |
| **Settings** | always | Toggle the four global preference checkboxes without starting a session |
| **Quit focus** | always | Quit the app |

The countdown keeps updating even while the menu is open.

## Preferences (Settings dialog)

Four checkboxes live in the **Settings** dialog. They're **global, persisted
preferences** (stored in `UserDefaults`), not per-session — the last state you
set applies to every future timer:

- **Play sound when time's up** *(default on)* — plays the `Glass` chime at zero.
- **Send Pushover notification** *(default off)* — sends a push at session start
  and at time's up. Requires setup (below).
- **Auto-proceed with next queued task** *(default off)* — hands-free mode. When
  a session ends, it's marked completed **without stopping to rate** (deferred to
  "Rate unrated sessions"), and the next queued focus auto-starts after a 10-second
  countdown you can cancel. Lets a queue run start-to-finish untouched.
- **Show total session time after remaining time** *(default on)* — the pill
  shows `MM:SS / MM:SS` (remaining / session total); off shows just the remaining.

## Pushover setup

To use the Pushover checkbox, create `~/focus/pushover.json` with an application
token and your user key (both from [pushover.net](https://pushover.net)):

```json
{ "token": "YOUR_APP_API_TOKEN", "user": "YOUR_USER_KEY" }
```

Keep it private (`chmod 600`). It lives outside the repo and is never committed.
If the box is checked but the file is missing/invalid, sends are skipped and an
error is logged to `/tmp/focus.err.log`.

## Data & files

| Path | What |
|------|------|
| `~/focus/focus.db` | SQLite database (sessions, queue, time additions) |
| `~/focus/pushover.json` | Pushover credentials (you create this) |
| `~/Library/LaunchAgents/com.murftown.focus.plist` | The installed LaunchAgent |
| `~/Library/Preferences/…` | The three checkbox preferences (`UserDefaults`) |
| `/tmp/focus.err.log`, `/tmp/focus.out.log` | Agent stdout/stderr |

All of this lives outside the repo and **survives reinstalls** — installing only
rebuilds the binary and reloads the agent.

### Database schema

- **`sessions`** — one row per focus session: `started_at`, `ended_at`, `reason`
  (what triggered it), `seconds` (planned duration in seconds, bumped by "Add
  time"; for interrupted sessions, the actual elapsed seconds), `original_seconds`
  (the planned duration stamped at creation — never changes when time is added),
  `focus`, `rating` (1–10, nullable),
  `status`, `note` (optional free text entered when rating), `open_seconds_start`
  / `open_seconds_end` (how long the session-start and ending/rating popups stayed
  open, in whole seconds; **accumulated** — each popup span is credited either to
  end-popup-open (banked) or to the duration; `NULL`/`0:00` in the history window
  means no popup overhead was recorded). Planned durations are entered in whole
  minutes but stored as seconds (×60), and shown as `M:SS` in the history window.
  The rating (and time's-up) modal has an **"Apply this time to the previous focus
  session"** checkbox — when ticked, that popup span is added to the session's
  `seconds` (duration) and **not** to `open_seconds_end`; when unticked it's banked
  as `open_seconds_end`. This is decided per span, so it composes across multiple
  time's-up "Add time" cycles (each Add-time click credits the span so far
  immediately and restarts the "Open for" counter).
- **`queue`** — pending focuses (`created_at`, `seconds`, `focus`, `position`);
  ordered by `position` (right-click a row in the queue window to re-order).
  "Add to queue" appends (max position + 1); a front pre-empt inserts at min − 1.
- **`time_additions`** — one row per "Add time" event (`session_id`, `added_at`,
  `seconds`); the session's total `seconds` is also bumped.
- **`preempts`** — one row per pre-empt (`at`, `preempted_session_id`,
  `new_session_id`); `preempted_session_id` is `NULL` when nothing was running
  (pre-empting before a queued task starts), and both are `NULL` for an
  "Add focus to front" queue jump (nothing interrupted, nothing started yet).

**Status values:** `completed` (finished/rated, or auto-proceeded with a null
rating pending), `interrupted` (aborted, pre-empted, or swept on next launch after
a crash), and `deferred` ("Defer task" — paused to be continued later, its
full-duration continuation appended to the queue). A `NULL` status means the
session is still in progress (shown as "active"). (Older databases may also
contain the retired `superseded`/`cleared` values.)

## Session lifecycle & resilience

Finishing one focus **chains straight into the next** — the front of the queue if
something's queued, otherwise a fresh prompt — so you can flow session to session
(hands-free with auto-proceed on).

The timer is wall-clock based, so lock / sleep / closing the lid don't disturb a
running session, and returning won't re-prompt while one is active. If the
*process* itself dies mid-session (crash, reboot, reinstall), the next launch
offers three choices: **Resume** it, **Switch focus** (re-queue its remaining time
to the front and start a new focus now), or **Start fresh** (abandon it — with an
optional confirm to also clear the queue — then prompt for a new focus). If its
time elapsed while away, it's completed and sent to the rating queue instead.

## Configuration

Quick tweaks live at the top of `macos/main.swift`:

- `defaultMinutes` (default `25`) — the pre-filled duration.
- `timeUpSoundName` (default `"Glass"`) — any sound in `/System/Library/Sounds`
  (e.g. `Hero`, `Ping`, `Submarine`, `Tink`).

Re-run `macos/install.sh` after editing.

## Project layout

```
macos/
  main.swift                 # the entire app
  com.murftown.focus.plist   # LaunchAgent template
  install.sh / uninstall.sh
ios/                         # early SwiftUI + Live Activity port (see ios/README.md)
```
