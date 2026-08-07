# Focus — iPhone app

SwiftUI + SwiftData app with a Live Activity (Dynamic Island + Lock Screen pill)
that mirrors the macOS focus app: set a focus for N minutes, see it counting down
everywhere, and rate the session 1–10 when it ends.

**Standalone local store for now** — no sync with the Mac app yet (SwiftData,
on-device). CloudKit/iCloud sync is a later step.

## What's here

```
ios/
  project.yml            # XcodeGen spec — generates Focus.xcodeproj
  Shared/
    FocusAttributes.swift  # ActivityKit attributes, compiled into BOTH targets
  App/
    FocusApp.swift         # @main, SwiftData container
    Session.swift          # @Model — same fields as the Mac sessions table
    FocusManager.swift     # sessions + Live Activity + notifications + rating flow
    ContentView.swift      # active card, history, sheet wiring
    StartFocusView.swift   # "focus + minutes" form
    RatingView.swift       # mandatory 1–10 sheet (no escape)
    Info.plist             # NSSupportsLiveActivities
  Widget/
    FocusWidgetBundle.swift
    FocusLiveActivity.swift # Lock Screen + Dynamic Island
    Info.plist             # widgetkit-extension
```

## Build steps

1. **Install full Xcode** from the Mac App Store (Command Line Tools alone can't
   build iOS apps). Then point the toolchain at it:
   ```
   sudo xcode-select -s /Applications/Xcode.app
   sudo xcodebuild -license accept
   ```

2. **Install XcodeGen**:
   ```
   brew install xcodegen
   ```

3. **Generate and open the project**:
   ```
   cd ios
   xcodegen generate
   open Focus.xcodeproj
   ```

4. **Signing**: select the `Focus` target → *Signing & Capabilities* → pick your
   Team. Do the same for `FocusWidget`. A free Apple ID works (7-day builds); the
   bundle IDs (`com.ryanfmurphy.focus` / `.FocusWidget`) may need to be made
   unique if they collide.

5. **Run**:
   - Live Activities need iOS 16.1+; the **Dynamic Island** needs an
     iPhone 14 Pro/15 Pro (or that simulator).
   - First launch asks for notification permission (used for the "time's up"
     alert when the app is backgrounded).

## Known limitations (iOS constraints, not bugs)

- **No on-unlock trigger.** iOS does not let third-party apps run code or force a
  modal when you unlock the phone, so the Mac app's "return → mandatory prompt"
  can't be reproduced. You start a focus by opening the app / tapping the widget.
- **Rating is enforced, not forced onto the screen.** When the timer ends the app
  shows a non-dismissable rating sheet the next time it's frontmost (open it, or
  tap the "time's up" notification). It can't seize the screen the way the Mac
  modal does.

## Not built yet

- iCloud/CloudKit sync with the macOS app (chosen to defer).
- App icon / launch art.
- Widgets beyond the Live Activity (e.g. a Home Screen "current focus" widget).

This scaffold hasn't been compiled — it's authored source. Expect to set your
signing team and possibly nudge a minor API detail on first build in Xcode.
