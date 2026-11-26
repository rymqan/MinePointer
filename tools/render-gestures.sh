#!/bin/zsh
# Re-renders the gesture animations in media/gestures/ from the clips in Sources/MinePointer/CaseMotion.swift (the app plays the
# same clips live). The build's self-test first checks that the detector recognizes every clip as its gesture.
set -euo pipefail
cd -- "${0:A:h:h}"
./build-minepointer.sh
build/MinePointer.app/Contents/MacOS/MinePointer --render-gestures media/gestures
