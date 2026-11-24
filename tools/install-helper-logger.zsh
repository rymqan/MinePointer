#!/bin/zsh
# Puts tools/helper-logger.zsh in front of the helper inside the built AirPointer.app. Re-run after every build.sh.
set -euo pipefail
cd -- "${0:A:h}/.."
res=AirPointer.app/Contents/Resources
[[ -e $res/ClosedCaseMotion.real ]] || mv $res/ClosedCaseMotion.bin $res/ClosedCaseMotion.real
cp tools/helper-logger.zsh $res/ClosedCaseMotion.bin
chmod +x $res/ClosedCaseMotion.bin
codesign --force --sign - --timestamp=none AirPointer.app
echo "installed"
