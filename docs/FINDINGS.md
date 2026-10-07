# Findings

Measured on one DGX Spark (GB10, 128 GB, DGX OS / Ubuntu 24.04, kernel 6.17.0-1029-nvidia, NVIDIA 580.173.02,
Steam snap 1.0.0.85 with FEX 2603, Proton Experimental), 1920x1080 on a 60 Hz TV over HDMI, October 2026.
Run records are in [`results/`](../results); how they were measured is in [METHODOLOGY.md](METHODOLOGY.md).

## Hardware, measured

| | Spec | Measured on this unit |
|---|---|---|
| GPU memory bandwidth | 273 GB/s (LPDDR5X, shared with the CPU) | 208 GB/s read, 197 GB/s copy (CUDA probe, `tools/membw/bw.cu`) |
| FP32 throughput | not published | 27.7 TFLOPS (48 SMs, about 2.25 GHz sustained) |
| CPU | 10x Cortex-X925 (3.9 GHz) + 10x Cortex-A725 (2.8 GHz) | kernel capacity 997-1024 vs 718-731 |
| Graphics APIs | | Vulkan 1.4.312 and OpenGL 4.6 through the NVIDIA driver, direct rendering on Xorg |

The GPU has an RTX 5070's shader count with roughly an RTX 4060's memory bandwidth.

## Cyberpunk 2077 (DirectX 12 through VKD3D-Proton)

Built-in benchmark, 1080p, High preset with ray tracing off, unless noted. Run-to-run noise is about 2%.

| Run | Change | Avg fps | 1% low | GPU busy |
|---|---|---:|---:|---:|
| B0 | native, no upscaling | 49.0 | 25.1 | 64% |
| B1 | + DLSS Quality | 50.7 | 26.5 | 54% |
| E2 | B1 + game pinned to the X925 cores after launch | 58.6 | 29.8 | 62% |
| E4a | B1 + `scx_bpfland -m performance` (no pinning) | 57.5 | 32.4 | 62% |
| C1 | E4a again through `bench/run.sh`, cron burst held off | 59.3 | 34.5 | 62% |
| E9 | E4a + `WINE_CPU_TOPOLOGY` showing only the X925 cores | 55.1 | | |
| E8a | E4a + DLSS frame generation 2x | **100.4 shown** / 50.2 rendered | 58.0 shown | 73% |

What the numbers say:

1. **The game is CPU-bound, not GPU-bound.** The GPU sits around 60% busy, and DLSS upscaling cuts its work
   without raising fps (+3%).
2. **Core placement is the first real win.** By default the scheduler puts much of the game's work on the slower
   A725 cores. Steering it to the X925 cores gives +12-14%, whether by pinning or by `scx_bpfland`, which does it
   system-wide without per-game setup.
3. **Hiding cores hurts.** Showing the game only the 10 fast cores cut context switching sharply but lost 8%:
   the game's 19 job workers do real work.
4. **Frame generation doubles displayed fps** (100 fps) at a cost of about 7 rendered fps. The responsiveness is
   still that of ~50 fps, and a 60 Hz TV shows at most 60.

## Where the CPU time goes (profile p01, E4a configuration)

`profile/profile.sh` with `FEX_LIBRARYJITNAMING=1`; 265k samples over 45 s of the benchmark.

| Layer | Share of game CPU |
|---|---:|
| Game code, translated (inferred; Wine maps the .exe without a file label) | 63.4% |
| Kernel (mostly context switching: `finish_task_switch` 11.8%) | 22.7% |
| Wine / Proton | 4.8% |
| NVIDIA Vulkan driver, x86 build running under FEX | 3.5% |
| VKD3D-Proton | 3.4% |
| x86 system libraries | 1.4% |
| FEX runtime (JIT compiler, dispatcher) | 0.8% |

94% of the game's CPU time is in its `redDispatcher` job workers. Implications:

- Running NVIDIA's driver natively (FEX Vulkan thunking) can save at most ~7% here (driver + VKD3D). Worth doing,
  but not the main lever for this game.
- The main lever is the quality of FEX's translated code for the game itself: x86 memory-ordering (TSO)
  emulation, FEX version, code caching.
- Turning TSO emulation off (`FEX_TSOENABLED=0`, ceiling test only) makes Cyberpunk hang while loading, as
  expected for a heavily multithreaded engine, so that ceiling cannot be measured directly.

## Things that do not work yet

- **FEX Vulkan thunking inside Steam's container.** Setting `Vulkan: 1` has no effect for games: inside
  pressure-vessel the native arm64 `libvulkan.so.1` is not visible (the host copy is only reachable at
  `/var/lib/snapd/hostfs`), so FEX silently falls back to NVIDIA's x86 driver.
- **`scx_lavd`** panics on GB10 (`cpu_order.rs:433` unwrap on missing CPU cluster information, scx 1.1.2).
- **`preempt=full` at runtime**: Secure Boot puts the kernel in `lockdown=integrity`, which denies
  `/sys/kernel/debug/sched/preempt`. It needs the kernel command line and a reboot.
- **Kernel anti-cheat** games (EAC or BattlEye online modes, League of Legends) do not run under Proton.

## Background load matters

A cron job on the test machine re-verified 12,087 camera frames every 5 minutes, forking `bash`/`jq`/`sha256sum`
per frame for about 90 s. During a burst it took ~10% of all CPU samples, enough to cause periodic stutter and
to move benchmark averages by 3-4%. `bench/run.sh` can hold such jobs' lock files during a run (`QUIET_LOCKS`).
