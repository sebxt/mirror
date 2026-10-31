#!/bin/bash
# Rebuilds Resources/AppIcon.icns from tools/icon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
swift tools/icon.swift "$tmp/icon.png"
mkdir "$tmp/AppIcon.iconset"
for px in 16 32 128 256 512; do
  sips -z $px $px "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${px}x${px}.png" >/dev/null
  sips -z $((px * 2)) $((px * 2)) "$tmp/icon.png" --out "$tmp/AppIcon.iconset/icon_${px}x${px}@2x.png" >/dev/null
done
mkdir -p Resources
iconutil -c icns "$tmp/AppIcon.iconset" -o Resources/AppIcon.icns
cp "$tmp/icon.png" Resources/AppIcon.png
rm -rf "$tmp"
