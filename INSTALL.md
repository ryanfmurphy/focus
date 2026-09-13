# Installing **focus** on macOS

`focus` is a menu-bar focus/timer app that runs as a login **LaunchAgent** — no Xcode,
no app bundle, no external dependencies beyond the system frameworks. It's a single Swift
binary compiled with the command-line tools.

---

## 1. Requirements

- **macOS** (developed on Ventura 13.x; recent versions are fine).
- **Xcode Command Line Tools** — provides the `swiftc` compiler. If you don't have them:

  ```sh
  xcode-select --install
  ```

  You do **not** need the full Xcode app.

---

## 2. Get the code

```sh
git clone https://github.com/ryanfmurphy/focus.git
cd focus
```

---

## 3. Install

```sh
cd macos
./install.sh
```

This does everything:

1. **Compiles** `main.swift` + `FocusCore.swift` → `macos/focus`.
2. **Generates** the LaunchAgent plist for *your* machine (it fills the binary's absolute
   path into a template) and copies it to
   `~/Library/LaunchAgents/com.murftown.focus.plist`.
3. **Loads** the agent so it starts now and at every login.

The focus prompt appears immediately (launching counts as "returning to the Mac"), and
thereafter on every **login / wake / screen unlock**.

That's it — you'll see a **🎯** icon in the menu bar.

> **First launch may create data:** the app stores everything in `~/focus/focus.db`
> (created automatically). This lives **outside** the repo and survives reinstalls.

---

## 4. A clickable launcher (optional)

The app is menu-bar-only (no Dock icon). To get a 🎯 icon you can click to launch it —
handy after a clean quit — build a small launcher bundle:

```sh
cd macos
./make-app.sh                 # builds ./Focus.app
./make-app.sh /Applications   # …or build and install straight to /Applications
```

Clicking `Focus.app` just tells launchd to start the managed agent (so you never get a
second instance). Drag it to the Dock to keep it one click away.

---

## 5. Phone notifications (optional)

To get a push at the start/end of sessions (via [Pushover](https://pushover.net)), create
`~/focus/pushover.json` with your credentials:

```json
{ "token": "YOUR_APP_API_TOKEN", "user": "YOUR_USER_KEY" }
```

```sh
chmod 600 ~/focus/pushover.json
```

Then enable **"Send Pushover notification…"** in the app's **Settings**. The file lives
outside the repo and is never committed. If the box is checked but the file is
missing/invalid, sends are skipped and an error is logged to `/tmp/focus.err.log`.

---

## 6. Updating

After pulling new changes (or editing the source), just re-run the installer — it rebuilds
the binary and reloads the agent cleanly:

```sh
cd macos
./install.sh
```

---

## 7. Quitting & reopening

- **Cmd-Q** (or **Quit focus** in the menu) quits the app, and it **stays** closed until
  your next login. (A crash or kill is auto-relaunched; a clean quit is not.)
- To reopen it before then:

  ```sh
  cd macos
  ./open.sh
  ```

- To stop it **and** keep it from returning at next login, unload the agent:

  ```sh
  launchctl bootout gui/$(id -u)/com.murftown.focus
  ```

---

## 8. Uninstalling

```sh
cd macos
./uninstall.sh
```

Stops and unloads the agent and removes the plist. **Your data in `~/focus/` is left
untouched** — delete `~/focus/` yourself if you also want to remove the database.

---

## 9. Configuration & tests (optional)

Quick tweaks live at the top of `macos/main.swift`:

- `defaultMinutes` (default `25`) — the pre-filled session duration.
- `timeUpSoundName` (default `"Glass"`) — any sound in `/System/Library/Sounds`
  (e.g. `Hero`, `Ping`, `Submarine`, `Tink`).

Re-run `./install.sh` after editing.

To run the headless data-layer test suite:

```sh
cd macos
./run-tests.sh
```

---

## Troubleshooting

| Symptom | Fix |
|---|---|
| `swiftc: command not found` | Install the Command Line Tools: `xcode-select --install`. |
| No 🎯 in the menu bar after install | Check the logs: `cat /tmp/focus.err.log`. Re-run `./install.sh`. |
| Agent won't start / "Aqua session required" | The agent needs a logged-in GUI session (it shows modals). Run it from your normal desktop session, not over SSH. |
| Want a fully clean stop | `launchctl bootout gui/$(id -u)/com.murftown.focus` then `./uninstall.sh`. |

For what the app *does* and how the code is put together, see
[`README.md`](README.md) and [`macos/ARCHITECTURE.md`](macos/ARCHITECTURE.md).
