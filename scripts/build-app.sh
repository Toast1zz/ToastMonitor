#!/bin/bash
# Assemble ToastMonitor.app from the SwiftPM release build.
set -e
cd "$(dirname "$0")/.."   # ~/Projects/ToastMonitor

BIN="$(swift build -c release --show-bin-path)/ToastMonitor"
APP="$(pwd)/dist/ToastMonitor.app"

echo "== building (if needed) =="
swift build -c release

echo "== assembling bundle =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>ToastMonitor</string>
    <key>CFBundleDisplayName</key><string>ToastMonitor</string>
    <key>CFBundleIdentifier</key><string>com.toast.toastmonitor</string>
    <key>CFBundleExecutable</key><string>ToastMonitor</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSUIElement</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <!-- P0-6: no blanket cleartext. Local networking (Tailscale/private)
             is allowed so the VPS usage feed over http://100.116.x.x works;
             everything else requires HTTPS (enforced in code too). -->
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>NSHumanReadableCopyright</key><string>© 2026 Toast</string>
</dict>
</plist>
PLIST

cp "$BIN" "$APP/Contents/MacOS/ToastMonitor"

echo "== generating icon =="
mkdir -p /tmp/tm_icon.iconset
cat > /tmp/tm_icon_gen.swift <<'SWIFT'
import AppKit

let size = NSSize(width: 1024, height: 1024)
let img = NSImage(size: size)
img.lockFocus()

// Background: dark rounded square with subtle gradient
let rect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
let bg = NSBezierPath(roundedRect: rect, xRadius: 224, yRadius: 224)
NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1),
    NSColor(calibratedRed: 0.08, green: 0.09, blue: 0.12, alpha: 1),
])!.draw(in: bg, angle: -90)

// Chart bars (orange, like the menu bar icon)
let barColor = NSColor(calibratedRed: 1.0, green: 0.58, blue: 0.25, alpha: 1)
let bars: [(x: CGFloat, w: CGFloat, h: CGFloat)] = [
    (210, 110, 180),
    (390, 110, 320),
    (570, 110, 250),
    (750, 110, 560),
]
for b in bars {
    let r = NSRect(x: b.x, y: 230, width: b.w, height: b.h)
    let path = NSBezierPath(roundedRect: r, xRadius: 26, yRadius: 26)
    barColor.setFill()
    path.fill()
}

// Trend line over the bars
let line = NSBezierPath()
line.move(to: NSPoint(x: 150, y: 260))
line.line(to: NSPoint(x: 430, y: 520))
line.line(to: NSPoint(x: 610, y: 430))
line.line(to: NSPoint(x: 900, y: 800))
line.lineWidth = 34
line.lineCapStyle = .round
line.lineJoinStyle = .round
NSColor(calibratedRed: 1.0, green: 0.95, blue: 0.85, alpha: 0.95).setStroke()
line.stroke()

img.unlockFocus()

guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("icon render failed")
}
try! png.write(to: URL(fileURLWithPath: "/tmp/tm_icon_1024.png"))
print("icon png written")
SWIFT
swift /tmp/tm_icon_gen.swift

for s in 16 32 128 256 512; do
    sips -z $s $s /tmp/tm_icon_1024.png --out /tmp/tm_icon.iconset/icon_${s}x${s}.png >/dev/null 2>&1
    s2=$((s*2))
    sips -z $s2 $s2 /tmp/tm_icon_1024.png --out /tmp/tm_icon.iconset/icon_${s}x${s}@2x.png >/dev/null 2>&1
done
iconutil -c icns /tmp/tm_icon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
echo "== icon done =="

echo "== code signing =="
# codesign needs the login keychain unlocked; unlock is transient (~5 min).
# TM_KEYCHAIN_PASSWORD is passed by the deploy tooling; when absent the
# keychain may prompt once on the GUI session (allow = permanent ACL).
if [[ -n "${TM_KEYCHAIN_PASSWORD:-}" ]]; then
    security unlock-keychain -p "$TM_KEYCHAIN_PASSWORD" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
else
    security unlock-keychain "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true
fi

# Ad-hoc signing changes the app's identity whenever the bundle is rebuilt,
# which makes macOS Keychain treat every local install as a new client. Prefer
# the stable local identity already present on this Mac; callers can override
# it with TM_SIGNING_IDENTITY for CI or release builds.
SIGNING_IDENTITY="${TM_SIGNING_IDENTITY:-}"
if [[ -z "$SIGNING_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq '"Spotoast Local Dev"'; then
    SIGNING_IDENTITY="Spotoast Local Dev"
fi
if [[ -z "$SIGNING_IDENTITY" ]]; then
    echo "error: no stable local signing identity found; refusing ad-hoc signing"
    echo "       set TM_SIGNING_IDENTITY to a trusted Developer ID for a release build"
    exit 1
fi
echo "signing identity: $SIGNING_IDENTITY"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp=none "$APP"

echo "== done: $APP =="
