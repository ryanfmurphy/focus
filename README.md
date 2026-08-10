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
- **Always-present focus** — a floating, click-through pill in the top-right of
  the screen shows `🎯 <focus>  MM:SS`, above other windows and across all Spaces;
  plus a `🎯` menu-bar item.
- **Timer** — counts down (wall-clock based, so it survives sleep/lock); at zero
  it chimes, optionally sends a phone notification, and asks you to rate the
  session 1–10 (with an optional free-text **note**). You can **add more time**
  instead of finishing.
- **A queue** — line up future focuses; each session start pulls the next queued
  item (a confirm screen), or asks you to improvise if the queue is empty.
- **Pre-empt / complete / abort** — interrupt the running task in the way that
  fits (see [Menu reference](#menu-reference)).
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
has `RunAtLoad` + `KeepAlive`, so it starts at login and relaunches if it exits.
The focus prompt appears immediately (launching counts as a return).

To update after editing `main.swift`, just re-run `./install.sh` — it kills the
old instance and loads the rebuilt binary cleanly.

## Uninstall

```sh
cd macos
./uninstall.sh
```

Stops and unloads the agent. Your data in `~/focus/` is left untouched.

### Quitting while a modal is up

The prompts are application-modal, and the agent has `KeepAlive`, so a plain
Force-Quit just respawns it. To stop it (even with a modal showing):

```sh
launchctl bootout gui/$(id -u)/com.murftown.focus
```

## Menu reference

Click the `🎯` menu-bar icon. Items are context-sensitive (disabled/renamed
based on state):

| Item | When | What it does |
|------|------|--------------|
| **Add to queue** | always | Append a focus to the end of the queue |
| **Complete task** | session active | Mark completed, rate 1–10, advance to the next focus |
| **Abort task** | session active | Rate it, mark interrupted (records elapsed minutes), advance |
| **Add time to current** | session active | Add N minutes to the running session (same as "Add time" at time's up) |
| **Pre-empt this task** | session active | Interrupt the current one (its remaining time is re-queued to the front as "… (continued)") and start a new focus now |
| **Set focus** | idle | Start an ad-hoc focus (same item as Pre-empt this task, relabeled) |
| **See history (N)** | always | Table of past sessions (time · duration · rating · status · focus · note); N = total recorded |
| **See queue (N)** | always | Table of pending queued focuses, next-up first (N = current length) |
| **Clear queue** | queue non-empty | Empty the queue (with confirmation) |
| **Rate unrated sessions (N)** | N > 0 | Loop through deferred/unrated completed sessions oldest-first and rate each |
| **Settings** | always | Toggle the three global preference checkboxes without starting a session |
| **Quit focus** | always | Quit the app |

The countdown keeps updating even while the menu is open.

## Preferences (checkboxes on the start prompt)

Three checkboxes appear on the "start a focus" modal (and in the **Settings**
dialog). They're **global, persisted preferences** (stored in `UserDefaults`),
not per-session — the last state you set applies to every future timer:

- **Play sound when time's up** *(default on)* — plays the `Glass` chime at zero.
- **Send Pushover notification** *(default off)* — sends a push at session start
  and at time's up. Requires setup (below).
- **Auto-proceed with next queued task** *(default off)* — hands-free mode. When
  a session ends, it's marked completed **without stopping to rate** (deferred to
  "Rate unrated sessions"), and the next queued focus auto-starts after a 10-second
  countdown you can cancel. Lets a queue run start-to-finish untouched.

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
  (what triggered it), `minutes` (planned duration; for interrupted sessions,
  the actual elapsed minutes), `focus`, `rating` (1–10, nullable), `status`,
  `note` (optional free text entered when rating).
- **`queue`** — pending focuses (`created_at`, `minutes`, `focus`); FIFO by `id`.
- **`time_additions`** — one row per "Add time" event (`session_id`, `added_at`,
  `minutes`); the session's total `minutes` is also bumped.
- **`preempts`** — one row per pre-empt (`at`, `preempted_session_id`,
  `new_session_id`); `preempted_session_id` is `NULL` when nothing was running
  (pre-empting before a queued task starts).

**Status values:** `completed` (finished/rated, or deferred with null rating) and
`interrupted` (aborted, pre-empted, or swept on next launch after a crash); a
`NULL` status means the session is still in progress (shown as "active").
(Older databases may also contain the retired `superseded`/`cleared` values.)

## Session lifecycle & resilience

Finishing one focus **chains straight into the next** — the front of the queue if
something's queued, otherwise a fresh prompt — so you can flow session to session
(hands-free with auto-proceed on).

The timer is wall-clock based, so lock / sleep / closing the lid don't disturb a
running session, and returning won't re-prompt while one is active. If the
*process* itself dies mid-session (crash, reboot, reinstall), the next launch
offers to **resume** it (or start fresh); if its time elapsed while away, it's
completed and sent to the rating queue.

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
