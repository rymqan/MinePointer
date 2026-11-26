#!/usr/bin/env python3
"""A scripted stand-in for `MinePointer --engine`, to test the UI without AirPods.

Use: MINEPOINTER_ENGINE=$PWD/tools/fake-engine.py build/MinePointer.app/Contents/MacOS/MinePointer
Options (the UI starts it with no arguments, so the environment works too):
  --error | FAKE_ENGINE=error   ends with an @error line and exit 1 (no restart expected)
  --crash | FAKE_ENGINE=crash   dies with exit 139 and no @error (restarts, then "keeps crashing")
  --fast  | FAKE_ENGINE_FAST=1  runs the script about 4 times faster
It echoes every command it reads as a log line and exits on `quit` or on stdin EOF.
After calibrating it plays the gesture clips of the app that started it (`<app> --clip-poses`): @pose lines while the sandbox
asks for them (`pose on`), and each gesture at the moment the real detector recognizes it in that clip. If the app cannot give
the clips, it names a fixed list of gestures instead.
"""
import json
import os
import subprocess
import sys
import threading
import time

args = sys.argv[1:]
mode = "error" if "--error" in args else "crash" if "--crash" in args else os.environ.get("FAKE_ENGINE", "")
speed = 0.25 if "--fast" in args or os.environ.get("FAKE_ENGINE_FAST") else 1.0

lock = threading.Lock()
session, ui_mode, left, right, gesture, seq = "", "", 0, 0, "", 0
output_off = "--output-off" in args
calibrating = False
posing = False                  # `pose on`: the clips' poses go out as @pose lines


def emit(line):
    with lock:
        sys.stdout.write(line + "\n")
        sys.stdout.flush()


def log(text):
    emit("[%s] [fake-engine] %s" % (time.strftime("%H:%M:%S"), text))


def state():
    shown = "calibrating" if calibrating else "output off" if output_off else ui_mode
    emit("\t".join(["@state", session, shown, str(left), str(right), gesture, str(seq), "0" if output_off else "1"]))


def set_session(text):
    global session
    session = text
    state()


def pause(seconds):
    time.sleep(seconds * speed)


def quit_now(reason):
    log(reason)
    emit("[fake-engine] all buttons released")
    os._exit(0)


def read_commands():
    global output_off, calibrating, posing
    for raw in sys.stdin:
        command = raw.strip()
        log("command: " + command)
        if command == "quit":
            quit_now("quit received")
        elif command == "output off":
            output_off = True
            state()
        elif command == "output on":
            output_off = False
            state()
        elif command == "pose on":
            posing = True
        elif command == "pose off":
            posing = False
        elif command == "recalibrate":
            threading.Thread(target=calibrate, daemon=True).start()
    quit_now("stdin closed")


def calibrate():
    global calibrating, ui_mode
    calibrating = True
    state()
    prompts = [
        "Calibration: hold the case still in your usual grip…",
        "Make 3 clockwise twists (and back), with a short pause between them",
        "Slowly raise and lower the far end of the case twice",
    ]
    for prompt in prompts:
        emit("@prompt\t" + prompt)
        pause(2.5)
    calibrating = False
    emit("@calibrated")
    state()


def show(name, text):
    global gesture, seq
    gesture, seq = text, seq + 1
    emit("@gesture\t" + name)
    state()


threading.Thread(target=read_commands, daemon=True).start()

log("starting (mode '%s')" % (mode or "normal"))
state()
set_session("requesting Bluetooth access")
pause(0.8)
set_session("looking for paired AirPods")
pause(0.8)
if mode == "crash":
    log("simulated crash")
    os._exit(139)
set_session("waiting: open the case lid")
pause(2.0)
if mode == "error":
    emit("@error\tYour AirPods didn’t answer. Open the lid, briefly lift and reseat one earbud, then try again.")
    sys.exit(1)
set_session("connecting")
pause(1.0)
set_session("streaming")
pause(0.5)
calibrate()
pause(1.0)
# Detector labels (CaseMotion.swift) → the engine's @gesture id and panel text (main.swift's apply).
GESTURES = {"jerk_down": ("jerkDown", "LMB click"), "shake": ("shake", "shake"), "jerk_up": ("jerkUp", "RMB click"),
            "pull": ("pull", "pull"), "bow_shot": ("bowShot", "shot"), "twist_next": ("twistNext", "slot +1"),
            "twist_previous": ("twistPrevious", "slot −1"), "veto": ("veto", "vetoed"), "pause": ("pause", "pause"),
            "resume": ("resume", "resume")}


def load_clips():
    try:
        app = subprocess.run(["ps", "-o", "comm=", "-p", str(os.getppid())], capture_output=True, text=True).stdout.strip()
        out = subprocess.run([app, "--clip-poses"], capture_output=True, text=True, timeout=20).stdout
        return [json.loads(line) for line in out.splitlines()]
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        log("no gesture clips (%s): naming gestures without motion" % error)
        return []


def play(clip):
    events = sorted(clip["events"])
    start = time.time()
    for i, pose in enumerate(clip["poses"]):
        now = i / 30
        while events and events[0][0] <= now:
            label = events.pop(0)[1]
            if label in GESTURES:
                show(*GESTURES[label])
        if posing:
            emit("@pose\t" + "\t".join("%.4f" % v for v in pose))
        time.sleep(max(0, start + (i + 1) / 30 - time.time()))


clips = load_clips()
script = [("jerkDown", "LMB click"), ("shake", "LMB hold"), ("jerkUp", "RMB click"), ("pull", "RMB latch"),
          ("twistNext", "next slot"), ("veto", "refused"), ("pause", "pause"), ("resume", "resume")]
while True:
    if clips:
        for clip in clips:
            log("clip: " + clip["id"])
            play(clip)
    else:
        for name, text in script:
            pause(1.5)
            show(name, text)
