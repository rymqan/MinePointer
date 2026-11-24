"""Summarise a helper log (logs/helper-*.txt): rate, gaps, duration, value ranges.

Usage: .venv/bin/python tools/helperstats.py logs/helper-XXXX.txt
Motion rows: seq,service,sensor_us,received_uptime,x,y,z (service 11 = accel, 12 = gyro). Other lines are diagnostics.
"""
import statistics
import sys
from pathlib import Path


def parse(lines):
    rows = {}
    for line in lines:
        parts = line.strip().split(",")
        if len(parts) != 7:
            continue
        try:
            seq, svc, sensor_us = int(parts[0]), int(parts[1]), int(parts[2])
            recv = float(parts[3])
            x, y, z = (int(v) for v in parts[4:])
        except ValueError:
            continue
        rows.setdefault(svc, []).append((seq, sensor_us, recv, x, y, z))
    return rows


def pct(values, p):
    s = sorted(values)
    return s[min(len(s) - 1, int(p * len(s)))]


def summary(rows):
    out = {}
    for svc, r in sorted(rows.items()):
        recv = [row[2] for row in r]
        sens = [row[1] for row in r]
        gaps = [b - a for a, b in zip(recv, recv[1:])]
        dur = recv[-1] - recv[0] if len(r) > 1 else 0.0
        mag = [(x * x + y * y + z * z) ** 0.5 for *_, x, y, z in r]
        out[svc] = {
            "samples": len(r),
            "duration_s": round(dur, 1),
            "rate_hz": round((len(r) - 1) / dur, 1) if dur else 0.0,
            "sensor_rate_hz": round((len(r) - 1) / ((sens[-1] - sens[0]) / 1e6), 1) if sens[-1] != sens[0] else 0.0,
            "gap_p50_ms": round(pct(gaps, 0.5) * 1e3, 1) if gaps else None,
            "gap_p99_ms": round(pct(gaps, 0.99) * 1e3, 1) if gaps else None,
            "gap_max_ms": round(max(gaps) * 1e3, 1) if gaps else None,
            "gaps_over_100ms": sum(g > 0.1 for g in gaps),
            "magnitude_median": round(statistics.median(mag)),
        }
    return out


def demo():
    lines = ["Earbud ModelName=x"] + [f"{i},11,{i * 5000},{i * 0.005:.6f},0,0,100000" for i in range(201)]
    lines += ["1,12,0,0.0,1,2,3", "2,12,5000,0.3,1,2,3"]
    s = summary(parse(lines))
    assert s[11]["samples"] == 201 and s[11]["rate_hz"] == 200.0 and s[11]["sensor_rate_hz"] == 200.0
    assert s[11]["magnitude_median"] == 100000 and s[12]["gaps_over_100ms"] == 1


if __name__ == "__main__":
    demo()
    path = Path(sys.argv[1])
    for svc, stats in summary(parse(path.read_text(errors="replace").splitlines())).items():
        print({11: "accel", 12: "gyro"}.get(svc, f"service {svc}"), stats)
    meta = path.with_suffix(".meta")
    if meta.exists():
        print(meta.read_text().strip())
