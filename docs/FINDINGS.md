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

## System FEX 2610 with the native Vulkan driver

`system/fex-system.sh` installs FEX 2610 (armv8.4 build) with Vulkan/GL thunking and runs Valve's Steam launcher
under it, sharing the snap's Steam folder (`share-snap`), so game files, prefixes and settings are identical and
only FEX differs. Inside Steam's container this FEX does engage thunking: the game maps FEX's host thunks and
NVIDIA's native arm64 `libGLX_nvidia`/`libnvidia-glcore`.

| Setup (same settings) | Cyberpunk 2077 | Rise of the Tomb Raider DX12 | DX11 |
|---|---:|---:|---:|
| Snap, FEX 2603 (driver emulated) | 59.3 | 135.3 | 128.9 |
| FEX 2610, thunks off (driver emulated) | 62.3 | 125.0 | |
| FEX 2610 + native Vulkan driver | **69.2** (1% low 44.6) | 126.0 | 120.5 |

- **Cyberpunk: +17% over the snap**, split into +5% from FEX 2610 and +11% from the native driver; 1% lows
  +29%.
- **Tomb Raider: about 7% slower than the snap**, and thunking is neutral for it. The loss comes from FEX 2610 or
  its environment, not the driver. Copying the snap's FEX settings into the new config changed nothing (126.0).
- **Keep FEX 2610's default settings.** With the snap's settings (which turn off memory-ordering emulation for
  vector and memcpy accesses), 2 of 9 Tomb Raider DX12 runs crashed shortly after starting the benchmark: an
  access violation in `ROTTR.exe` and an invalid handle in `ntdll` (the game's crashpad minidumps). With the
  defaults that `system/fex-system.sh` writes, 0 of 7 DX12 runs and 0 of 15 tuning runs crashed. Suggestive,
  not proven (2/9 vs 0/7 is not statistically significant); the defaults cost nothing in speed.
- The first run after switching drivers rebuilds the driver's shader cache (111-118 fps); count the second.
- So the best setup is per game, like the scheduler. FEX can turn thunking off per executable (AppConfig), but
  the FEX version is per Steam install.

## Red Dead Redemption 2

On the FEX 2610 setup with NVIDIA's native driver, DX12 (VKD3D-Proton), 1080p, the game's Safe defaults (mostly
Low, Ultra textures), VSync off: **74.7-76.0 fps** over two runs (pass 4, the long scene the game reports; passes
0-3 run 72-126 fps). The GPU is about 50% busy, so like the other games it is limited by translated CPU work.

Getting there took five fixes, each now built into the adapter or documented in its header:

- **Rockstar launcher sign-in.** On the plain X11 desktop the sign-in window starts hidden in the tray (right-click >
  Open), then stays blank white: its Chromium draws through DXVK but nothing reaches the window, with or without FEX
  GL/Vulkan thunking. Inside a Wine virtual desktop (prefix registry `Software\Wine\Explorer`) it renders.
- **Launcher stalls.** About half of launches stall at sign-in with no window; a fresh launch clears it, so the
  runner retries launches (`LAUNCH_RETRIES`, `game_abort`).
- **Software rendering.** `system/fex-system.sh` installs Mesa's Vulkan drivers, so the host loader also lists
  llvmpipe. DXVK and VKD3D skip software devices; RDR2 does not, and its Safe config picked it (7.9 fps, GPU at 3%).
  `VK_LOADER_DRIVERS_SELECT=*nvidia*` hides the other drivers; `lib/env.sh` sets it for every game the FEX Steam
  starts.
- **NVAPI must stay on.** With `PROTON_DISABLE_NVAPI=1` the game sees an NVIDIA GPU, then polls for
  `nvapi64.dll` forever (about 1,400 lookups a second, each a full scan of `system32`; found with perf and strace).
- **Vulkan crashes.** RDR2's own Vulkan renderer on the GB10 through FEX's Vulkan thunking crashes during init
  (access violation in `RDR2.exe`); with NVAPI hidden it hangs instead. It ran only on llvmpipe. DX12 works, so the
  Vulkan vs DX12 comparison is blocked on this, not yet measured.

## The scheduler is a per-game choice

| Game | Default scheduler | `scx_bpfland -m performance` | Effect |
|---|---:|---:|---:|
| Cyberpunk 2077 (19 job workers) | 53.9 | 59.3 | +10% |
| Cyberpunk 2077 on FEX 2610 + native driver (autotuner, 2 runs each) | 68.2 | 68.3 | 0% |
| Rise of the Tomb Raider DX12 on FEX 2610 (autotuner) | 125.3 | 115.2 | -8% |
| Rise of the Tomb Raider DX11 on FEX 2610 (autotuner) | 121.6 | 117.1 | -4% |
| Rise of the Tomb Raider DX12 (one dominant thread) | 135.3 | 131.1 | -3% |
| Rise of the Tomb Raider DX11 | 128.9 | 125.4 | -3% |

Games that spread work across many threads gain from keeping them on the fast cores; games limited by one
main thread lose a little. `system/scheduler.sh` therefore stays opt-in, and the scheduler is a per-game
setting for the autotuner to choose.

The gain also depends on the Steam setup. With FEX 2610 and the native driver, Cyberpunk gains nothing from
the scheduler. Measured fact: 0% vs +10% on the snap; Tomb Raider loses more there (-8% on DX12). Untested hypothesis: with less translated driver work
per frame, the job workers no longer saturate the fast cores, so where they run matters less. Profiles are
therefore kept per setup (`profiles/snap/`, `profiles/fex/`), and the governor reads the running Steam's set.

## Things that do not work yet

- **FEX Vulkan thunking inside the Steam snap's container** (solved by the system FEX setup above). It works outside the container: x86
  `vulkaninfo` under the snap's FEX with `Vulkan: 1` reports the host's arm64 Mesa (LLVM 20.1.2, 128-bit)
  instead of the x86 image's (LLVM 20.1.8, 256-bit). Inside pressure-vessel it does not engage:
  - the game maps the x86 `libvulkan.so.1.4.309` and FEX logs no thunk activity at all;
  - the container's arm64 side holds only FEX's own five libraries; the host's `libvulkan.so.1` and NVIDIA's
    arm64 driver (which also needs arm64 `libX11`/`libXext`) are only under `/var/lib/snapd/hostfs`;
  - pressure-vessel rewrites `LD_LIBRARY_PATH`, so adding that directory from the launch options is dropped;
  - `FEX_HOSTENV=VK_DRIVER_FILES=...` reaches the x86 loader too and breaks instance creation.

  Worth fixing for DX11 games (DXVK + emulated driver + Wine are over half their CPU), less for DX12. Options:
  a system FEX (PPA 2607+) with its own RootFS, which a public GB10 setup reports thunking games with; or a
  steam-snap change so pressure-vessel imports the host's arm64 graphics stack for FEX.
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
