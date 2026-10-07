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
| D1, D2 | E4a settings, default scheduler, cron burst held off | 53.7, 54.1 | 27.2, 31.0 | 56% |
| E9 | E4a + `WINE_CPU_TOPOLOGY` showing only the X925 cores | 55.1 | | |
| E8a | E4a + DLSS frame generation 2x | **100.4 shown** / 50.2 rendered | 58.0 shown | 73% |

What the numbers say:

1. **The game is CPU-bound, not GPU-bound.** The GPU sits around 60% busy, and DLSS upscaling cuts its work
   without raising fps (+3%).
2. **Core placement is the first real win for this game.** By default the scheduler puts much of the game's work
   on the slower A725 cores. Steering it to the X925 cores gives +10% measured cleanly (59.3 vs 53.9 fps with
   `scx_bpfland`; manual pinning is similar). The earlier B1/E1 baselines overlapped a cron burst, which
   overstated the gain as +12-14%. It is not a universal win: see the scheduler section below.
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

## Rise of the Tomb Raider: DirectX 11 (DXVK) vs DirectX 12 (VKD3D-Proton)

Windows build under Proton Experimental, built-in benchmark (three scenes), 1080p, default settings with VSync
off, `scx_bpfland` active, warm shader caches. The results screen is read with OCR (no results file exists).

| API path | Runs (overall fps) | Mean | Mountain Peak | Syria | Geothermal Valley |
|---|---|---:|---:|---:|---:|
| DX11 via DXVK | 125.7, 125.1, 125.3 | 125.4 | 199.3 | 92.1 | 80.4 |
| DX12 via VKD3D-Proton | 131.1, 131.1, 131.2 | **131.1** | 193.4 | 94.4 | 99.7 |

Per-layer CPU profiles of the same runs:

| | DX11 | DX12 |
|---|---:|---:|
| Game's share of all machine CPU samples | 38.4% | 17.5% |
| Game code (translated) | 39.1% | 66.9% |
| Translation layer (DXVK / VKD3D) | **36.7%** | **5.0%** |
| Wine / Proton | 8.8% | 7.3% |
| NVIDIA driver, x86 build under FEX | 8.1% | 8.0% |
| Kernel | 5.5% | 10.7% |

- **DX12 is the thinner translation.** It maps closely onto Vulkan, so VKD3D costs 5% of the game's CPU. DX11
  needs DXVK's state tracking on its command-stream thread (`dxvk-cs`, 26.6% of game CPU), and the DX11 path
  uses twice the CPU for 4.5% fewer frames. Prefer DX12 when a game offers both.
- **For DX11 games the translation stack is over half of the game's CPU** (DXVK + emulated NVIDIA driver +
  Wine). Running those natively (Vulkan thunking, ARM64EC builds) is worth far more for DX11 titles than for
  Cyberpunk.
- **The first run after switching APIs compiles pipelines mid-benchmark:** the first DX12 run scored 102.7 fps
  with a 1.27 fps minimum in Syria. Discard warm-up runs.
- The very first DX11 run (game's first launch) scored 83.1; Steam pre-compiles Vulkan shaders for this game
  before first launch, but the game's own caches still warm up on the first run.

## The scheduler is a per-game choice

| Game | Default scheduler | `scx_bpfland -m performance` | Effect |
|---|---:|---:|---:|
| Cyberpunk 2077 (19 job workers) | 53.9 | 59.3 | +10% |
| Rise of the Tomb Raider DX12 (one dominant thread) | 135.3 | 131.1 | -3% |
| Rise of the Tomb Raider DX11 | 128.9 | 125.4 | -3% |

Games that spread work across many threads gain from keeping them on the fast cores; games limited by one
main thread lose a little. `system/scheduler.sh` therefore stays opt-in, and the scheduler is a per-game
setting for the autotuner to choose.

## Things that do not work yet

- **FEX Vulkan thunking inside Steam's container.** Setting `Vulkan: 1` has no effect for games: inside
  pressure-vessel the native arm64 `libvulkan.so.1` is not visible (the host copy is only reachable at
  `/var/lib/snapd/hostfs`), so FEX silently falls back to NVIDIA's x86 driver.
- **`scx_lavd`** panics on GB10 (`cpu_order.rs:433` unwrap on missing CPU cluster information, scx 1.1.2).
- **`preempt=full` at runtime**: Secure Boot puts the kernel in `lockdown=integrity`, which denies
  `/sys/kernel/debug/sched/preempt`. It needs the kernel command line and a reboot.
- **Occasional startup crash:** one Cyberpunk launch crashed 5 s into loading (`CrashInfo.json`, not OOM);
  the next two launches with identical settings ran normally. The runner reports it as a failed run.
- **Kernel anti-cheat** games (EAC or BattlEye online modes, League of Legends) do not run under Proton.

## Background load matters

A cron job on the test machine re-verified 12,087 camera frames every 5 minutes, forking `bash`/`jq`/`sha256sum`
per frame for about 90 s. During a burst it took ~10% of all CPU samples, enough to cause periodic stutter and
to move benchmark averages by 3-4%. `bench/run.sh` can hold such jobs' lock files during a run (`QUIET_LOCKS`).
