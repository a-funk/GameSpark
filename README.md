# spark-gaming

Make Steam games run better on the NVIDIA DGX Spark (GB10), and measure every change.

The Spark has a capable GPU (27.7 TFLOPS FP32 measured) on 208 GB/s of shared memory bandwidth, but its
CPU is ARM: every Windows game runs through three translators (FEX for x86 code, Proton/Wine for Windows,
DXVK or VKD3D-Proton for DirectX). This repo holds the tools to see where that costs time, the fixes that
measurably help, and the data.

**Status:** early. Tested on one Spark with Canonical's arm64 Steam snap. Results so far are for
Cyberpunk 2077; Rise of the Tomb Raider (DirectX 11 vs 12) and Red Dead Redemption 2 (Vulkan vs DirectX 12)
are next.

## Results so far

Cyberpunk 2077 built-in benchmark, 1080p, High, ray tracing off ([details](docs/FINDINGS.md)):

| Setup | Avg fps | 1% low |
|---|---:|---:|
| Default | 49.0 | 25.1 |
| + DLSS Quality | 50.7 | 26.5 |
| + `scx_bpfland` scheduler (`system/scheduler.sh`) | 57.5-59.3 | 32.4-34.5 |
| + DLSS frame generation 2x | **100.4 shown** (50.2 rendered) | 58.0 shown |

What we learned:

- Games are **CPU-bound by translation**, not GPU-bound: the GPU sits ~60% busy and DLSS upscaling adds 3%.
- **Core placement** is the biggest system-wide win so far: steering game threads to the Cortex-X925 cores
  gives +12-14%.
- In Cyberpunk, **63% of the game's CPU time is its own translated code** and 23% is kernel context switching;
  NVIDIA's emulated driver plus VKD3D is only ~7%.

## Quick start

Requirements: DGX OS (Ubuntu 24.04 arm64), the Steam snap (`sudo snap install steam`) signed in, and either
passwordless sudo or membership in the `docker` group (scripts fall back to a privileged container for root).

```bash
git clone <this repo> ~/spark-gaming && cd ~/spark-gaming
make test                                   # offline checks

system/scheduler.sh install                 # scx_bpfland preferring the fast cores, persistent
system/console-mode.sh enable               # optional: log in and open Steam Big Picture at boot
controller/README.md                        # optional: Xbox controller over Bluetooth

# Benchmark (Steam running, game installed):
QUIET_LOCKS=/path/to/cron.lock SHOT_AT=85 bench/run.sh cyberpunk2077 my-label

# Per-layer CPU profile (needs FEX_LIBRARYJITNAMING=1 in the game's launch options):
tools/steam-config.sh launch-options 1091500 "FEX_LIBRARYJITNAMING=1 PROTON_ENABLE_NVAPI=1 %command%"
profile/profile.sh cyberpunk2077 my-label
```

Run records land in `~/.local/share/spark-gaming/` (override with `SG_DATA`).

For DLSS in Cyberpunk use the launch options `PROTON_ENABLE_NVAPI=1 PROTON_ENABLE_NGX_UPDATER=1 %command%`
and an x86-64 Proton (Experimental, 10 or 11), not the ARM64 Proton build.

## Layout

| Path | What |
|---|---|
| `bench/run.sh`, `bench/games/*.sh` | Benchmark runner and per-game adapters (launch args, where results land) |
| `bench/ingest.py` | Run record: avg and 1% low (rendered and displayed), telemetry for the benchmark window |
| `bench/telemetry.py` | 1 Hz GPU/CPU sampler |
| `profile/` | perf + FEX perf-map profiler and the layer classifier |
| `system/` | Scheduler installer, console mode |
| `tools/` | Steam pipe helpers, launch-option editor, screenshots, GPU bandwidth probe |
| `controller/` | Xbox controller Bluetooth fix and pairing script |
| `results/` | Run and profile records behind the numbers in this README |
| `docs/` | Findings and methodology |

## Known issues

- Games with kernel anti-cheat in online modes (EAC, BattlEye) do not run.
- FEX Vulkan thunking does not reach games inside Steam's container yet (see FINDINGS).
- `scx_lavd` crashes on GB10; `system/scheduler.sh` uses `scx_bpfland`.
- Console mode turns on automatic login: anyone at the TV gets the desktop session.
- Screenshots can include Steam friend notifications; check before sharing.
