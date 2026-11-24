"""Gesture recording protocol and check.

Motion comes from AirPointer's helper, logged by tools/helper-logger.zsh to logs/helper-*.txt.
This tool only marks takes: it writes logs/takes.csv rows (take, start_uptime, end_uptime),
in the same clock as the helper's received_uptime (NSProcessInfo.systemUptime == CLOCK_UPTIME_RAW).

  .venv/bin/python tools/record.py            # walk through the protocol (resumes after the last finished take)
  .venv/bin/python tools/record.py redo NAME  # record one take again (the newest take with a name wins)
  .venv/bin/python tools/record.py check      # per take: samples, gaps, detected repetitions
"""
import csv
import sys
import time
from pathlib import Path

LOGS = Path(__file__).resolve().parent.parent / "logs"
TAKES = LOGS / "takes.csv"

# (name, expected bursts for check (put down + pick up = 2 per rep) or 0 for continuous, instruction)
PROTOCOL = [
    ("neutral_still", 0, "Hold the case in the neutral pose, forearm rested, still. ~10 s."),
    ("aim_slow", 0, "Aim slowly: turn left and right, tilt up and down, as if looking around. ~60 s."),
    ("aim_fast", 0, "Aim fast: sharp turns as in a fight, no gestures. ~30 s."),
    ("jerk_down", 25, "Sharp jerk down (one impulse), back to the neutral pose, pause ~1.5 s. ×25."),
    ("jerk_shake", 20, "Jerk down turning into an up-down shake for 1–3 s, then still ~1.5 s. ×20."),
    ("push_screen", 25, "Push toward the screen and back, pause ~1.5 s. ×25."),
    ("pull_self", 25, "Pull toward yourself and back, pause ~1.5 s. ×25."),
    ("jerk_up", 25, "Sharp jerk up (one impulse), back to the neutral pose, pause ~1.5 s. ×25."),
    ("bow", 10, "Pull toward yourself to draw the bow, aim ~2 s, jerk up to shoot, pause ~2 s. ×10."),
    ("twist_cw", 25, "Twist clockwise (looking past the hand at the screen) and back, pause ~1.5 s. ×25."),
    ("twist_ccw", 25, "Twist counterclockwise and back, pause ~1.5 s. ×25."),
    ("regrip", 15, "Regrip the case in your hand (move the fingers, adjust the grip), pause ~2 s. ×15."),
    ("put_down_pick_up", 20, "Put the case flat on the table for 3 s, pick it up into the neutral pose, hold 3 s. ×10."),
    ("table_still", 0, "The case lies flat on the table, hands off. ~30 s."),
    ("free_play", 0, "Mimic play without gestures: aim, look around, change pose. ~2 min."),
]


def uptime():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW)


def load_takes():
    if not TAKES.exists():
        return {}
    with TAKES.open() as f:
        return {r["take"]: (float(r["start_uptime"]), float(r["end_uptime"])) for r in csv.DictReader(f)}


def record(name, reps, text):
    print(f"\n== {name}: {text}")
    input("   Take the pose and press Enter to START...")
    start = uptime()
    input("   Recording. Press Enter to STOP...")
    end = uptime()
    new = not TAKES.exists()
    with TAKES.open("a", newline="") as f:
        w = csv.writer(f)
        if new:
            w.writerow(["take", "start_uptime", "end_uptime"])
        w.writerow([name, f"{start:.6f}", f"{end:.6f}"])
    print(f"   saved: {end - start:.1f} s")


def load_motion():
    """All accel/gyro rows from every helper log, keyed by service: list of (recv_uptime, x, y, z)."""
    rows = {11: [], 12: []}
    for path in sorted(LOGS.glob("helper-*.txt")):
        for line in path.read_text(errors="replace").splitlines():
            p = line.split(",")
            if len(p) != 7 or p[1] not in ("11", "12"):
                continue
            try:
                rows[int(p[1])].append((float(p[3]), int(p[4]), int(p[5]), int(p[6])))
            except ValueError:
                pass
    for r in rows.values():
        r.sort()
    return rows


def count_reps(accel, gyro, lin_g=0.4, gyro_dps=150, min_sep_s=0.8):
    """Rough repetition count: bursts of linear acceleration (gravity removed) or rotation rate."""
    # ponytail: EMA gravity estimate + fixed thresholds; sanity-checks a take, not a gesture detector.
    events, g = [], None
    for t, x, y, z in accel:
        v = (x / 1e5, y / 1e5, z / 1e5)
        g = v if g is None else tuple(gi + 0.01 * (vi - gi) for gi, vi in zip(g, v))
        if sum((vi - gi) ** 2 for vi, gi in zip(v, g)) ** 0.5 > lin_g:
            events.append(t)
    events += [t for t, x, y, z in gyro if (x * x + y * y + z * z) ** 0.5 / 1e5 > gyro_dps]
    reps, last = 0, -1e9
    for t in sorted(events):
        if t - last > min_sep_s:
            reps += 1
        last = t
    return reps


def check_take(start, end, motion):
    acc = [r for r in motion[11] if start <= r[0] <= end]
    gyr = [r for r in motion[12] if start <= r[0] <= end]
    times = [r[0] for r in acc]
    edges = [start] + times + [end]
    max_gap = max(b - a for a, b in zip(edges, edges[1:]))
    return {"seconds": round(end - start, 1), "accel": len(acc), "gyro": len(gyr),
            "max_gap_s": round(max_gap, 2), "reps_seen": count_reps(acc, gyr)}


def check():
    takes, motion = load_takes(), load_motion()
    expected = {n: reps for n, reps, _ in PROTOCOL}
    for name, (start, end) in takes.items():
        s = check_take(start, end, motion)
        want = expected.get(name, 0)
        flags = []
        if s["accel"] < 150 * s["seconds"]:
            flags.append("LOW DATA")
        if s["max_gap_s"] > 1.0:
            flags.append("GAP>1s")
        if want and abs(s["reps_seen"] - want) > want * 0.3:
            flags.append(f"REPS {s['reps_seen']} vs {want}")
        print(f"{name:18} {s}  {' '.join(flags) or 'ok'}")
    missing = [n for n, *_ in PROTOCOL if n not in takes]
    if missing:
        print("not recorded:", ", ".join(missing))


def demo():
    still = [(i / 200, 0, 0, 100000) for i in range(400)]
    pushes = [(2 + i * 1.5, 60000, 0, 100000) for i in range(5)]  # 0.6 g sideways: |a| barely changes
    twists = [(10 + i * 1.5, 0, 30000000, 0) for i in range(3)]  # 300 deg/s
    assert count_reps(still, still) == 0
    assert count_reps(sorted(still + pushes), []) == 5
    assert count_reps(still, twists) == 3
    motion = {11: sorted(still + pushes), 12: still}
    s = check_take(0.0, 1.995, motion)
    assert s["accel"] == 400 and s["reps_seen"] == 0 and s["max_gap_s"] <= 0.01


if __name__ == "__main__":
    demo()
    LOGS.mkdir(exist_ok=True)
    args = sys.argv[1:]
    if args[:1] == ["check"]:
        check()
    elif args[:1] == ["redo"] and len(args) == 2:
        step = next((p for p in PROTOCOL if p[0] == args[1]), None)
        if not step:
            sys.exit(f"unknown take {args[1]}; known: {', '.join(p[0] for p in PROTOCOL)}")
        record(*step)
    else:
        done = load_takes()
        for step in PROTOCOL:
            if step[0] not in done:
                record(*step)
        print("\nAll takes recorded. Run: .venv/bin/python tools/record.py check")
