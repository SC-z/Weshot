#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
CONFIGURATION="${1:-release}"
APP_ROOT="$ROOT/build/WeShot.app"
CONTENTS="$APP_ROOT/Contents"
SIGNING_CERT="$ROOT/Resources/WeShotSigning.cer"
PINNED_IDENTITY="-"
if [[ -f "$SIGNING_CERT" ]]; then
    FINGERPRINT="$(openssl x509 -inform DER -in "$SIGNING_CERT" -noout -fingerprint -sha1)"
    FINGERPRINT="${FINGERPRINT#*=}"
    PINNED_IDENTITY="${FINGERPRINT//:/}"
fi
SIGNING_IDENTITY="${WESHOT_SIGNING_IDENTITY:-$PINNED_IDENTITY}"

if [[ "$SIGNING_IDENTITY" == "-" ]]; then
    if [[ "$CONFIGURATION" == "release" && "${WESHOT_ALLOW_ADHOC:-0}" != "1" ]]; then
        print -u2 "Release requires WESHOT_SIGNING_IDENTITY to preserve screen recording authorization across updates."
        print -u2 "For local tests only, explicitly set WESHOT_ALLOW_ADHOC=1."
        exit 1
    fi
    print -u2 "Local ad-hoc signing: updates can require screen recording authorization again."
fi

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

codesign --force --sign "$SIGNING_IDENTITY" --identifier local.codex.WeShot "$APP_ROOT"
codesign --verify --strict --verbose=2 "$APP_ROOT"
if [[ "$SIGNING_IDENTITY" != "-" && "$PINNED_IDENTITY" != "-" ]]; then
    codesign --verify --strict \
        -R "=identifier \"local.codex.WeShot\" and certificate leaf = H\"$PINNED_IDENTITY\"" "$APP_ROOT"
fi
plutil -lint "$CONTENTS/Info.plist"

print "$APP_ROOT"
