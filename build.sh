#!/bin/bash
# Kompilasi Lega jadi .app universal (Apple Silicon dan Intel),
# lalu pasang ke ~/Applications. Pakai --no-install untuk build saja.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Lega.app"
BIN="$APP/Contents/MacOS/Lega"
MIN=15.0

[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos$MIN" \
    Sources/main.swift -o "build/Lega-$arch"
done
lipo -create build/Lega-arm64 build/Lega-x86_64 -output "$BIN"
rm build/Lega-arm64 build/Lega-x86_64

cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Lega</string>
  <key>CFBundleDisplayName</key><string>Lega</string>
  <key>CFBundleIdentifier</key><string>id.innovationkit.lega</string>
  <key>CFBundleExecutable</key><string>Lega</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>$MIN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License. Wira Perdana, InnovationKit.</string>
  <key>NSAppleEventsUsageDescription</key><string>Untuk mengosongkan Trash lewat Finder.</string>
</dict>
</plist>
EOF

codesign --force --sign - "$APP"
echo "Build: $APP ($(lipo -archs "$BIN"))"

if [ "${1:-}" != "--no-install" ]; then
  osascript -e 'tell application "Lega" to quit' 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Lega.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Terpasang: $HOME/Applications/Lega.app"
fi
