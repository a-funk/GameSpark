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


def cp2077_setting(run, name):
    """A value from the UserSettings.json snapshot bench/games/cyberpunk2077.sh saves with each run."""
    try:
        for g in json.load(open(os.path.join(run, "UserSettings.json")))["data"]:
            for o in g["options"]:
                if o["name"] == name:
                    return o.get("value")
    except (OSError, ValueError, KeyError):
        return None


def parse_cyberpunk2077(run):
    """benchmarkResults/<ts>/summary.json + frames.csv. With frame generation, column 1 is the rendered frame time
    and the active generator's column is the displayed frame time."""
    res = os.path.join(run, "result")
    S = json.load(open(os.path.join(res, "summary.json")))["Data"]
    with open(os.path.join(res, "frames.csv")) as f:
        rows = list(csv.reader(f))[1:]
    col = lambda c: [float(r[c]) for r in rows if len(r) > c and r[c].strip()]
    shown = 2 if S.get("DLSSFrameGenEnabled") else (3 if S.get("FSR3Enabled") and S.get("frameGenerationType") else 1)
    # summary.json's DLSSQuality enum is not the menu order (Quality reports as 2), so use the saved setting.
    q = cp2077_setting(run, "DLSS") or f"mode {S.get('DLSSQuality')}"
    upscale = f"DLSS {q}" if S.get("DLSSEnabled") else ("DLAA" if S.get("DLAAEnabled") else "native")
    fg = f"frame gen {int(S.get('DLSSMultiFrameGenFrameToGenerate') or 1) + 1}x" if S.get("DLSSFrameGenEnabled") else ""
    w, h = S["renderWidth"], S["renderHeight"]
    return {
        "game": "Cyberpunk 2077", "game_version": S.get("gameVersion"), "api": "DirectX 12 (VKD3D-Proton)",
        "resolution": f"{h}p" if w * 9 == h * 16 else f"{w}x{h}",
        "preset": " · ".join(x for x in [S.get("presetName"), upscale, fg] if x),
        "reported_avg_fps": S["averageFps"], "min_fps": S["minFps"], "max_fps": S["maxFps"], "seconds": S["time"],
        "rendered_ms": col(1), "displayed_ms": col(shown), "frame_gen": shown != 1,
        "end_ts": os.path.getmtime(os.path.join(res, "summary.json")),
    }


def parse_rottr(run):
    """OCR text of the results screen: per-scene 'Name: 144.21 FPS (min: 14.89, max: 213.24)' and 'Overall score'.
    No per-frame data, so 1% lows and fps-over-time are not available."""
    import re
    res = os.path.join(run, "result")
    text = open(os.path.join(res, "results.txt")).read()
    scenes = [{"scene": m[0].strip(), "avg_fps": float(m[1]), "min_fps": float(m[2]), "max_fps": float(m[3])}
              for m in re.findall(r"([A-Za-z' ]+):\s*([\d.]+)\s*FPS\s*\(min:\s*([\d.]+),\s*max:\s*([\d.]+)\)", text)]
    overall = float(re.search(r"Overall score:\s*([\d.]+)", text).group(1))
    start = int(open(os.path.join(res, "bench_start")).read())
    end = int(open(os.path.join(res, "bench_end")).read())
    settings = open(os.path.join(res, "settings.txt")).read() if os.path.exists(os.path.join(res, "settings.txt")) else ""
    dx12 = '"EnableDX12"=dword:00000001' in settings
    return {"game": "Rise of the Tomb Raider", "api": "DirectX 12 (VKD3D-Proton)" if dx12 else "DirectX 11 (DXVK)",
            "resolution": "1080p", "preset": ("DX12" if dx12 else "DX11") + " · default settings, VSync off",
            "reported_avg_fps": overall, "min_fps": min(x["min_fps"] for x in scenes), "max_fps": max(x["max_fps"] for x in scenes),
            "seconds": end - start, "end_ts": end, "scenes": scenes}


PARSERS = {"cyberpunk2077": parse_cyberpunk2077, "rottr": parse_rottr}


def build(run, game, label):
    p = PARSERS[game](run)
    shown, rendered = p.get("displayed_ms") or [], p.get("rendered_ms") or []
    end = p["end_ts"]
    start = end - p["seconds"]
    tel = [json.loads(l) for l in open(os.path.join(run, "telemetry.jsonl"))]
    win = [r for r in tel if start <= r["ts"] <= end] or tel
    mean = lambda k: round(sum(r.get(k) or 0 for r in win) / len(win), 1)
    rate = lambda ms: round(1000 * len(ms) / sum(ms), 1) if ms else None
    base = os.path.basename(run)
    doc = {
        "ts": f"{base[0:4]}-{base[4:6]}-{base[6:8]}T{base[9:11]}:{base[11:13]}", "run_dir": base, "variant": label,
        "game": p["game"], "game_version": p.get("game_version"), "api": p.get("api"), "resolution": p["resolution"], "preset": p["preset"],
        "avg_fps": rate(shown) or round(p["reported_avg_fps"], 1), "low1_fps": round(low1(shown), 1) if shown else None,
        "rendered_fps": rate(rendered) or round(p["reported_avg_fps"], 1), "rendered_low1_fps": round(low1(rendered), 1) if rendered else None,
        "frame_gen": bool(p.get("frame_gen")), "reported_avg_fps": round(p["reported_avg_fps"], 1),
        "min_fps": round(p["min_fps"], 1), "max_fps": round(p["max_fps"], 1), "frames": len(shown) or None, "seconds": round(p["seconds"], 1),
        "gpu_util": mean("gpu"), "gpu_power_w": mean("power"), "gpu_clock_mhz": mean("clock"),
        "cpu_util": mean("cpu"), "cpu_x925": mean("cpu_x925"), "cpu_a725": mean("cpu_a725"),
    }
    if p.get("scenes"):
        doc["scenes"] = p["scenes"]
    sched = os.path.join(run, "sched")
    if os.path.exists(sched):  # "enabled bpfland_1.1.2_..." or "disabled"
        words = open(sched).read().split()
        doc["scheduler"] = words[1].split("_")[0] if len(words) > 1 and words[0] == "enabled" else "default"
    pts, w0 = thin(win), win[0]["ts"]
    doc["series"] = {"t": [round(r["ts"] - w0, 1) for r in pts], **{k: [r.get(k) for r in pts] for k in ("gpu", "power", "cpu", "cpu_x925", "clock")}}
    f = thin(fps_per_second(shown))
    doc["fps_series"] = {"t": [t for t, _ in f], "fps": [v for _, v in f]}
    if p.get("frame_gen"):
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
    json.dump({"data": [{"group_name": "/graphics/presets", "options": [{"name": "DLSS", "value": "Quality"}]}]},
              open(os.path.join(run, "UserSettings.json"), "w"))
    d = build(run, "cyberpunk2077", "t")
    assert d["avg_fps"] == 100.0 and d["rendered_fps"] == 50.0 and d["frame_gen"] and d["gpu_util"] == 60.0, d
    assert d["ts"] == "2026-10-07T10:15" and d["resolution"] == "1080p" and "rendered" in d["fps_series"]
    assert "DLSS Quality" in d["preset"], d["preset"]
    run2 = os.path.join(os.path.dirname(run), "20261007-113000-rottr-t")
    res2 = os.path.join(run2, "result")
    os.makedirs(res2)
    open(os.path.join(res2, "results.txt"), "w").write(
        "Mountain Peak: 144.21 FPS (min: 14.89, max: 213.24)\nSyria: 61.96 FPS (min: 11.36, max: 95.12)\n"
        "Geothermal Valley: 40.78 FPS (min: 2.41, max: 83.04)\nOverall score: 83.10 FPS\n")
    open(os.path.join(res2, "bench_start"), "w").write(str(int(end) - 2))
    open(os.path.join(res2, "bench_end"), "w").write(str(int(end)))
    open(os.path.join(res2, "settings.txt"), "w").write('"EnableDX12"=dword:00000001\n')
    os.link(os.path.join(run, "telemetry.jsonl"), os.path.join(run2, "telemetry.jsonl"))
    r = build(run2, "rottr", "t")
    assert r["avg_fps"] == 83.1 and r["low1_fps"] is None and len(r["scenes"]) == 3 and r["min_fps"] == 2.4, r
    assert r["api"].startswith("DirectX 12") and r["scenes"][2]["scene"] == "Geothermal Valley", r
    print("ok")


if __name__ == "__main__":
    if sys.argv[1] == "--selftest":
        selftest()
    else:
        json.dump(build(*sys.argv[1:4]), sys.stdout)
