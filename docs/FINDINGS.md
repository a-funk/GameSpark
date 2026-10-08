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

## The Witcher 3: a 10 Hz "am I online?" check

The Witcher 3 (4.x next-gen build, DirectX 12 only, VKD3D-Proton) on the FEX 2610 setup, measured at the player's
own save (Novigrad, Steam Cloud) with Geralt standing still for 60 s, 1080p, the game's auto-detected settings
(XeSS Auto, ray tracing unavailable), VSync off:

| Configuration | Avg fps | 1% low | Frames over 30 ms |
|---|---:|---:|---:|
| As shipped (two clean runs) | 55.2-63.0 | 17.4-19.6 | 567-571 |
| With `system/shim.sh` (one run on an otherwise idle GPU) | **88.1** | **63.2** | 0 |

Without the shim, most frames took about 11 ms (90 fps) but a 35 ms stall landed every ~105 ms, steady in time
rather than in frames: about 10 times a second. Over every run of the day (60 s each), including runs whose
averages are not comparable because another workload shared the GPU:

| Runs | Frames over 30 ms | ...of them 90-120 ms apart (the stall's cadence) |
|---|---:|---:|
| 8 without the shim | 565-601 | 430-557 |
| 8 with the shim (7 of them sharing the GPU) | 0-114 | 0-8 |

How it was traced:

1. **Not the measurement, the controller or Xalia.** The stalls stayed with MangoHud's CPU/GPU polling off
   (`cpu_stats=0,gpu_stats=0`, now the default for captures), with the DualSense's raw HID hidden
   (`PROTON_DISABLE_HIDRAW`), and with Proton's Xalia helper off (`PROTON_USE_XALIA=0`). (Those three runs
   overlapped another workload's LLM inference on the GPU, so their averages are not comparable; the stall cadence,
   which is what they tested, was the same.)
2. **perf** (`profile/profile.sh`): 17% of the game's CPU was a Wine service thread (`wine_sechost_service` in
   `winedevice.exe`, Wine's driver host), and 2,020 of its samples were in the kernel's `rtl8127_dump_tally_counter`
   (the Realtek NIC's hardware counters, on a port that is down), plus `dev_fetch_sw_netstats` and
   `__snmp6_fill_stats64`: the kernel gathering every interface's counters, which it does for each read of
   `/proc/net/dev` and each netlink link dump. That thread used about 12 s of CPU in the 30 s window, close to the
   10.5 s that 10 stalls/s x 35 ms add up to.
3. **Wine trace** (`WINEDEBUG=+iphlpapi,+nsi`): each `GetAdaptersAddresses` call from the game's `MainThread`
   made ~81 `ConvertInterfaceLuidToGuid` lookups (1,047,767 over 12,879 calls), one per interface Wine's
   `nsiproxy.sys` knew about, although the host had 11. nsiproxy (`dlls/nsiproxy.sys/ndis.c`, Wine master and
   Proton 10/11 alike) adds every interface it sees to its list and never removes one. Each enumeration of that list
   runs `if_nameindex()`, then for every known interface opens a socket, makes two ioctls, reads `/sys` and reads
   all of `/proc/net/dev`. Each enumeration therefore costs (known interfaces) x (host interfaces).
4. **Relay trace** (`WINEDEBUG=+relay`, `RelayInclude` set to one function at a time): the caller of
   `GetAdaptersAddresses` is Wine's own `wininet.dll`, and the caller of `wininet!InternetGetConnectedState` is
   `witcher3.exe` (offset 0x2546476) on its main thread. Wine's `InternetGetConnectedStateExW` has no cache: each call
   builds the full adapter list twice (once to size the buffer, once to fill it), about four interface enumerations.
5. **Where the ~81 came from.** Another workload started and removed 634 Docker containers on the host's `docker0`
   bridge today, most of them between 08:10 and 10:10 (up to 97 in ten minutes), the hours of these runs. Each
   container's network interface existed for about a second, long enough for the game's 10 Hz polling to add it to nsiproxy's
   list for good. `shim/igcs_cost.c` reproduces it outside the game. In a fresh prefix it measured once, polled at
   10 Hz like the game while 70 containers ran (`docker run --rm alpine true`), and measured again in the same
   session. Upstream Wine (WineHQ's 11.19 Ubuntu build, run under FEX) behaves the same as Proton:

   | Wine | Session | Adapters `GetAdaptersAddresses` returns | `InternetGetConnectedState` per call |
   |---|---|---:|---:|
   | Wine 11.19 | Fresh (11 host interfaces) | 11 | 5.0 ms |
   | Wine 11.19 | After 70 containers came and went | 115 | 39.8 ms |
   | Proton Experimental 11.0 | Fresh | 11 | 7.0 ms |
   | Proton Experimental 11.0 | After 70 containers came and went | 100 | 45.4 ms |

   At the end, all but 11 of the adapters no longer existed. A native read of `/proc/net/dev` takes 0.059 ms here
   (the Realtek driver's counter dump is most of it), so after the churn roughly half to two thirds of each call is
   kernel time and the rest is Wine's translated code. The game's frame times on a quiet host without the shim
   were not measured.

The fix caches the answer at the game's import of `InternetGetConnectedState`. `shim/shim.c` is a small x86
Windows DLL built with mingw-w64 on the Spark, loaded as a proxy for `powrprof.dll` (the game imports one function
from it, which Wine passes straight to `ntdll`, so the proxy forwards it there and never loads the real DLL). On
load it patches the import tables of the modules already loaded. No game or Proton file is modified; the shim is
one added file next to the executable, switched on by `WINEDLLOVERRIDES` in `profiles/launch/292030.env`, and Wine
falls back to its own `powrprof` if the file is missing.

The first version refreshed the cached answer on the game's own thread when it was 2 s old, which left one slow
frame (17-24 ms against 11 ms) every 2.1 s in the measured run. The shim now refreshes it on a background thread
every 2 s, so the game's thread never waits for Wine. `shim/shim_check.c` polls at 10 Hz for 7 s with the shim
loaded and fails if any call takes 1 ms or more. Under Wine 11.19 the slowest call was 8.6 ms with the first
version and 0.003 ms with the background refresh. In the game, at the same save, the 2.1 s cadence is gone: 87.3
fps, 1% low 63.8 (`results/witcher3/r04-shim-async.json`), with the few remaining slow frames in two bursts.

The underlying cost is in Wine: `InternetGetConnectedState` has no cache, each interface enumeration reads
`/proc/net/dev` once per known interface, and nsiproxy never drops interfaces that are gone. Any Linux host where
containers, VMs or VPNs come and go while a game polls this call accumulates entries. On x86 the translated part
would be faster; the kernel part would not (not measured). Wine does not accept LLM-generated code (its Developer
FAQ and Clean Room Guidelines), so this project reports the cause, a reproducer and the candidate fixes upstream
rather than a patch.

Not measured yet: XeSS vs DLSS and the scheduler for this game (`TUNE_KNOBS` in the adapter). Today's autotuner
sessions overlapped another workload's GPU use (now detected; such runs are discarded) and a Steam Cloud sync
failure (now cancelled without touching saves), so the tune needs a quiet window: `bench/tune.py witcher3`.
For play on the 60 Hz TV the adapter leaves VSync on: with the shim the game holds 60 with headroom.

## Frame times through FEX (MangoHud)

Games without a built-in benchmark (Divinity: Original Sin 2, The Witcher 3) need an external frame-time source.
MangoHud works, with two adjustments found with `VK_LOADER_DEBUG` in the Proton log:

- With FEX's Vulkan thunking the game's Vulkan calls run through the native arm64 loader, so the layer must be the
  arm64 build, and it must load inside Steam's container, which lacks its spdlog/fmt dependencies.
  `system/frametimes.sh` copies it with those libraries next to it.
- pressure-vessel sets `VK_IMPLICIT_LAYER_PATH` inside the container (to a directory that does not even exist
  there), which makes the loader ignore `VK_ADD_IMPLICIT_LAYER_PATH`. Setting `VK_IMPLICIT_LAYER_PATH` itself inside
  the container works; `tools/launch.sh` does that for `CONTAINER_` settings, which `bench/run.sh FRAMES=SECS` uses.

First capture: DOS2's main menu at 60.0 fps (1% low 58.3), the display-rate cap.

MangoHud's logging hotkey works inside the container too (it reads the X keyboard state), so adapters that reach
their scene by menu driving start the log themselves once the scene is on screen (`FRAMES_DELAY=key`,
`frames_start` in `lib/menu.sh`) instead of guessing a delay that would include loading screens.

## Controllers under Proton

- **DualSense pairing.** With the Bluetooth adapter set non-pairable, BlueZ pairs without storing a bond and then
  rejects the controller's input ("Rejected connection from !bonded device"): it connects but never shows up as an
  input device. `controller/pair.sh` makes the adapter pairable for the run and pairs with an agent.
- **DualSense in XInput-only games.** Proton hands DualSense pads to games as raw HID (hidraw), which older games
  that only read XInput ignore: in DOS2 player 2 could not press Start to join. `PROTON_DISABLE_HIDRAW=0x054c/0x0ce6`
  makes Wine's SDL backend present the pad as an XInput controller (Wine's `+hid` trace shows a `WINEXINPUT` device);
  it is in `profiles/launch/435150.env`. The value is matched in lowercase.

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

The GPU is shared too. During one Witcher 3 tuning session another workload on the Spark sent a local LLM server
(Ollama) a continuous stream of chat requests; a run in that window fell to 49 fps with the GPU 91% busy, where the
same configuration had measured 88 fps shortly before. `bench/run.sh` now records other GPU compute processes at
the start and end of each run (`other_gpu_apps` in the record, a warning on the console), and `bench/tune.py`
discards such runs. An idle model that is still loaded counts too, which is conservative; Ollama unloads models
after five idle minutes.
