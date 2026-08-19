#!/bin/bash
# Build "Focus.app" — a small launcher you can click in Applications/ or the Dock.
# It doesn't run focus itself; it tells launchd to start the managed LaunchAgent
# (so there's never a second instance). A 🎯 icon is generated for it.
#
# Usage:
#   ./make-app.sh              # builds ./Focus.app
#   ./make-app.sh /Applications  # builds and copies into /Applications
set -euo pipefail
cd "$(dirname "$0")"

APP="Focus.app"
LABEL="com.murftown.focus"

echo "Building $APP ..."
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# --- Info.plist -------------------------------------------------------------
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Focus</string>
    <key>CFBundleDisplayName</key><string>Focus</string>
    <key>CFBundleIdentifier</key><string>${LABEL}.launcher</string>
    <key>CFBundleExecutable</key><string>Focus</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <!-- Accessory: no transient Dock bounce; still clickable in Finder/Dock. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

# --- Launcher executable (a shell script) -----------------------------------
# Start the agent if it's stopped; no-op if it's already running (kickstart
# without -k won't restart it, so a live session isn't interrupted).
cat > "$APP/Contents/MacOS/Focus" <<'LAUNCH'
#!/bin/bash
LABEL="com.murftown.focus"
UID_="$(id -u)"
TARGET="gui/$UID_/$LABEL"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
if launchctl print "$TARGET" >/dev/null 2>&1; then
    launchctl kickstart "$TARGET" 2>/dev/null || true   # launch if stopped; else no-op
elif [ -f "$PLIST" ]; then
    launchctl bootstrap "gui/$UID_" "$PLIST"             # load it (RunAtLoad starts it)
else
    osascript -e 'display alert "Focus is not installed" message "Run macos/install.sh first."'
fi
LAUNCH
chmod +x "$APP/Contents/MacOS/Focus"

# --- Icon: render 🎯 to an .iconset, then iconutil -> AppIcon.icns -----------
echo "Generating icon ..."
ICONSET="$(mktemp -d)/Focus.iconset"
mkdir -p "$ICONSET"
SWIFT="$(mktemp -t makeicon).swift"
cat > "$SWIFT" <<'SWIFTSRC'
import AppKit
let out = CommandLine.arguments[1]
func render(_ px: Int, _ name: String) {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let str = "🎯" as NSString
    let font = NSFont.systemFont(ofSize: CGFloat(px) * 0.82)
    let attrs: [NSAttributedString.Key: Any] = [.font: font]
    let sz = str.size(withAttributes: attrs)
    str.draw(at: NSPoint(x: (CGFloat(px) - sz.width) / 2, y: (CGFloat(px) - sz.height) / 2),
             withAttributes: attrs)
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(out)/\(name)"))
    }
}
for base in [16, 32, 128, 256, 512] {
    render(base, "icon_\(base)x\(base).png")
    render(base * 2, "icon_\(base)x\(base)@2x.png")
}
SWIFTSRC
ICONBIN="$(mktemp -t makeicon)"
swiftc "$SWIFT" -o "$ICONBIN"
"$ICONBIN" "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$SWIFT" "$ICONBIN" "$(dirname "$ICONSET")"

echo "Built $APP"

# --- Optional: copy into a destination (e.g. /Applications) -----------------
if [ "${1:-}" != "" ]; then
    DEST="${1%/}/$APP"
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    echo "Installed -> $DEST"
    echo "Tip: open it once, then keep it in the Dock (right-click → Options → Keep in Dock)."
else
    echo "Drag $APP into /Applications (and then to the Dock) to keep it handy."
fi
