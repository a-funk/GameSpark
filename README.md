# GameSpark

Make Steam games run better on the NVIDIA DGX Spark (GB10), and measure every change.

The Spark has a capable GPU (27.7 TFLOPS FP32 measured) on 208 GB/s of shared memory bandwidth, but its
CPU is ARM: every Windows game runs through three translators (FEX for x86 code, Proton/Wine for Windows,
DXVK or VKD3D-Proton for DirectX). This repo holds the tools to see where that costs time, the fixes that
measurably help, and the data.

**Status:** early. Tested on one Spark with Canonical's arm64 Steam snap and a system FEX. Results so far cover
Cyberpunk 2077 (DirectX 12), Rise of the Tomb Raider (DirectX 11 vs 12), Red Dead Redemption 2 (DirectX 12) and
The Witcher 3 (DirectX 12, measured at a player's save). STAR WARS: Galactic Racer (Denuvo) runs with a patched FEX.

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

The Witcher 3 (FEX 2610 setup, DX12, 1080p, auto-detected settings, Novigrad save, VSync off): **55-63 fps with a
35 ms stall ten times a second; 88.1 fps, 1% low 63.2, with `system/shim.sh`**, which caches one Win32 call the game
polls and Wine makes expensive ([details](docs/FINDINGS.md#the-witcher-3-a-10-hz-am-i-online-check)).

STAR WARS: Galactic Racer (Denuvo): stock FEX stops it 0.6 s in; **with `system/fex-patched.sh` it reaches the title
screen at 60 fps**. Denuvo needs two things FEX 2610 lacks: Proton must catch the game's direct Windows syscalls, and
x86 hardware breakpoints must fire ([details](docs/FINDINGS.md#star-wars-galactic-racer-what-denuvo-needs-from-fex)).

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
- **A cheap Win32 call can be the bottleneck.** The Witcher 3 asks "am I online?" ten times a second. Wine answers
  by re-reading every network interface it has ever seen, and keeps every short-lived Docker container's interface
  (~80 by then, 11 real), which took 35 ms. A 2 s cache in a tiny proxy DLL removes the stutter (55-63 to 88 fps
  average, 1% low 17-20 to 63).

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
system/console-mode.sh enable fex           # optional: boot into this Steam (needed for Xbox pads in Big Picture)
controller/pair.sh                          # optional: pair an Xbox or PS5 controller (see controller/README.md)
system/fex-patched.sh install               # needed for Denuvo games such as Galactic Racer: a patched FEX for the
                                            # games whose profiles/launch/<appid>.env sets FEX_BINARY=gamespark

# Once per game: launch through GameSpark's wrapper, which applies profiles/launch/<appid>.env (launcher skips,
# controller and DLSS fixes) and per-run settings, so they change without editing Steam's launch options again.
tools/steam-config.sh launch-options 1091500 "$PWD/tools/launch.sh %command%"

# Benchmark (Steam running, game installed):
QUIET_LOCKS=/path/to/cron.lock SHOT_AT=85 bench/run.sh cyberpunk2077 my-label

# Frame times for any game, including games without a built-in benchmark (MangoHud through FEX):
system/frametimes.sh install
FRAMES=60 bench/run.sh dos2 my-label        # 60 s of frame times; the record gets true 1% lows

# Win32 call cache for games whose profiles/launch/<appid>.env has a SHIM= line (builds with mingw-w64):
system/shim.sh install 292030               # The Witcher 3

# Per-layer CPU profile (FEX's JIT labels are switched on for the run through tools/launch.sh):
profile/profile.sh cyberpunk2077 my-label

# Autotune: benchmark each combination of a game's options, write its profile and apply it
bench/tune.py rottr --dry-run               # list the runs first (about 4 min each for this game)
bench/tune.py rottr                         # writes profiles/<snap|fex>/rottr.conf for the running Steam
bench/tune.py rottr --apply                 # re-apply after switching Steam setups (the game prefix is shared)
```

Run records land in `~/.local/share/gamespark/` (override with `SG_DATA`).

DLSS needs an x86-64 Proton (Experimental, 10 or 11), not the ARM64 Proton build; the NVAPI settings it needs are
in `profiles/launch/`.

## Layout

| Path | What |
|---|---|
| `bench/run.sh`, `bench/games/*.sh` | Benchmark runner and per-game adapters (launch args, where results land) |
| `bench/ingest.py` | Run record: avg and 1% low (rendered and displayed), telemetry for the benchmark window |
| `bench/telemetry.py` | 1 Hz GPU/CPU sampler |
| `bench/tune.py`, `profiles/` | Autotuner and the per-game, per-Steam-setup profiles it writes |
| `tools/launch.sh`, `profiles/launch/` | Steam launch wrapper and per-game launch settings (env, executable swap, args) |
| `lib/menu.sh`, `tests/menu-replay.sh` | OCR-gated menu steps for adapters, and their replay test on saved screenshots |
| `system/frametimes.sh` | Builds the arm64 MangoHud layer used by `bench/run.sh FRAMES=SECS` |
| `shim/`, `system/shim.sh` | Proxy DLL that caches Win32 calls Wine makes slow, its per-game installer, its check (`shim_check.c`), and a reproducer for the Wine cost (`igcs_cost.c`) |
| `profile/` | perf + FEX perf-map profiler and the layer classifier |
| `system/` | Per-game scheduler governor, system FEX setup, the patched FEX build (`fex-patched.sh`), console mode, global scheduler installer |
| `fex/patches/` | Local FEX patches (seccomp trap semantics, x86 hardware execute breakpoints) built by `system/fex-patched.sh` |
| `tools/` | Steam pipe helpers, launch-option editor, keyboard/mouse and virtual gamepad input, screenshots, GPU probe, and checks of how FEX handles what Denuvo relies on (`faultprobe.c`, `syscall_check.c`, `hwbp_check.c`) |
| `controller/` | Bluetooth pairing for Xbox and PlayStation controllers, the BlueZ settings and Steam udev rule they need, and a check for FEX's 32-bit evdev bug |
| `results/` | Run and profile records behind the numbers in this README |
| `docs/` | Findings and methodology |

## Known issues

- Games with kernel anti-cheat in online modes (EAC, BattlEye) do not run.
- Denuvo games need the patched FEX (`system/fex-patched.sh`): stock FEX 2603/2610 cannot run Denuvo's startup checks.
  Each new runtime can count as a new machine against Denuvo's activation limit, so keep one setup per game.
- Steam launch options are per account: GameSpark's wrapper only applies on the account they were set for.
- FEX Vulkan thunking does not reach games inside the Steam snap's container; `system/fex-system.sh` works
  around it with a second Steam under a system FEX. Run only one of the two Steams at a time.
- `scx_lavd` crashes on GB10; `system/scheduler.sh` uses `scx_bpfland`.
- Console mode turns on automatic login: anyone at the TV gets the desktop session.
- Screenshots can include Steam friend notifications; check before sharing.
- Steam's cloud sync for controller layouts (app 241100) can get stuck failing; every launch then shows "Unable to
  Sync". The runner cancels it (saves untouched); restarting Steam clears it.
- The 32-bit Steam client under FEX misreads controllers it reads through evdev: FEX hands it the 64-bit
  `input_event` layout. Steam reads Bluetooth Xbox pads through hidraw instead once `system/fex-system.sh controllers`
  installs `controller/60-gamespark-xbox-hidraw.rules`. The snap Steam cannot use hidraw, so use the FEX Steam for
  Big Picture. Wired Xbox pads have no hidraw node and stay affected. See docs/FINDINGS.md.

## License

MIT, see [LICENSE](LICENSE).
