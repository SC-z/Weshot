#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP_ROOT="$ROOT/build/WeShot.app"
CONTENTS="$APP_ROOT/Contents"

cd "$ROOT"
SWIFT_FLAGS=()
if [[ "${WESHOT_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFT_FLAGS+=(--disable-sandbox)
fi
swift build "${SWIFT_FLAGS[@]}" -c "$CONFIGURATION" --product WeShot
BIN_DIR="$(swift build "${SWIFT_FLAGS[@]}" -c "$CONFIGURATION" --show-bin-path)"

mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/WeShot" "$CONTENTS/MacOS/WeShot"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
"$ROOT/scripts/generate_app_icon.sh" >/dev/null
cp "$ROOT/build/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

codesign --force --sign - --identifier local.codex.WeShot "$APP_ROOT"
codesign --verify --strict --verbose=2 "$APP_ROOT"
plutil -lint "$CONTENTS/Info.plist"

print "$APP_ROOT"
