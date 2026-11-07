#!/bin/bash
# Membuat dua DMG dari build universal: Apple Silicon (arm64) dan Intel (x86_64).
# Jalankan ./build.sh dulu. Hasilnya di build/dmg/.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="build/Lega.app"
[ -d "$SRC" ] || { echo "Jalankan ./build.sh dulu"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$SRC/Contents/Info.plist")
OUT="build/dmg"
rm -rf "$OUT"; mkdir -p "$OUT"

for pair in "arm64:AppleSilicon" "x86_64:Intel"; do
  arch=${pair%%:*}; label=${pair##*:}
  stage="$OUT/stage-$label"
  mkdir -p "$stage"
  cp -R "$SRC" "$stage/"
  lipo -thin "$arch" "$SRC/Contents/MacOS/Lega" -output "$stage/Lega.app/Contents/MacOS/Lega"
  codesign --force --sign - "$stage/Lega.app"
  ln -s /Applications "$stage/Applications"
  hdiutil create -volname "Lega $VER" -srcfolder "$stage" -fs HFS+ -format UDZO -ov \
    "$OUT/Lega-$VER-$label.dmg" >/dev/null
  rm -rf "$stage"
  echo "$OUT/Lega-$VER-$label.dmg ($(du -h "$OUT/Lega-$VER-$label.dmg" | cut -f1))"
done
