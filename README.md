# GameSpark

Make Steam games run better on the NVIDIA DGX Spark (GB10), and measure every change.

The Spark has a capable GPU (27.7 TFLOPS FP32 measured) on 208 GB/s of shared memory bandwidth, but its
CPU is ARM: every Windows game runs through three translators (FEX for x86 code, Proton/Wine for Windows,
DXVK or VKD3D-Proton for DirectX). This repo holds the tools to see where that costs time, the fixes that
measurably help, and the data.

**Status:** early. Tested on one Spark with Canonical's arm64 Steam snap. Results so far cover
Cyberpunk 2077 (DirectX 12) and Rise of the Tomb Raider (DirectX 11 vs 12); Red Dead Redemption 2
(Vulkan vs DirectX 12) is next.

## Results so far

Cyberpunk 2077 built-in benchmark, 1080p, High, ray tracing off ([details](docs/FINDINGS.md)):

| Setup | Avg fps | 1% low |
|---|---:|---:|
| Default | 49.0 | 25.1 |
| + DLSS Quality | 50.7 | 26.5 |
| + `scx_bpfland` scheduler (`system/scheduler.sh`) | 59.3 (vs 53.9 default, clean) | 34.5 |
| + DLSS frame generation 2x | **100.4 shown** (50.2 rendered) | 58.0 shown |
| System FEX 2610 + native Vulkan driver (`system/fex-system.sh`), no frame gen | **69.2** | 44.6 |

Red Dead Redemption 2 (FEX 2610 setup, DX12, 1080p, the game's Safe defaults, VSync off): **74.7-76.0 fps**.

What we learned:

- Games are **CPU-bound by translation**, not GPU-bound: the GPU sits ~60% busy and DLSS upscaling adds 3%.
- **Core placement** helps games that spread work over many threads (+10% in Cyberpunk) and costs a little in
  games limited by one main thread (-3% in Rise of the Tomb Raider), so the scheduler is a per-game choice.
- **DirectX 12 translates more cheaply than DirectX 11**: in Rise of the Tomb Raider, VKD3D costs 5% of the
  game's CPU vs 37% for DXVK, and DX12 runs 4.5% faster with half the CPU.
- **Running NVIDIA's Vulkan driver natively** (FEX 2610 thunking, via a system FEX next to the snap) is +11% in
  Cyberpunk on top of +5% from the newer FEX; neutral in Tomb Raider, where FEX 2610 itself is 7% slower.
- In Cyberpunk, **63% of the game's CPU time is its own translated code** and 23% is kernel context switching;
  NVIDIA's emulated driver plus VKD3D is only ~7%.

## Quick start

Requirements: DGX OS (Ubuntu 24.04 arm64), the Steam snap (`sudo snap install steam`) signed in, and either
passwordless sudo or membership in the `docker` group (scripts fall back to a privileged container for root).

```bash
git clone <this repo> ~/gamespark && cd ~/gamespark
make test                                   # offline checks

system/governor.sh install                  # per-game scheduler from profiles/ (scx_bpfland only where it helps)
system/console-mode.sh enable               # optional: log in and open Steam Big Picture at boot

# Optional: system FEX 2610 with NVIDIA's native Vulkan driver, as a second Steam on the same library
# (Cyberpunk +17%, Tomb Raider -7%; see docs/FINDINGS.md). Close Steam first.
system/fex-system.sh install && system/fex-system.sh share-snap
GAMESPARK_STEAM=fex tools/steam-console.sh  # other commands detect which Steam is running
system/console-mode.sh enable fex           # optional: boot into this Steam instead of the snap
controller/README.md                        # optional: Xbox controller over Bluetooth

# Benchmark (Steam running, game installed):
QUIET_LOCKS=/path/to/cron.lock SHOT_AT=85 bench/run.sh cyberpunk2077 my-label

# Per-layer CPU profile (needs FEX_LIBRARYJITNAMING=1 in the game's launch options):
tools/steam-config.sh launch-options 1091500 "FEX_LIBRARYJITNAMING=1 PROTON_ENABLE_NVAPI=1 %command%"
profile/profile.sh cyberpunk2077 my-label

# Autotune: benchmark each combination of a game's options, write its profile and apply it
bench/tune.py rottr --dry-run               # list the runs first (about 4 min each for this game)
bench/tune.py rottr                         # writes profiles/<snap|fex>/rottr.conf for the running Steam
bench/tune.py rottr --apply                 # re-apply after switching Steam setups (the game prefix is shared)
```

Run records land in `~/.local/share/gamespark/` (override with `SG_DATA`).

For DLSS in Cyberpunk use the launch options `PROTON_ENABLE_NVAPI=1 PROTON_ENABLE_NGX_UPDATER=1 %command%`
and an x86-64 Proton (Experimental, 10 or 11), not the ARM64 Proton build.

## Layout

| Path | What |
|---|---|
| `bench/run.sh`, `bench/games/*.sh` | Benchmark runner and per-game adapters (launch args, where results land) |
| `bench/ingest.py` | Run record: avg and 1% low (rendered and displayed), telemetry for the benchmark window |
| `bench/telemetry.py` | 1 Hz GPU/CPU sampler |
| `bench/tune.py`, `profiles/` | Autotuner and the per-game, per-Steam-setup profiles it writes |
| `profile/` | perf + FEX perf-map profiler and the layer classifier |
| `system/` | Per-game scheduler governor, system FEX setup, console mode, global scheduler installer |
| `tools/` | Steam pipe helpers, launch-option editor, screenshots, GPU bandwidth probe |
| `controller/` | Xbox controller Bluetooth fix and pairing script |
| `results/` | Run and profile records behind the numbers in this README |
| `docs/` | Findings and methodology |

## Known issues

- Games with kernel anti-cheat in online modes (EAC, BattlEye) do not run.
- FEX Vulkan thunking does not reach games inside the Steam snap's container; `system/fex-system.sh` works
  around it with a second Steam under a system FEX. Run only one of the two Steams at a time.
- `scx_lavd` crashes on GB10; `system/scheduler.sh` uses `scx_bpfland`.
- Console mode turns on automatic login: anyone at the TV gets the desktop session.
- Screenshots can include Steam friend notifications; check before sharing.

## License

MIT, see [LICENSE](LICENSE).
