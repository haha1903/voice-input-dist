#!/bin/bash
# Build AppIcon.icns from icon_1024.png for macOS apps.
# macOS expects an .iconset directory with specific sizes + @2x retina variants,
# then iconutil rolls it into a signed .icns container.

set -euo pipefail
cd "$(dirname "$0")"

SRC="icon_1024.png"
ICONSET="AppIcon.iconset"
OUT="AppIcon.icns"

if [ ! -f "$SRC" ]; then
    echo "Generating $SRC first..."
    python3 make-icon.py
fi

rm -rf "$ICONSET" "$OUT"
mkdir "$ICONSET"

# Apple-required sizes for a complete icon set
for sz in 16 32 128 256 512; do
    sips -z $sz       $sz       "$SRC" --out "$ICONSET/icon_${sz}x${sz}.png"        > /dev/null
    sips -z $((sz*2)) $((sz*2)) "$SRC" --out "$ICONSET/icon_${sz}x${sz}@2x.png"     > /dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT"
rm -rf "$ICONSET"
echo "✅ Generated $OUT"
