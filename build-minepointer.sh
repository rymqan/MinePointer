#!/bin/zsh
# Builds MinePointer.app (arm64, macOS 14+): our Swift app plus AirPointer's helpers (Sources/ClosedCase*, MIT), signs it, then runs the offline self-test.
# MINEPOINTER_SIGNING_IDENTITY overrides the identity ("-" = ad hoc); a stable identity keeps the Accessibility/Bluetooth grants across builds.
# MINEPOINTER_RELEASE=1 signs with a secure timestamp (needs network), as a notarization-ready build requires.
set -euo pipefail
cd -- "${0:A:h}"
identity="${MINEPOINTER_SIGNING_IDENTITY:-Apple Development}"
version="$(<Packaging/VERSION)"
# CFBundleVersion is the commit count; 1 when there is no git history (e.g. a source archive).
build_number="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
# An ad-hoc signature cannot carry a secure timestamp.
if [[ "${MINEPOINTER_RELEASE:-}" == 1 && "$identity" != "-" ]]; then timestamp=--timestamp; else timestamp=--timestamp=none; fi
v=Sources
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Compile everything first so a failed build leaves the previous app untouched.
clang -fobjc-arc -Wall -Wextra -Werror -arch arm64 -mmacosx-version-min=14.0 \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth -framework CoreMotion \
    $v/ClosedCaseMotion/CaseSustainedRenewal.m -o "$out/ClosedCaseMotion"
xcrun swiftc -target arm64-apple-macos14.0 -swift-version 5 -O $v/ClosedCaseRestore/ClosedCaseRestore.swift -o "$out/ClosedCaseRestore" \
    -framework Foundation -framework CoreBluetooth -framework IOBluetooth
xcrun swiftc -target arm64-apple-macos14.0 -swift-version 5 -O \
    Sources/MinePointer/*.swift Sources/MinePointer/App/*.swift \
    $v/AirPointer/Session/ClosedCaseAirPods.swift $v/AirPointer/Interface/RemoteKit.swift $v/AirPointer/Interface/AccessibilityGuide.swift \
    -o "$out/MinePointer" \
    -framework AppKit -framework Carbon -framework CoreBluetooth -framework IOBluetooth -framework ServiceManagement -framework SceneKit
app=build/MinePointer.app
rm -rf $app && mkdir -p $app/Contents/MacOS $app/Contents/Helpers $app/Contents/Resources
mv "$out/MinePointer" $app/Contents/MacOS/
mv "$out/ClosedCaseMotion" "$out/ClosedCaseRestore" $app/Contents/Helpers/
cp Packaging/AppIcon-*.icns Packaging/Icon/MenuBarIcon.svg LICENSE THIRD_PARTY_NOTICES.md $app/Contents/Resources/
cp Packaging/AppIcon-green.icns $app/Contents/Resources/AppIcon.icns
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>MinePointer</string>
<key>CFBundleIdentifier</key><string>io.github.rymqan.MinePointer</string>
<key>CFBundleName</key><string>MinePointer</string>
<key>CFBundleDisplayName</key><string>MinePointer</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build_number</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>MIT License, see LICENSE. Copyright (c) 2026 Alisher Rymkan, Oscar Nicholas.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>MinePointer reads motion from your AirPods in the closed case to control the mouse.</string>
</dict></plist>
PLIST
# Sign inside-out (helpers, then the app) with the hardened runtime. No entitlements: the helpers only load Apple's own frameworks.
for bin in ClosedCaseMotion ClosedCaseRestore; do
    codesign --force --sign "$identity" $timestamp --options runtime --identifier io.github.rymqan.MinePointer.$bin $app/Contents/Helpers/$bin
done
codesign --force --sign "$identity" $timestamp --options runtime $app
codesign --verify --strict --deep $app
$app/Contents/MacOS/MinePointer --self-test
