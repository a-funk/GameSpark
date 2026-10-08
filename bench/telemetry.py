"""1 Hz GPU/CPU telemetry for benchmark runs. Usage: python3 -I bench/telemetry.py OUT.jsonl  (stop with SIGTERM).
Fields: gpu util %, power W, graphics clock MHz, temp C; CPU util % overall, on the fast cores (cpu_x925) and the rest (cpu_a725)."""
import json, signal, subprocess, sys, time

def fast_cpu_set():
    """CPUs whose kernel capacity is above the min/max midpoint (GB10: Cortex-X925 997-1024, Cortex-A725 718-731)."""
    import glob
    caps = {int(f.split("/")[5][3:]): int(open(f).read()) for f in glob.glob("/sys/devices/system/cpu/cpu[0-9]*/cpu_capacity")}
    if not caps:
        return set()
    lo, hi = min(caps.values()), max(caps.values())
    return {c for c, v in caps.items() if hi == lo or v > (lo + hi) / 2}


X925 = fast_cpu_set()
Q = "utilization.gpu,power.draw,clocks.gr,temperature.gpu"
running = True
signal.signal(signal.SIGTERM, lambda *_: globals().update(running=False))

def cpu_times():
    out = {}
    for line in open("/proc/stat"):
        if line.startswith("cpu") and line[3].isdigit():
            f = line.split(); v = list(map(int, f[1:9]))
            out[int(f[0][3:])] = (sum(v), v[3] + v[4])  # total, idle+iowait
    return out

def util(a, b, cpus):
    tot = sum(b[c][0] - a[c][0] for c in cpus); idle = sum(b[c][1] - a[c][1] for c in cpus)
    return round(100 * (tot - idle) / tot, 1) if tot else 0.0

def num(s):
    try: return float(s)
    except ValueError: return None

with open(sys.argv[1], "a") as out:
    prev, t0 = cpu_times(), time.time()
    while running:
        time.sleep(1)
        g = subprocess.run(["nvidia-smi", f"--query-gpu={Q}", "--format=csv,noheader,nounits"], capture_output=True, text=True).stdout.strip().split(", ")
        cur = cpu_times(); cpus = sorted(cur)
        rec = {"ts": round(time.time(), 1), "t": round(time.time() - t0, 1),
               "gpu": num(g[0]), "power": num(g[1]), "clock": num(g[2]), "temp": num(g[3]),
               "cpu": util(prev, cur, cpus), "cpu_x925": util(prev, cur, [c for c in cpus if c in X925]),
               "cpu_a725": util(prev, cur, [c for c in cpus if c not in X925])}
        out.write(json.dumps(rec) + "\n"); out.flush(); prev = cur
