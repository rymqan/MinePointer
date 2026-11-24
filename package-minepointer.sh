#!/bin/zsh
# Builds a release MinePointer.app, checks it and packs it into build/MinePointer-<version>.dmg.
# Same identity override as build-minepointer.sh. Set MINEPOINTER_NOTARY_PROFILE (a `notarytool store-credentials` profile) to notarize and staple.
set -euo pipefail
cd -- "${0:A:h}"
identity="${MINEPOINTER_SIGNING_IDENTITY:-Apple Development}"
version="$(<Packaging/VERSION)"
app=build/MinePointer.app
dmg=build/MinePointer-$version.dmg
id=io.github.rymqan.MinePointer

# A release build signs with a secure timestamp.
MINEPOINTER_RELEASE=1 ./build-minepointer.sh

fail() { print -u2 "package: $*"; exit 1; }

# check <what> <actual> <expected>
check() { [[ "$2" == "$3" ]] || fail "$1: got '$2', expected '$3'"; print "ok  $1 = $2"; }

# True when codesign's flags list "runtime" (0x10000, or 0x10002 for ad hoc). Captures all output first: grep -q would SIGPIPE codesign under pipefail.
has_runtime() { local info re='flags=0x[0-9a-f]+\([^)]*runtime'; info="$(codesign -dvv $1 2>&1)"; [[ "$info" =~ $re ]]; }

# Verifies the signature, the hardened runtime flag and the architecture of the app and both helpers in the bundle at $1.
verify_bundle() {
    local bundle=$1 bin
    codesign --verify --deep --strict --verbose=2 $bundle
    for bin in $bundle/Contents/MacOS/MinePointer $bundle/Contents/Helpers/ClosedCaseMotion $bundle/Contents/Helpers/ClosedCaseRestore; do
        has_runtime $bin || fail "hardened runtime flag missing on $bin"
        check "arch of ${bin:t}" "$(lipo -archs $bin)" arm64
    done
    has_runtime $bundle || fail "hardened runtime flag missing on $bundle"
}

verify_bundle $app
plist=$app/Contents/Info.plist
check CFBundleIdentifier "$(plutil -extract CFBundleIdentifier raw $plist)" $id
check CFBundleExecutable "$(plutil -extract CFBundleExecutable raw $plist)" MinePointer
check CFBundleShortVersionString "$(plutil -extract CFBundleShortVersionString raw $plist)" $version
check LSMinimumSystemVersion "$(plutil -extract LSMinimumSystemVersion raw $plist)" 14.0
check LSUIElement "$(plutil -extract LSUIElement raw $plist)" true
check CFBundleIconFile "$(plutil -extract CFBundleIconFile raw $plist)" AppIcon
[[ -f $app/Contents/Resources/AppIcon.icns ]] || fail "AppIcon.icns missing from the bundle"
[[ "$(plutil -extract CFBundleVersion raw $plist)" == <-> ]] || fail "CFBundleVersion is not a number"

# DMG: the app next to an Applications shortcut.
stage="$(mktemp -d)"
mnt="$(mktemp -d)"
cleanup() { hdiutil detach -quiet $mnt 2>/dev/null || true; rm -rf "$stage" "$mnt"; }
trap cleanup EXIT
ditto $app $stage/MinePointer.app
ln -s /Applications $stage/Applications
rm -f $dmg
hdiutil create -volname "MinePointer $version" -srcfolder $stage -format UDZO -ov $dmg
if [[ "$identity" != "-" ]]; then codesign --force --sign "$identity" --timestamp $dmg; fi
hdiutil verify $dmg

# Open the finished image and verify the app as the recipient will see it.
hdiutil attach -nobrowse -readonly -mountpoint $mnt $dmg
verify_bundle $mnt/MinePointer.app
hdiutil detach $mnt

if [[ -n "${MINEPOINTER_NOTARY_PROFILE:-}" ]]; then
    xcrun notarytool submit $dmg --keychain-profile "$MINEPOINTER_NOTARY_PROFILE" --wait
    xcrun stapler staple $dmg
    xcrun stapler validate $dmg
else
    print "The DMG is not notarized: recipients must use \"Open Anyway\" in System Settings > Privacy & Security once."
fi

# Gatekeeper verdicts are information only; without a Developer ID they are expected to reject.
spctl -a -t exec -vv $app || true
spctl -a -t open --context context:primary-signature -vv $dmg || true

print "DMG:    $dmg"
print "Size:   $(du -h $dmg | cut -f1) ($(stat -f %z $dmg) bytes)"
print "SHA256: $(shasum -a 256 $dmg | cut -d' ' -f1)"
