#!/usr/bin/env python3
"""Autotuner: benchmark every combination of a game's knobs, keep the fastest, write profiles/GAME.conf.

Knobs are the scheduler (SCHED=default|bpfland, switched live by system/governor.sh) plus what the adapter
declares in TUNE_KNOBS ("VAR=a,b VAR2=c"; first value = default). Adapter knobs are environment variables its
game_prepare reads, so the winner is applied by running game_prepare with them set; the governor applies SCHED
whenever the game runs. Profiles are per Steam setup (profiles/<snap|fex>/GAME.conf): the same knob can help on
one and not the other.

Each adapter-knob combination starts with a discarded warm-up run (the first run after a graphics API or driver
change rebuilds shader caches), then each scheduler gets --reps runs. A challenger replaces the default
configuration only if its mean beats the default's by more than --noise percent.

Usage: bench/tune.py GAME [--reps N] [--noise PCT] [--dry-run]     (with Steam running)
       bench/tune.py GAME --apply     re-apply the running setup's profile (e.g. after switching setups)
       bench/tune.py GAME --check [--tolerance PCT]   re-run the profile's chosen configuration and exit 1 if it is
                                      more than PCT (default 4) slower than the mean the profile recorded; an apparent
                                      regression gets a second run, since the first run after a driver change rebuilds
                                      shader caches (bench/matrix.sh checks every tuned game)
Self-check: python3 -I bench/tune.py --selftest
"""
import argparse, contextlib, itertools, json, os, re, statistics, subprocess, sys, tempfile, time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SCHEDS = ["default", "bpfland"]


def parse_knobs(text):
    """'A=x,y B=z' -> [('A', ['x', 'y']), ('B', ['z'])]"""
    return [(k, v.split(",")) for k, v in (w.split("=", 1) for w in text.split())]


def plan(knobs, reps):
    """[(config, warmup)] with adapter knobs outermost, so each combination warms up once."""
    steps = []
    for values in itertools.product(*[v for _, v in knobs]):
        env = dict(zip([k for k, _ in knobs], values))
        steps.append(({"SCHED": SCHEDS[0], **env}, True))
        steps += [({"SCHED": s, **env}, False) for s in SCHEDS for _ in range(reps)]
    return steps


def key(cfg):
    return " ".join(f"{k}={v}" for k, v in cfg.items())


def choose(scores, default, noise):
    """scores {key: [fps]} -> (winner, means). The best mean must beat the default by more than noise (fraction)."""
    means = {k: statistics.mean(v) for k, v in scores.items() if v}
    best = max(means, key=means.get)
    if default in means and means[best] <= means[default] * (1 + noise):
        best = default
    return best, means


def chosen(profile_text):
    """(configuration, mean fps) of the '<- chosen' line a tuned profile records."""
    m = re.search(r"^#\s+(.+?): ([\d.]+) \(.*<- chosen$", profile_text, re.M)
    if not m:
        sys.exit("error: profile has no '<- chosen' line (hand-written profiles cannot be checked; tune the game first)")
    return m[1], float(m[2])


def adapter_sh(game, script, env=None):
    """Run shell code with lib/env.sh and the game's adapter sourced."""
    return subprocess.run(["bash", "-c", '. "$ROOT/lib/env.sh"; . "$ROOT/bench/games/$GAME.sh"; ' + script],
                          env={**os.environ, "ROOT": ROOT, "GAME": game, **(env or {})},
                          capture_output=True, text=True, check=True).stdout.strip()


def apply(game, settings):
    """Persist the adapter knobs in settings ('SCHED=x VAR=y') by running game_prepare with them set."""
    with tempfile.TemporaryDirectory() as d:
        adapter_sh(game, 'game_prepare "$OUTDIR"', {"OUTDIR": d, **dict(w.split("=", 1) for w in settings.split())})


@contextlib.contextmanager
def scheduler_control(game):
    """Pause the governor so runs can set the scheduler themselves; restore the default afterwards."""
    pause = os.path.join(adapter_sh(game, 'printf %s "$SG_DATA"'), "governor.pause")
    open(pause, "w").close()
    try:
        yield
    finally:
        subprocess.run([f"{ROOT}/system/governor.sh", "set", "default"], stdout=subprocess.DEVNULL)
        os.remove(pause)


def bench(game, cfg, warmup, prefix="tune"):
    subprocess.run([f"{ROOT}/system/governor.sh", "set", cfg["SCHED"]], check=True, stdout=subprocess.DEVNULL)
    label = f"{prefix}-" + ("warmup-" if warmup else "") + "-".join(cfg.values())
    p = subprocess.run([f"{ROOT}/bench/run.sh", game, label], env={**os.environ, **cfg}, capture_output=True, text=True)
    lines = p.stdout.strip().splitlines()
    if p.returncode or not lines:
        print(f"    failed: {(p.stderr or p.stdout).strip()[-200:]}", flush=True)
        return None
    rec = json.load(open(os.path.join(lines[-1], "run.json")))
    if rec.get("scheduler") != cfg["SCHED"]:
        print(f"    discarded: ran under {rec.get('scheduler')}, wanted {cfg['SCHED']}", flush=True)
        return None
    if rec.get("other_gpu_apps"):
        print(f"    discarded: shared the GPU with {', '.join(rec['other_gpu_apps'])}", flush=True)
        return None
    return rec


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("game")
    ap.add_argument("--reps", type=int, default=2)
    ap.add_argument("--noise", type=float, default=2.0, help="percent a challenger must beat the default by")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--tolerance", type=float, default=4.0, help="--check: percent slower that counts as a regression")
    a = ap.parse_args()
    setup = adapter_sh(a.game, 'printf %s "$GAMESPARK_STEAM"')
    path = os.path.join(ROOT, "profiles", setup, f"{a.game}.conf")
    if a.apply:
        settings = " ".join(l.strip() for l in open(path) if "=" in l and not l.startswith("#"))
        apply(a.game, settings)
        return print(f"applied {path}: {settings}")
    if a.check:
        conf, base = chosen(open(path).read())
        cfg = dict(w.split("=", 1) for w in conf.split())
        apply(a.game, conf)
        with scheduler_control(a.game):
            for attempt in (1, 2):
                rec = bench(a.game, cfg, False, prefix="check")
                delta = rec["avg_fps"] / base - 1 if rec else None
                if delta is not None and delta >= -a.tolerance / 100:
                    break
        verdict = "FAILED" if delta is None else ("REGRESSION" if delta < -a.tolerance / 100 else "ok")
        got = f"{rec['avg_fps']} fps vs profile {base} ({delta:+.1%})" if rec else f"no result vs profile {base}"
        print(f"{verdict:10} {a.game} [{setup}] {conf}: {got}", flush=True)
        sys.exit(0 if verdict == "ok" else 1)
    knobs = parse_knobs(adapter_sh(a.game, 'printf %s "${TUNE_KNOBS:-}"'))
    steps = plan(knobs, a.reps)
    for cfg, warm in steps:
        print(("warm-up " if warm else "        ") + key(cfg))
    if a.dry_run:
        return
    scores, lows, fails = {}, {}, {}
    with scheduler_control(a.game):
        for i, (cfg, warm) in enumerate(steps, 1):
            print(f"[{i}/{len(steps)}] {'warm-up ' if warm else ''}{key(cfg)}", flush=True)
            rec = bench(a.game, cfg, warm)
            if not rec:
                fails[key(cfg)] = fails.get(key(cfg), 0) + 1   # reported in the profile: crashes count against it
                continue
            print(f"    {rec['avg_fps']} fps (1% low {rec.get('low1_fps')})", flush=True)
            if not warm:
                scores.setdefault(key(cfg), []).append(rec["avg_fps"])
                if rec.get("low1_fps") is not None:
                    lows.setdefault(key(cfg), []).append(rec["low1_fps"])
    if not scores:
        sys.exit("error: no successful runs")
    default = key(steps[0][0])
    best, means = choose(scores, default, a.noise / 100)
    out = [f"# Generated by bench/tune.py on {time.strftime('%Y-%m-%d')} ({setup} Steam, {a.reps} runs each after a "
           f"warm-up, noise {a.noise}%).",
           "# Mean fps per configuration:"]
    for k, m in sorted(means.items(), key=lambda kv: -kv[1]):
        low = f", 1% low {statistics.mean(lows[k]):.1f}" if k in lows else ""
        failed = f", {fails[k]} failed" if k in fails else ""
        out.append(f"#   {k}: {m:.1f} ({len(scores[k])} runs{low}{failed}){'  <- chosen' if k == best else ''}")
    out += [f"#   {k}: no successful run ({n} failed)" for k, n in fails.items() if k not in means]
    out += best.split()
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "w").write("\n".join(out) + "\n")
    print("\n".join(out))
    apply(a.game, best)   # persist the winner's adapter settings (e.g. the graphics API)
    print(f"wrote {path} and applied it")


def selftest():
    k = parse_knobs("ROTTR_API=dx11,dx12")
    assert k == [("ROTTR_API", ["dx11", "dx12"])] and parse_knobs("") == []
    p = plan(k, 2)
    assert len(p) == 2 * (1 + 2 * len(SCHEDS)) and [w for _, w in p].count(True) == 2, p
    assert p[0] == ({"SCHED": "default", "ROTTR_API": "dx11"}, True) and p[5][0]["ROTTR_API"] == "dx12", p
    assert len(plan([], 3)) == 1 + 3 * len(SCHEDS)
    d, b = "SCHED=default", "SCHED=bpfland"
    assert choose({d: [100, 100], b: [101.5]}, d, 0.02)[0] == d          # within noise: keep the default
    assert choose({d: [100, 100], b: [103, 104]}, d, 0.02)[0] == b       # clear win
    assert choose({d: [], b: [90]}, d, 0.02)[0] == b                     # default failed every run
    assert choose({d: [100], b: [95]}, d, 0.02) == (d, {d: 100, b: 95})
    prof = "# Mean fps per configuration:\n#   SCHED=default ROTTR_API=dx12: 125.3 (2 runs)  <- chosen\n" \
           "#   SCHED=default ROTTR_API=dx11: 121.6 (2 runs, 1 failed)\nSCHED=default\nROTTR_API=dx12\n"
    assert chosen(prof) == ("SCHED=default ROTTR_API=dx12", 125.3)
    print("ok")


if __name__ == "__main__":
    selftest() if sys.argv[1:] == ["--selftest"] else main()
