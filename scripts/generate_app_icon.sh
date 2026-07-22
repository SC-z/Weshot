#!/bin/zsh
set -euo pipefail

ROOT="${0:A:h:h}"
SOURCE="$ROOT/Resources/AppIcon.svg"
ICONSET="$ROOT/build/AppIcon.iconset"
OUTPUT="$ROOT/build/AppIcon.icns"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
qlmanage -t -s 1024 -o "$ICONSET" "$SOURCE" >/dev/null
RASTER="$ICONSET/${SOURCE:t}.png"

for entry in \
    "16 icon_16x16.png" \
    "32 icon_16x16@2x.png" \
    "32 icon_32x32.png" \
    "64 icon_32x32@2x.png" \
    "128 icon_128x128.png" \
    "256 icon_128x128@2x.png" \
    "256 icon_256x256.png" \
    "512 icon_256x256@2x.png" \
    "512 icon_512x512.png" \
    "1024 icon_512x512@2x.png"
do
    size="${entry%% *}"
    name="${entry#* }"
    sips -s format png -z "$size" "$size" "$RASTER" --out "$ICONSET/$name" >/dev/null
done

rm -f "$RASTER"
iconutil -c icns "$ICONSET" -o "$OUTPUT"
print "$OUTPUT"
