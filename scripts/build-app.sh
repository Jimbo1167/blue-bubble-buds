#!/bin/bash
# Build Blue Bubble Buds as a double-clickable .app bundle.
# Usage:  bash scripts/build-app.sh [--install]
#         --install  also copies the result into /Applications

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Blue Bubble Buds"
BUNDLE_ID="family.schindler.bluebubblebuds"
APP_DIR="$ROOT/dist/${APP_NAME}.app"
CONTENTS="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

echo "==> Cleaning previous build"
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES/cli"

echo "==> Building release binary"
cd "$ROOT"
swift build -c release

BINARY="$ROOT/.build/release/BlueBubbleBuds"
if [[ ! -x "$BINARY" ]]; then
    echo "ERROR: expected release binary at $BINARY" >&2
    exit 1
fi

echo "==> Assembling bundle at $APP_DIR"
cp "$BINARY" "$MACOS_DIR/BlueBubbleBuds"
cp "$ROOT/cli/blue_bubble_buds.py" "$RESOURCES/cli/"
cp "$ROOT/cli/build_names.py" "$RESOURCES/cli/"
# names.json is gitignored; copy it if the user has generated one
if [[ -f "$ROOT/cli/names.json" ]]; then
    cp "$ROOT/cli/names.json" "$RESOURCES/cli/"
fi

# App icon
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$RESOURCES/AppIcon.icns"
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key><string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>BlueBubbleBuds</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.social-networking</string>
</dict>
</plist>
PLIST

echo "==> Code signing"
# Prefer any stable keychain identity (Apple Development, Mac Developer, or our
# self-signed 'Blue Bubble Buds Dev'). This keeps the Designated Requirement
# constant across rebuilds so Full Disk Access doesn't reset.
SIGNING_IDENTITY=""
IDENTITIES=$(security find-identity -v -p codesigning || true)
for candidate in "Blue Bubble Buds Dev" "Apple Development" "Mac Developer" "Developer ID Application"; do
    match=$(printf '%s\n' "$IDENTITIES" | grep "\"$candidate" || true)
    if [[ -n "$match" ]]; then
        SIGNING_IDENTITY=$(printf '%s\n' "$match" | head -1 | sed -E 's/.*"([^"]+)".*/\1/')
        break
    fi
done

if [[ -n "$SIGNING_IDENTITY" ]]; then
    echo "    using stable identity: $SIGNING_IDENTITY"
    echo "    (FDA grant persists across rebuilds)"
    codesign --force --deep --sign "$SIGNING_IDENTITY" "$APP_DIR"
else
    echo "    using ad-hoc signature — FDA grant resets on every rebuild"
    echo "    one-time fix: bash scripts/setup-signing.sh"
    codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true
fi

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/${APP_NAME}.app"
    cp -R "$APP_DIR" "/Applications/${APP_NAME}.app"
    echo "Installed. Launch from Spotlight, Launchpad, or /Applications."
else
    echo "Done. Bundle at: $APP_DIR"
    echo
    echo "To install:"
    echo "  bash scripts/build-app.sh --install"
    echo
    echo "Or drag '$APP_DIR' into /Applications manually."
fi
