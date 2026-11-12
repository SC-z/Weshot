#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
"$ROOT/scripts/build_app.sh" release
APP="$ROOT/build/WeShot.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUTPUT="$ROOT/build/WeShot-$VERSION-arm64.dmg"
FINGERPRINT="$(openssl x509 -inform DER -in "$ROOT/Resources/WeShotSigning.cer" -noout -fingerprint -sha1)"
FINGERPRINT="${FINGERPRINT#*=}"
IDENTITY="${FINGERPRINT//:/}"

# Update packages must retain the pinned signer, including after local ad-hoc tests.
codesign --verify --strict \
    -R "=identifier \"local.codex.WeShot\" and certificate leaf = H\"$IDENTITY\"" "$APP"
if [[ -e "$OUTPUT" ]]; then
    print -u2 "Package already exists: $OUTPUT. Preserve it and increment the version before releasing again."
    exit 1
fi

STAGING="$(mktemp -d "${TMPDIR:-/tmp}/weshot-dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
ditto "$APP" "$STAGING/WeShot.app"
ln -s /Applications "$STAGING/Applications"
cp "$ROOT/LICENSE" "$STAGING/LICENSE.txt"
hdiutil create -volname WeShot -srcfolder "$STAGING" -fs HFS+ \
    -format UDZO -imagekey zlib-level=9 "$OUTPUT"
codesign --sign "$IDENTITY" --identifier local.codex.WeShot.dmg "$OUTPUT"
codesign --verify --strict "$OUTPUT"
hdiutil verify "$OUTPUT"
(cd "$ROOT/build" && shasum -a 256 "${OUTPUT:t}" > "${OUTPUT:t}.sha256")
print "$OUTPUT"
