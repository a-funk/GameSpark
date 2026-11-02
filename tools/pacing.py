"""Frame pacing on a fixed-refresh display (the 59.94 Hz TV, no VRR): which frames the screen showed for more than one
refresh, how regularly that happens, and what ran meanwhile. An average "60 fps" can hide a frame repeated every
second; on a VRR monitor the same frame times would not show.

  python3 -I tools/pacing.py trace OUT_DIR SECS [PID]   record a running VKD3D-Proton game from the kernel (root,
                                    through lib/env.sh as_root): nothing is injected, no overlay, no relaunch, so it
                                    also works on a player's own session. PID defaults to the process with a
                                    "vkd3d-swapchain" thread. Writes trace.txt (tools/frametrace.bt), gpu.txt
                                    (nvidia-smi every 100 ms), pad.txt (DualSense triggers, to tell racing from menus)
                                    and display.txt (the mode's exact refresh rate).
  python3 -I tools/pacing.py report RUN [FROM TO]        RUN = a trace dir, or a MangoHud CSV (its frame times; only
                                    meaningful with VSync on). FROM/TO: seconds into the run. Prints JSON; writes
                                    frames.csv and pacing.svg next to RUN.
  python3 -I tools/pacing.py --selftest

"shown" = refreshes between a frame reaching the screen and the next one: 1 is smooth, 2 means the screen showed the
same frame twice (a visible hitch at a fixed refresh rate). The period of those repeats comes from the autocorrelation
of a per-refresh repeat indicator (a uniform time base, unlike frame numbers), and from the gaps between repeats.
"""
import csv
import glob
import json
import os
import re
import signal
import subprocess
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# Columns of frametrace.bt's P lines after the timestamp: on-CPU microseconds since the previous frame, by group.
GROUPS = ["game_thread", "render_thread", "rhi", "vkd3d_queue", "present_wait", "task_workers", "shader_compile",
          "game_other", "wineserver", "steamwebhelper", "xorg", "gnome_shell", "other"]


def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def refresh_hz():
    """Exact refresh rate of the current mode (pixel clock / total pixels): 59.94 is 59.9404 on the TV."""
    out = sh("xrandr", "--verbose")
    m = re.search(r"\s([\d.]+)MHz[^\n]*\*current\n\s+h:.*total\s+(\d+).*\n\s+v:.*total\s+(\d+)", out)
    return float(m[1]) * 1e6 / (int(m[2]) * int(m[3])) if m else None


def threads(pid):
    out = {}
    for d in glob.glob(f"/proc/{pid}/task/*"):
        try:
            out[int(os.path.basename(d))] = open(f"{d}/comm").read().strip()
        except OSError:
            pass
    return out


def trace(out_dir, secs, pid=None):
    if pid is None:
        for p in sorted(int(x) for x in os.listdir("/proc") if x.isdigit()):
            if "vkd3d-swapchain" in threads(p).values():
                pid = p
                break
    if pid is None:
        sys.exit("no running process with a vkd3d-swapchain thread (a VKD3D-Proton game)")
    sync = [t for t, c in threads(pid).items() if c == "vkd3d-swapchain"]
    if len(sync) != 1:
        sys.exit(f"expected one vkd3d-swapchain thread in {pid}, found {sync}")
    ws = sh("pgrep", "-f", "wineserver").split() or ["0"]
    os.makedirs(out_dir, exist_ok=True)
    hz = refresh_hz()
    with open(f"{out_dir}/display.txt", "w") as f:
        f.write(f"{hz}\n")
    with open(f"{out_dir}/meta.json", "w") as f:
        json.dump({"pid": pid, "sync_tid": sync[0], "wineserver": int(ws[0]), "secs": secs, "refresh_hz": hz,
                   "start": time.strftime("%Y-%m-%d %H:%M:%S"),
                   # trace.txt's clock is CLOCK_MONOTONIC: this pair converts its times to wall clock
                   "wall": time.time(), "mono_ns": time.monotonic_ns(), "comm": open(f"/proc/{pid}/comm").read().strip()}, f)
    helpers = []
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        # nvidia-smi and the pad reader stamp lines with CLOCK_MONOTONIC, bpftrace's nsecs clock
        gpu = subprocess.Popen(["nvidia-smi", "--query-gpu=utilization.gpu,clocks.gr", "--format=csv,noheader,nounits",
                                "-lms", "100"], stdout=subprocess.PIPE, text=True)
        helpers.append(gpu)
        bt = subprocess.Popen(["bash", "-c", '. "$1/lib/env.sh"; shift; as_root "$@"', "_", ROOT, "timeout", "-s",
                               "INT", str(secs), "bpftrace", "-q", f"{ROOT}/tools/frametrace.bt", str(pid),
                               str(sync[0]), ws[0]], stdout=open(f"{out_dir}/trace.txt", "w"))
        helpers.append(bt)
        pad = pad_reader(f"{out_dir}/pad.txt")
        with open(f"{out_dir}/gpu.txt", "w") as g:
            for line in gpu.stdout:
                g.write(f"{time.monotonic_ns()} {line.strip().replace(',', '')}\n")
                if bt.poll() is not None:
                    break
        bt.wait()
        if pad:
            pad.terminate()
    finally:
        for h in helpers:
            if h.poll() is None:
                h.terminate()
    print(out_dir)


def pad_reader(path):
    """DualSense trigger and button events (EV_ABS Z/RZ, EV_KEY) with the monotonic time they were read."""
    dev = None
    for line in open("/proc/bus/input/devices").read().split("\n\n"):
        if '"DualSense Wireless Controller"' in line:
            dev = "/dev/input/" + re.search(r"(event\d+)", line)[1]
    if not dev or not os.access(dev, os.R_OK):
        return None
    code = ("import os, struct, sys, time\n"
            "fd = os.open(sys.argv[1], os.O_RDONLY); out = open(sys.argv[2], 'w', buffering=1)\n"
            "while True:\n"
            "    d = os.read(fd, 24 * 64)\n"
            "    for i in range(0, len(d), 24):\n"
            "        _, _, t, c, v = struct.unpack('qqHHi', d[i:i + 24])\n"
            "        if t == 1 or (t == 3 and c in (2, 5)): out.write(f'{time.monotonic_ns()} {t} {c} {v}\\n')\n")
    return subprocess.Popen([sys.executable, "-I", "-c", code, dev, path])


def load(run):
    """-> dict: t (s, when each frame's present completed), cpu (frames x groups, ms), rq_sum/rq_max (ms), lat
    (vkQueuePresentKHR to present-wait done, ms, NaN where unknown), gpu (util %, per frame), M (s, compositor swaps),
    pad (s of trigger/button events), hz."""
    if os.path.isfile(run):   # MangoHud CSV: frame times as the game presented them
        rows = list(csv.reader(open(run)))
        head = next(i for i, r in enumerate(rows) if "frametime" in r)
        cols = rows[head]
        data = np.array([[float(x) for x in r] for r in rows[head + 1:] if len(r) == len(cols)])
        ft = data[:, cols.index("frametime")]
        out = {"t": np.cumsum(ft) / 1e3, "hz": None}
        if "gpu_load" in cols:
            out["gpu"] = data[:, cols.index("gpu_load")]
        return out
    P, R, G, M = [], [], [], []
    for line in open(f"{run}/trace.txt"):
        f = line.split()
        if not f or not f[1].isdigit():
            continue
        if f[0] == "P" and len(f) == 2 + len(GROUPS) + 2:
            P.append([int(x) for x in f[1:]])
        elif f[0] == "R":
            R.append(int(f[1]))
        elif f[0] == "G":
            G.append(int(f[1]))
        elif f[0] == "M":
            M.append(int(f[1]))
    P = np.array(P, dtype=np.float64)
    t0 = P[0, 0]
    out = {"t": (P[:, 0] - t0) / 1e9, "cpu": P[:, 1:1 + len(GROUPS)] / 1e3, "rq_sum": P[:, -2] / 1e3,
           "rq_max": P[:, -1] / 1e3, "t0": t0, "M": (np.array(M, dtype=np.float64) - t0) / 1e9}
    # each frame's handoff to the driver: the last R before its P (none when the waiter was still busy)
    R = np.array(R, dtype=np.float64)
    i = np.searchsorted(R, P[:, 0]) - 1
    prev = np.concatenate([[-np.inf], P[:-1, 0]])
    ok = (i >= 0) & (R[np.maximum(i, 0)] > prev)
    out["lat"] = np.where(ok, (P[:, 0] - R[np.maximum(i, 0)]) / 1e6, np.nan)
    try:
        g = np.loadtxt(f"{run}/gpu.txt", ndmin=2)
        j = np.clip(np.searchsorted(g[:, 0], P[:, 0]), 0, len(g) - 1)
        out["gpu"] = g[j, 1]
    except (OSError, ValueError, IndexError):
        pass
    pad = [int(x.split()[0]) for x in open(f"{run}/pad.txt")] if os.path.exists(f"{run}/pad.txt") else []
    out["pad"] = (np.array(pad, dtype=np.float64) - t0) / 1e9
    try:
        out["hz"] = float(open(f"{run}/display.txt").read().split()[0])
    except (OSError, ValueError, IndexError):
        out["hz"] = None
    return out


def crop(d, a, b):
    m = (d["t"] >= a) & (d["t"] <= b)
    out = {k: (v[m] if isinstance(v, np.ndarray) and v.shape[:1] == m.shape else v) for k, v in d.items()}
    for k in ("M", "pad"):
        if k in d:
            out[k] = d[k][(d[k] >= a) & (d[k] <= b)]
    return out


def composite(tP, tM):
    """The game's frames as a compositor showed them. Frame i reaches the screen with the compositor's first swap after
    it, unless the next frame arrives before that swap: then it is never shown (dropped). -> (swap time of each shown
    frame, times of dropped frames, share of swaps that came within 5 ms of a game frame)."""
    tM = tM[(tM > tP[0]) & (tM <= tP[-1])]
    if len(tM) < 2:
        return None, None, 0.0
    j = np.searchsorted(tM, tP, side="right")   # index of the first swap after each frame
    own = (j[:-1] < j[1:]) & (j[:-1] < len(tM))  # the last frame's fate is unknown
    k = np.searchsorted(tP, tM, side="right") - 1
    follow = float(((tM - tP[np.maximum(k, 0)]) < 5e-3).mean())
    return tM[j[:-1][own]], tP[:-1][~own], follow


def acf(x, maxlag):
    x = x - x.mean()
    n = len(x)
    f = np.fft.rfft(x, 2 * n)
    a = np.fft.irfft(f * np.conj(f))[:maxlag + 1]
    return a / a[0] if a[0] > 0 else a


def analyse(t, hz=None, drops=()):
    """t: display time of each frame (s); drops: times of frames never shown (a compositor's). -> summary dict plus
    arrays (shown per interval, refresh slot of each hitch, autocorrelation). A hitch is a repeat (a frame shown 2+
    refreshes) or a dropped frame (motion skips one); the period is that of all hitches."""
    dt = np.diff(t) * 1e3
    T = 1e3 / hz if hz else float(np.median(dt[(dt > 12) & (dt < 22)]))
    shown = np.maximum(np.rint(dt / T), 1).astype(int)
    T_fit = float(dt.sum() / shown.sum())   # the display's real period as this clock sees it
    shown = np.maximum(np.rint(dt / T_fit), 1).astype(int)
    slot = np.cumsum(shown)                 # refresh count at each frame: a uniform time base
    rep = np.zeros(slot[-1] + 1)
    rep[slot[shown > 1]] = 1                # a repeat ends at this refresh
    if len(drops):                          # a dropped frame: at the refresh of the next frame shown
        rep[slot[np.clip(np.searchsorted(t[1:], drops), 0, len(slot) - 1)]] = 1
    reps = np.flatnonzero(rep)
    gaps = np.diff(reps)
    secs = float(t[-1] - t[0])
    s = {"frames": len(t), "seconds": round(secs, 1), "refresh_ms": round(T_fit, 4),
         "refresh_hz": round(1e3 / T_fit, 4), "fps": round((len(t) - 1) / secs, 2),
         "shown_once_pct": round(100 * float((shown == 1).mean()), 2),
         "repeats": int((shown > 1).sum()), "extra_refreshes": int((shown - 1).sum()),
         "repeats_per_min": round(60 * float((shown > 1).sum()) / secs, 1),
         "shown_hist": {int(k): int(v) for k, v in zip(*np.unique(shown, return_counts=True))},
         "dropped": len(drops), "hitches_per_min": round(60 * float(rep.sum()) / secs, 1),
         "stalls_100ms": int((dt > 100).sum()),   # one picture held 100 ms or more: a visible freeze
         "early_frames": int((dt < 0.5 * T_fit).sum()),   # two frames in one refresh: not FIFO (tearing/mailbox)
         "interval_jitter_ms": round(float(np.std(dt[shown == 1] - T_fit)), 3) if (shown == 1).any() else None}
    if len(gaps) >= 3:
        q = np.percentile(gaps, [10, 25, 50, 75, 90])
        s["hitch_gap_refreshes"] = {"p10": q[0], "p25": q[1], "median": q[2], "p75": q[3], "p90": q[4],
                                     "cv": round(float(gaps.std() / gaps.mean()), 2)}
        s["hitch_gap_seconds_median"] = round(float(q[2] * T_fit / 1e3), 3)
    a = acf(rep, min(len(rep) // 2, int(30e3 / T_fit)))
    if len(a) > 4 and len(reps) >= 3:
        lag = int(np.argmax(a[2:])) + 2
        # the strongest repeat period and how much of the pattern it explains (1 = clockwork, ~0 = random)
        s["period"] = {"refreshes": lag, "seconds": round(lag * T_fit / 1e3, 3), "acf": round(float(a[lag]), 3)}
        pk = [k for k in range(2, len(a) - 1) if a[k] > a[k - 1] and a[k] >= a[k + 1] and a[k] > 0.1]
        s["acf_peaks"] = [[k, round(k * T_fit / 1e3, 3), round(float(a[k]), 3)]
                          for k in sorted(pk, key=lambda k: -a[k])[:6]]
    # does the rate drift? repeats per 10 s window
    w = np.arange(0, secs, 10)
    ht = t[0] + reps * T_fit / 1e3
    s["hitches_per_10s"] = [int(((ht - t[0] >= x) & (ht - t[0] < x + 10)).sum()) for x in w]
    return s, shown, reps, a


def attribution(d, late):
    """Mean of each per-frame measure over smooth frames vs hitched ones (late: per interval between game frames);
    per-group CPU as cores (ms of CPU per ms of interval), so long intervals don't look busier just by being long."""
    dt = np.diff(d["t"]) * 1e3
    out = {}

    def row(name, v):
        v = v[1:]
        if late.any() and (~late).any():
            out[name] = [round(float(np.nanmean(v[~late])), 3), round(float(np.nanmean(v[late])), 3)]
    if "cpu" in d:
        for i, g in enumerate(GROUPS):
            row(g + "_cores", np.concatenate([[np.nan], d["cpu"][1:, i] / dt]))
        row("rq_wait_ms", d["rq_sum"])
        row("rq_max_ms", d["rq_max"])
    if "lat" in d:
        row("present_latency_ms", d["lat"])
    if "gpu" in d:
        row("gpu_util", d["gpu"])
    return {"columns": ["smooth", "hitch"], **out}


def svg(path, t, reps, a, T, what):
    """Three panels: each frame's time on screen, the hitch autocorrelation, the gaps between hitches."""
    W, H, pad = 1200, 220, 40
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{3 * H + 20}" font-family="sans-serif" '
             f'font-size="12"><rect width="100%" height="100%" fill="white"/>']

    def panel(y0, title, xs, ys, xmax, ymax, xlabel, kind):
        parts.append(f'<text x="{pad}" y="{y0 + 15}" font-weight="bold">{title}</text>')
        parts.append(f'<rect x="{pad}" y="{y0 + 22}" width="{W - 2 * pad}" height="{H - 60}" fill="none" stroke="#999"/>')
        sx = lambda x: pad + (W - 2 * pad) * x / xmax
        sy = lambda y: y0 + 22 + (H - 60) * (1 - min(y, ymax) / ymax)
        if kind == "line":
            pts = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in zip(xs, ys))
            parts.append(f'<polyline points="{pts}" fill="none" stroke="#1f6fb2" stroke-width="1"/>')
        else:
            for x, y in zip(xs, ys):
                c = "#c0392b" if kind == "dots" and y > 1.5 * T else "#1f6fb2"
                parts.append(f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="1.5" fill="{c}"/>')
        parts.append(f'<text x="{pad}" y="{y0 + H - 22}">0</text><text x="{W - pad - 60}" y="{y0 + H - 22}">'
                     f'{xmax:.4g} {xlabel}</text><text x="2" y="{y0 + 32}">{ymax:.3g}</text>')
    dt = np.diff(t) * 1e3
    t = t[1:] - t[0]
    panel(0, f"{what}: time on screen per frame (ms); red = shown 2+ refreshes", t, dt, max(t[-1], 1), 5 * T, "s", "dots")
    if len(a) > 2:
        lags = np.arange(len(a))
        panel(H, "autocorrelation of hitches (lag in refreshes)", lags[1:], np.clip(a[1:], 0, 1), len(a), 1.0,
              "refreshes", "line")
    if len(reps) > 1:
        g = np.diff(reps)
        hist = np.bincount(g, minlength=2)
        panel(2 * H, "gaps between hitches (count per gap in refreshes)", np.arange(len(hist)), hist, len(hist),
              max(hist.max(), 1), "refreshes", "bars")
    parts.append("</svg>")
    open(path, "w").write("\n".join(parts))


def report(run, a=None, b=None):
    d = load(run)
    if a is not None:
        d = crop(d, float(a), float(b))
    sg, shown, reps, ac = analyse(d["t"], d.get("hz"))
    out = {"game": sg}
    bad = shown > 1                  # per interval between frames: the game's own repeat
    stream, drops = d["t"], ()
    if len(d.get("M", [])):
        st, drops, follow = composite(d["t"], d["M"])
        out["compositor"] = {"swaps": int(len(d["M"])), "swaps_after_a_game_frame_pct": round(100 * follow, 1)}
        # Mutter composites the game (it did not let it bypass): the TV shows Mutter's swaps, so that is the stream
        # whose repeats and drops the player sees. A bypassed game leaves Mutter nearly idle (35 swaps in 54 s); how
        # soon a swap follows a frame depends on the game's pacing (43-95 %), so it does not decide.
        nM = int(((d["M"] > d["t"][0]) & (d["M"] <= d["t"][-1])).sum())
        if st is not None and nM > 0.5 * len(d["t"]):
            out["screen"], shown, reps, ac = analyse(st, d.get("hz"), drops)
            stream = st
            bad = bad | np.isin(d["t"][1:], drops)
        else:
            drops = ()
    out["attribution"] = attribution(d, bad)
    if len(d.get("pad", [])):
        out["pad_events"] = int(len(d["pad"]))
    base = run if os.path.isdir(run) else os.path.splitext(run)[0]
    sfx = f"-{a}-{b}" if a is not None else ""
    out_csv = f"{base}/frames{sfx}.csv" if os.path.isdir(run) else f"{base}.frames{sfx}.csv"
    with open(out_csv, "w", newline="") as f:   # one row per game frame
        w = csv.writer(f)
        w.writerow(["t_s", "game_interval_ms", "game_shown", "dropped"] + [g + "_ms" for g in GROUPS if "cpu" in d]
                   + (["rq_wait_ms", "rq_max_ms", "present_latency_ms"] if "cpu" in d else [])
                   + (["gpu_util"] if "gpu" in d else []))
        dt = np.diff(d["t"]) * 1e3
        gshown = np.maximum(np.rint(dt / sg["refresh_ms"]), 1).astype(int)
        dropped = np.isin(d["t"], drops)
        for i in range(1, len(d["t"])):
            r = [round(d["t"][i] - d["t"][0], 4), round(dt[i - 1], 3), gshown[i - 1], int(dropped[i])]
            if "cpu" in d:
                r += [round(x, 3) for x in d["cpu"][i]] + [d["rq_sum"][i], d["rq_max"][i], round(d["lat"][i], 3)]
            if "gpu" in d:
                r.append(d["gpu"][i])
            w.writerow(r)
    svg(out_csv.replace(".csv", ".svg").replace("frames", "pacing"), stream, reps, ac, sg["refresh_ms"],
        "screen (compositor)" if stream is not d["t"] else "game presents")
    print(json.dumps(out, indent=1))


def selftest():
    T = 1e3 / 59.9404
    rng = np.random.default_rng(1)
    # a game paced at 55 fps on FIFO: each frame waits for the next refresh -> a repeat about every 12 refreshes
    ready = np.cumsum(np.full(3300, 1e3 / 55)) + rng.normal(0, 0.3, 3300)
    disp = np.ceil(ready / T) * T + rng.normal(0, 0.2, 3300)
    s, shown, reps, a = analyse(disp / 1e3, 59.9404)
    assert 4.5 < s["repeats_per_min"] / 60 < 5.5, s
    assert 11 <= s["period"]["refreshes"] <= 13, s["period"]
    assert s["hitch_gap_refreshes"]["median"] in (11, 12, 13), s
    # every frame shown once: no repeats, no period
    s, *_ = analyse((np.arange(3000) * T + rng.normal(0, 0.2, 3000)) / 1e3, 59.9404)
    assert s["repeats"] == 0 and s["shown_once_pct"] == 100.0 and "period" not in s, s
    # one repeat every 1000 refreshes (a 60.000 fps limiter against 59.94 Hz): period 1000 refreshes, 16.7 s
    sl = np.arange(6000) + np.arange(6000) // 999
    s, *_ = analyse(sl * T / 1e3, 59.9404)
    assert s["repeats"] == 6 and abs(s["period"]["refreshes"] - 1000) <= 1, s
    assert abs(s["period"]["seconds"] - 16.68) < 0.05, s
    # a compositor that misses every 20th refresh while the game presents every refresh: the game's own stream is
    # smooth, the screen repeats one frame and drops the next every 20 refreshes
    k = np.arange(3000)
    tP = (k * T + rng.normal(0, 0.2, 3000)) / 1e3
    tM = (k[k % 20 != 7] * T + 1.5) / 1e3
    st, drops, follow = composite(tP, tM)
    assert follow > 0.99 and 145 <= len(drops) <= 150, (follow, len(drops))
    s, *_ = analyse(st, 59.9404, drops)
    assert s["period"]["refreshes"] == 20 and 145 <= s["repeats"] <= 150, s
    assert analyse(tP, 59.9404)[0]["repeats"] == 0
    print("selftest ok")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--selftest"]:
        selftest()
    elif sys.argv[1:2] == ["trace"] and len(sys.argv) in (4, 5):
        trace(sys.argv[2], int(sys.argv[3]), int(sys.argv[4]) if len(sys.argv) == 5 else None)
    elif sys.argv[1:2] == ["report"] and len(sys.argv) in (3, 5):
        report(*sys.argv[2:])
    else:
        sys.exit(__doc__)
