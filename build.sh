#!/bin/bash
# Kompilasi Bersih Storage jadi .app universal (Apple Silicon dan Intel),
# lalu pasang ke ~/Applications. Pakai --no-install untuk build saja.
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Bersih Storage.app"
BIN="$APP/Contents/MacOS/BersihStorage"
MIN=15.0

[ -f Resources/AppIcon.icns ] || swift Scripts/make-icon.swift

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target "$arch-apple-macos$MIN" \
    Sources/main.swift -o "build/BersihStorage-$arch"
done
lipo -create build/BersihStorage-arm64 build/BersihStorage-x86_64 -output "$BIN"
rm build/BersihStorage-arm64 build/BersihStorage-x86_64

cp Resources/AppIcon.icns "$APP/Contents/Resources/"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Bersih Storage</string>
  <key>CFBundleDisplayName</key><string>Bersih Storage</string>
  <key>CFBundleIdentifier</key><string>id.innovationkit.bersihstorage</string>
  <key>CFBundleExecutable</key><string>BersihStorage</string>
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
  osascript -e 'tell application "Bersih Storage" to quit' 2>/dev/null || true
  mkdir -p "$HOME/Applications"
  rm -rf "$HOME/Applications/Bersih Storage.app"
  cp -R "$APP" "$HOME/Applications/"
  echo "Terpasang: $HOME/Applications/Bersih Storage.app"
fi
