#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
APP="$ROOT/build/WeShot.app"
BIN="$APP/Contents/MacOS/WeShot"
OUTPUT="$ROOT/work/system-smoke"

mkdir -p "$OUTPUT"

if ioreg -l -w0 | grep -F '"CGSSessionScreenIsLocked"=Yes' >/dev/null; then
    print -u2 "SYSTEM_SMOKE FAIL screen-locked"
    exit 1
fi

WESHOT_DISABLE_SWIFTPM_SANDBOX=1 "$ROOT/scripts/build_app.sh" release

permission="$("$BIN" --permission-status)"
print "$permission"
if [[ "$permission" != "SCREEN_CAPTURE_PERMISSION GRANTED" ]]; then
    print -u2 "SYSTEM_SMOKE FAIL screen-capture-permission-not-granted"
    exit 1
fi

"$BIN" --capture-smoke "$OUTPUT/desktop.png"
"$BIN" --workflow-smoke "$OUTPUT/workflow"
"$BIN" --scroll-system-smoke "$OUTPUT/scroll"
"$BIN" --visible-ui-smoke "$OUTPUT/visible-ui"
"$BIN" --hotkey-event-smoke
"$BIN" --hotkey-physical-smoke
"$BIN" --translation-smoke Hello
"$BIN" --translation-smoke 你好

codesign --verify --strict --verbose=2 "$APP"

leftovers="$(pgrep -x WeShot || true)"
if [[ -n "$leftovers" ]]; then
    print -u2 "SYSTEM_SMOKE FAIL leftover-process"
    print -u2 "$leftovers"
    exit 1
fi

print "SYSTEM_SMOKE PASS"
