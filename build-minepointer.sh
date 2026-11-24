#!/bin/zsh
# Builds MinePointer.app: our Swift app plus AirPointer's helpers (Sources/ClosedCase*, MIT), then runs the offline self-test.
# MINEPOINTER_SIGNING_IDENTITY overrides the identity; a stable identity keeps the Accessibility/Bluetooth grants across builds.
set -euo pipefail
cd -- "${0:A:h}"
identity="${MINEPOINTER_SIGNING_IDENTITY:-Apple Development}"
v=Sources
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation -framework CoreBluetooth -framework IOBluetooth -framework CoreMotion \
    $v/ClosedCaseMotion/CaseSustainedRenewal.m -o "$out/ClosedCaseMotion.bin"
xcrun swiftc -swift-version 5 -O $v/ClosedCaseRestore/ClosedCaseRestore.swift -o "$out/ClosedCaseRestore.bin" \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth
xcrun swiftc -swift-version 5 -O Sources/MinePointer/*.swift $v/AirPointer/Session/ClosedCaseAirPods.swift -o "$out/MinePointer" \
    -framework AppKit -framework Carbon -framework CoreBluetooth -framework IOBluetooth
app=build/MinePointer.app
rm -rf $app && mkdir -p $app/Contents/MacOS $app/Contents/Resources
mv "$out/MinePointer" $app/Contents/MacOS/
mv "$out/ClosedCaseMotion.bin" "$out/ClosedCaseRestore.bin" $app/Contents/Resources/
cp LICENSE THIRD_PARTY_NOTICES.md $app/Contents/Resources/
cat > $app/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MinePointer</string>
<key>CFBundleIdentifier</key><string>local.minepointer</string>
<key>CFBundleName</key><string>MinePointer</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSBluetoothAlwaysUsageDescription</key><string>MinePointer reads motion from your AirPods in the closed case to control the mouse.</string>
</dict></plist>
PLIST
for bin in ClosedCaseMotion ClosedCaseRestore; do
    codesign --force --sign "$identity" --timestamp=none --identifier local.minepointer.${bin:l} $app/Contents/Resources/$bin.bin
done
codesign --force --sign "$identity" --timestamp=none $app
$app/Contents/MacOS/MinePointer --self-test
