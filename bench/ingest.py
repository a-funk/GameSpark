"""Turn a bench/run.sh run directory into one run record (JSON on stdout).

Each game adapter's results are parsed by a function in PARSERS returning frame times plus the game's own report.
Common metrics (1% lows, fps over time, telemetry means for the benchmark window) are computed here.

Usage:      python3 -I bench/ingest.py RUN_DIR GAME LABEL
Self-check: python3 -I bench/ingest.py --selftest
"""
import csv
import json
import os
import sys


def low1(frame_ms):
    """1% low fps = fps at the 99th-percentile frame time (nearest rank)."""
    s = sorted(frame_ms)
    return 1000.0 / s[min(len(s) - 1, int(0.99 * len(s)))]


def fps_per_second(frame_ms):
    out, acc, n, t = [], 0.0, 0, 0
    for ms in frame_ms:
        acc += ms
        n += 1
        if acc >= 1000:
            t += 1
            out.append((t, round(n * 1000 / acc, 1)))
            acc, n = 0.0, 0
    return out


def thin(xs, k=150):
    step = max(1, -(-len(xs) // k))
    return xs[::step]


def parse_cyberpunk2077(res):
    """benchmarkResults/<ts>/summary.json + frames.csv. With frame generation, column 1 is the rendered frame time
    and the active generator's column is the displayed frame time."""
    S = json.load(open(os.path.join(res, "summary.json")))["Data"]
    with open(os.path.join(res, "frames.csv")) as f:
        rows = list(csv.reader(f))[1:]
    col = lambda c: [float(r[c]) for r in rows if len(r) > c and r[c].strip()]
    shown = 2 if S.get("DLSSFrameGenEnabled") else (3 if S.get("FSR3Enabled") and S.get("frameGenerationType") else 1)
    q = {0: "Auto", 1: "Quality", 2: "Balanced", 3: "Performance", 4: "Ultra Performance"}.get(S.get("DLSSQuality"), str(S.get("DLSSQuality")))
    upscale = f"DLSS {q}" if S.get("DLSSEnabled") else ("DLAA" if S.get("DLAAEnabled") else "native")
    fg = "MFG" if S.get("DLSSMultiFrameGenEnabled") else ("FG" if S.get("DLSSFrameGenEnabled") else "")
    w, h = S["renderWidth"], S["renderHeight"]
    return {
        "game": "Cyberpunk 2077", "game_version": S.get("gameVersion"), "api": "DirectX 12 (VKD3D-Proton)",
        "resolution": f"{h}p" if w * 9 == h * 16 else f"{w}x{h}",
        "preset": " · ".join(x for x in [S.get("presetName"), upscale, fg] if x),
        "reported_avg_fps": S["averageFps"], "min_fps": S["minFps"], "max_fps": S["maxFps"], "seconds": S["time"],
        "rendered_ms": col(1), "displayed_ms": col(shown), "frame_gen": shown != 1,
        "end_ts": os.path.getmtime(os.path.join(res, "summary.json")),
    }


PARSERS = {"cyberpunk2077": parse_cyberpunk2077}


def build(run, game, label):
    p = PARSERS[game](os.path.join(run, "result"))
    shown, rendered = p["displayed_ms"], p["rendered_ms"]
    end = p["end_ts"]
    start = end - p["seconds"]
    tel = [json.loads(l) for l in open(os.path.join(run, "telemetry.jsonl"))]
    win = [r for r in tel if start <= r["ts"] <= end] or tel
    mean = lambda k: round(sum(r.get(k) or 0 for r in win) / len(win), 1)
    base = os.path.basename(run)
    doc = {
        "ts": f"{base[0:4]}-{base[4:6]}-{base[6:8]}T{base[9:11]}:{base[11:13]}", "run_dir": base, "variant": label,
        "game": p["game"], "game_version": p.get("game_version"), "api": p.get("api"), "resolution": p["resolution"], "preset": p["preset"],
        "avg_fps": round(1000 * len(shown) / sum(shown), 1), "low1_fps": round(low1(shown), 1),
        "rendered_fps": round(1000 * len(rendered) / sum(rendered), 1), "rendered_low1_fps": round(low1(rendered), 1),
        "frame_gen": p["frame_gen"], "reported_avg_fps": round(p["reported_avg_fps"], 1),
        "min_fps": round(p["min_fps"], 1), "max_fps": round(p["max_fps"], 1), "frames": len(shown), "seconds": round(p["seconds"], 1),
        "gpu_util": mean("gpu"), "gpu_power_w": mean("power"), "gpu_clock_mhz": mean("clock"),
        "cpu_util": mean("cpu"), "cpu_x925": mean("cpu_x925"), "cpu_a725": mean("cpu_a725"),
    }
    pts, w0 = thin(win), win[0]["ts"]
    doc["series"] = {"t": [round(r["ts"] - w0, 1) for r in pts], **{k: [r.get(k) for r in pts] for k in ("gpu", "power", "cpu", "cpu_x925", "clock")}}
    f = thin(fps_per_second(shown))
    doc["fps_series"] = {"t": [t for t, _ in f], "fps": [v for _, v in f]}
    if p["frame_gen"]:
        doc["fps_series"]["rendered"] = [v for _, v in thin(fps_per_second(rendered))][:len(f)]
    return doc


def selftest():
    import tempfile
    assert abs(low1([10.0] * 99 + [50.0]) - 20.0) < 1e-9  # worst 1% of frames is 50 ms -> 20 fps
    assert fps_per_second([10.0] * 100) == [(1, 100.0)]
    run = os.path.join(tempfile.mkdtemp(), "20261007-101500-cyberpunk2077-t")
    res = os.path.join(run, "result")
    os.makedirs(res)
    data = {"averageFps": 100.0, "minFps": 90.0, "maxFps": 110.0, "time": 2.0, "renderWidth": 1920, "renderHeight": 1080,
            "presetName": "Custom", "DLSSEnabled": True, "DLSSQuality": 2, "DLSSFrameGenEnabled": True}
    json.dump({"Data": data}, open(os.path.join(res, "summary.json"), "w"))
    with open(os.path.join(res, "frames.csv"), "w") as fh:
        fh.write("Frame index, Frame time (ms), DLSS Frame Generation (ms)\n" + "".join(f"{i}, 20.0, 10.0\n" for i in range(200)))
    end = os.path.getmtime(os.path.join(res, "summary.json"))
    with open(os.path.join(run, "telemetry.jsonl"), "w") as fh:
        for i in range(3):
            fh.write(json.dumps({"ts": end - 1.5 + i * 0.5, "gpu": 60, "power": 40, "clock": 2000, "cpu": 50, "cpu_x925": 70, "cpu_a725": 30}) + "\n")
    d = build(run, "cyberpunk2077", "t")
    assert d["avg_fps"] == 100.0 and d["rendered_fps"] == 50.0 and d["frame_gen"] and d["gpu_util"] == 60.0, d
    assert d["ts"] == "2026-10-07T10:15" and d["resolution"] == "1080p" and "rendered" in d["fps_series"]
    print("ok")


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest()
    else:
        json.dump(build(*sys.argv[1:4]), sys.stdout)
