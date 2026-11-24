# MinePointer

Play Minecraft Java on a Mac with a closed AirPods case instead of a mouse.

MinePointer reads the motion sensors of the earbuds while they sit in the closed case and turns it into mouse input: slow rotation of the case moves the camera, sharp gestures press the mouse buttons and turn the wheel. The keyboard stays as it is.

The sensor stream comes from [AirPointer](https://github.com/oscarcreatess/airpointer) (MIT). This repository is AirPointer's history with MinePointer added on top. MinePointer adds the camera, the gesture detector, calibration and mouse output.

> [!WARNING]
> This is an experimental personal project. It uses private macOS Bluetooth APIs through AirPointer's helper, and a session has side effects on the AirPods (audio and microphone are moved off them, and on some models case data and connection settings change). Read AirPointer's [Before you use it](https://github.com/oscarcreatess/airpointer#before-you-use-it) first.

## Status

Tested on one setup only: AirPods 4 with ANC, macOS 27.2.1, Apple Silicon, Minecraft Java 26.3 in fullscreen. Other AirPods models that AirPointer recognises may work but have not been tried, except AirPods Pro 1, which MinePointer does not support.

## Controls

Hold the closed case in your right hand.

| Motion | Action |
|---|---|
| Slow rotation | Camera |
| Sharp jerk down | Left click |
| Shake | Hold left button |
| Sharp jerk up | Right click (or release the bow while the right button is latched) |
| Pull toward you | Latch the right button |
| Twist | Mouse wheel, one step per twist |
| Case flat and still | Pause |
| <kbd>⌃⌥Space</kbd> | Panic: release all buttons and stop output |
| <kbd>⌃⌥C</kbd> | Recalibrate |

At start, MinePointer calibrates the grip: hold the case still, then twist it clockwise three times, then tilt it slowly.

The AirPods firmware ends the stream after about 30 minutes. Open and close the case lid to start a new session; MinePointer reconnects on its own.

## Build

Requirements: macOS 14 or later, Xcode command line tools, AirPods paired with the Mac.

The project must live at `~/Projects/MinePointer`: the app reads `config.json` and writes `logs/` there.

```sh
git clone https://github.com/rymqan/MinePointer.git ~/Projects/MinePointer
cd ~/Projects/MinePointer
./build-minepointer.sh
```

`build-minepointer.sh` compiles MinePointer and AirPointer's helpers into `build/MinePointer.app`, signs them and runs the offline self-test. It signs with the "Apple Development" identity by default. Set `MINEPOINTER_SIGNING_IDENTITY=-` to sign ad hoc; macOS then asks for the permissions again after every build.

## Run

```sh
build/MinePointer.app/Contents/MacOS/MinePointer
```

On first run, grant Bluetooth, Accessibility and Input Monitoring in System Settings. Close keyboard-layout switchers that use event taps while playing: they can swallow key-ups and leave movement keys stuck.

Other modes:

- `--self-test` runs the offline checks.
- `--replay [take ...]` replays recorded sessions from `logs/` through the camera and gesture detector.
- `--calibrate-log logs/helper-XXXX.txt` runs the calibration on a recorded log.
- `MINEPOINTER_TRACE=1` writes a debugging trace to `logs/output-*.csv`: posted mouse moves and button events, the system-wide key presses (key codes, in every app), frontmost-app changes and timing notes. Do not share a trace you would not share as a keylog.

## Configuration

Every tunable lives in `config.json` in the project root (snake_case keys). Missing keys fall back to the defaults in `Sources/MinePointer/Types.swift`, and the file is reloaded while the app runs. The calibration rewrites `neutral_up` and `forward_axis` at every start. Set `mc_sensitivity` to match Minecraft's mouse sensitivity slider (60% = 0.3).

## Repository layout

This repository is a fork of AirPointer: its files stay where upstream keeps them, and MinePointer adds its own.

| Path | Contents |
|---|---|
| `Sources/MinePointer` | MinePointer |
| `build-minepointer.sh` | Builds MinePointer |
| `tools/` | MinePointer's recording and log tools |
| `Sources/AirPointer`, `Sources/ClosedCase*` | AirPointer; MinePointer compiles its helpers and `ClosedCaseAirPods.swift` |
| `Assets/`, `Docs/`, `Scripts/`, `Tests/`, `build.sh` | AirPointer, unused by MinePointer |

Apart from this README, `LICENSE` and `.gitignore`, AirPointer's files are unmodified; AirPointer's own README is [upstream](https://github.com/oscarcreatess/airpointer).

### Updating AirPointer

MinePointer's commits stay on top of AirPointer's history:

```sh
git remote add upstream https://github.com/oscarcreatess/airpointer.git   # once
git fetch upstream
git rebase upstream/main
git push --force-with-lease
```

If the rebase stops on `README.md`, keep this README (`git checkout --theirs README.md`, since during a rebase "theirs" is MinePointer's commit). Then run `./build-minepointer.sh` and update the commit in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## License

MinePointer is released under the [MIT License](LICENSE). AirPointer and the other third-party parts keep their own licenses; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

MinePointer is not affiliated with Apple, Mojang or Microsoft, or with the authors of AirPointer.
