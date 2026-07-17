#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
cd "$ROOT"

SWIFT_FLAGS=()
if [[ "${WESHOT_DISABLE_SWIFTPM_SANDBOX:-0}" == "1" ]]; then
    SWIFT_FLAGS+=(--disable-sandbox)
fi
swift test "${SWIFT_FLAGS[@]}"
swift build "${SWIFT_FLAGS[@]}" -c release --product WeShot \
    -Xswiftc -warn-concurrency \
    -Xswiftc -warnings-as-errors
"$ROOT/scripts/build_app.sh" release
test -s "$ROOT/build/WeShot.app/Contents/Resources/AppIcon.icns"
[[ "$(plutil -extract CFBundleIconFile raw "$ROOT/build/WeShot.app/Contents/Info.plist")" == "AppIcon" ]]
if strings "$ROOT/build/WeShot.app/Contents/MacOS/WeShot" |
    awk -v root="$ROOT" 'index($0, root) { found = 1 } END { exit !found }'
then
    print -u2 "Release binary contains the local workspace path"
    exit 1
fi
"$ROOT/build/WeShot.app/Contents/MacOS/WeShot" --self-test
mkdir -p "$ROOT/work"
"$ROOT/build/WeShot.app/Contents/MacOS/WeShot" \
    --render-fixture "$ROOT/work/weshot-fixture.png"
"$ROOT/build/WeShot.app/Contents/MacOS/WeShot" \
    --render-editor-fixture "$ROOT/work/weshot-editor-fixture.png"
codesign --verify --strict --verbose=2 "$ROOT/build/WeShot.app"
