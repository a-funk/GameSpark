# Findings

Measured on one DGX Spark (GB10, 128 GB, DGX OS / Ubuntu 24.04, kernel 6.17.0-1029-nvidia, NVIDIA 580.173.02,
Steam snap 1.0.0.85 with FEX 2603, Proton Experimental), 1920x1080 on a 60 Hz TV over HDMI, October 2026. Since
2026-10-19 14:31 the Spark runs kernel 7.0.0-1019-nvidia with NVIDIA 615.71.09
([why](#star-wars-galactic-racer-nanite-on-after-a-driver-change-2026-10-19)).
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
rather than a patch: [Wine bug 60465](https://bugs.winehq.org/show_bug.cgi?id=60465).

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

- **Steam Input's virtual pads are dead.** With Steam Input active for a game, Steam hands it a virtual Xbox pad
  (uinput, `28de:11ff`) and Proton hides the real controller (Steam lists it in `SDL_GAMECONTROLLER_IGNORE_DEVICES`
  and maps virtual pads to real ones in `SteamVirtualGamepadInfo`). Here those virtual pads gave Street Fighter 6 no
  input, and the one Steam made from GameSpark's uinput Xbox pad sent no event while that pad sent D-pad and A presses.
  The 32-bit Steam client writes them through FEX, likely with the same `input_event` layout mismatch as its evdev
  reads (next section). A game the developer opts into Steam Input for every controller type ("Opted-in Controller Mask
  for AppId N: ffff" in Steam's `logs/controller.txt`) needs a profile that shows the real pad and hides the virtual
  ones, as Street Fighter 6's does.

## The Xbox controller in Big Picture: 32-bit Steam misreads evdev under FEX

An Xbox Series controller over Bluetooth worked in games but not in Steam Big Picture: left and right did nothing
and scrolling was erratic. A DualSense worked everywhere. How it was traced:

1. **Controller and kernel are fine.** Raw Bluetooth reports (hidraw) and evdev events both showed every stick at
   full range (0-65535), the D-pad and the buttons.
2. **Steam read the Xbox pad through evdev** (`path: sdl://N`, `Interface: -1` in `logs/controller.txt`). Its
   hidraw node was root-only: Valve's `60-steam-input.rules` grants hidraw only for the Elite 2 over Bluetooth. The
   DualSense's hidraw is granted, and Steam held it.
3. **Reproduced without hands.** A uinput twin of the pad (same name, IDs, axes and ranges) was registered by
   Steam, which loaded the Big Picture layout (`controller_base/basicui_gamepad.vdf`). No stick, D-pad or button
   moved Big Picture's interface, under both the FEX 2610 and the snap Steam, while the keyboard did.
4. **Cause.** The Steam client (`ubuntu12_32/steam`) is a 32-bit x86 program. On a 32-bit task Linux returns
   `struct input_event` in its 16-byte 32-bit form, but FEX runs 32-bit x86 code inside a 64-bit ARM process,
   so the kernel returns the 24-byte form. FEX's 32-bit syscall layer converts input ioctls but not `read()`.
   `controller/evdev32_check.py` runs a 40-byte `read()` from a static 32-bit x86 program under FEX 2610. It gets
   one 24-byte D-pad event (type 3, code 16, value 1), which a 32-bit program decodes as type 2221, code 12. Every
   evdev event is misread. Games are unaffected because 64-bit Wine reads the pad itself.
5. **Why the DualSense works.** Steam reads it as raw HID, which is a byte stream with no such layout. The snap
   Steam's sandbox has no hidraw access, so the snap reads both pads through evdev (it held `event7` and `event8`
   and no hidraw node); the DualSense in the snap's Big Picture was not tested.

Fix: `controller/60-gamespark-xbox-hidraw.rules` grants the desktop user hidraw access to Xbox controllers over
Bluetooth, installed by `system/fex-system.sh controllers` (and `install`). The FEX Steam then holds `hidraw0` and
no evdev node, as for the DualSense. A uhid twin built from the real controller's report descriptor showed it
working: the D-pad moved the selection right, down, up and back left. The snap Steam cannot use the rule, so
console mode boots the FEX Steam (`system/console-mode.sh enable fex`). Wired Xbox pads (kernel `xpad`, no hidraw)
still go through evdev and would show the same problem in the FEX Steam (not tested). The proper fix is in FEX:
converting `input_event` on reads (and on uinput writes) for 32-bit guests. When `controller/evdev32_check.py`
starts exiting 0, the rule is no longer needed.

## STAR WARS: Galactic Racer: what Denuvo needs from FEX

The game (Unreal Engine 5, DirectX 12, released 2026-10-06, Denuvo Anti-Tamper with a 5-machine activation limit) runs
on the Spark with GameSpark's patched FEX. On its first launch through Steam it reached the title screen at a steady
60 fps (vsync). With stock FEX (2610 or the snap's 2603) it exits about 0.6 s after the game process starts, inside
Denuvo's startup checks, before Unreal writes a log.

**How it was found.** A standalone repro runs the game exe under Wine and FEX without Steam (so Denuvo cannot
activate) and logs exceptions. Under stock FEX, Denuvo's vectored handler sees about 2,800 deliberate faults and
then a read through a pointer exactly 2^32 below a valid address (`0xFFFFFFFF2F12FD84` at `0x1535129EB`), and the
process dies of a stack overflow. Box64, an independent x86 emulator, failed the same way, which ruled out a
FEX-specific instruction bug. With two additions Box64 passed, and both additions are FEX features this game needs:

1. **Direct Windows syscalls.** The x86 reference log (Proton issue #10228) shows about 910 raw `syscall`
   instructions from the game's own code in its first 0.6 s. Proton's Wine traps them with a seccomp filter.
   - FEX 2610 emulates seccomp only with `NeedsSeccomp=1`, which is off by default, so Wine's filter install fails
     with `EINVAL`. The syscalls then run as Linux syscalls: in `tools/syscall_check.c` a copied `NtClose` stub
     (number `0xf`) runs Linux `rt_sigreturn` and crashes.
   - The Linux return values are 64-bit `-errno`, where Windows returns 32-bit NTSTATUS. That is the likely source
     of the upper half full of ones.
   - With `NeedsSeccomp=1` the call is trapped, but FEX also executed it, and its SIGSYS reported RIP at the
     `syscall` instruction instead of after it. Wine returns to `RIP + 0xb`, so it landed 2 bytes early and looped.
   - Fix: `fex/patches/0001`. Like Linux, it skips the syscall, keeps RAX = syscall number and raises SIGSYS on the
     way back to the guest, with the RIP after the instruction. The signal is queued as deferred and delivered by
     the dispatcher's syscall stub, after FEX's syscall handler has returned (see the next paragraph for why).
2. **Hardware execute breakpoints.**
   - What Denuvo does: on every thread it arms DR3 with `NtSetContextThread` (`dr3=0x14d2b84d0, dr7=0x40`) and
     expects `EXCEPTION_SINGLE_STEP` when that address runs.
   - What FEX did: wineserver sets debug registers with `ptrace(PTRACE_POKEUSER)`, FEX answered `EPERM`
     (`set_thread_context() = ACCESS_DENIED`), and nothing fired.
   - The fix, `fex/patches/0002`, carries the debug registers from wineserver to the game thread through a small
     per-thread shared-memory mailbox. It makes every armed address the start of its own compiled block, where the
     JIT checks the current thread's DR0-3 and raises a guest `#DB` (trap 1, `TRAP_HWBKPT`, DR6 set).
     `tools/hwbp_check.c` passes with it: SetThreadContext succeeds, exactly one single-step at the right address,
     `Dr6=0xffff0ff1`.

**Verification.**
- **Standalone:** 2,846 exceptions and the stack overflow became 49 exceptions (2 of them the expected
  single-steps), and the game loaded `steam_api64.dll` and asked Steam to relaunch it.
- **Through Steam:** 165 single-steps (one per thread), about 117,000 direct syscalls handled by Wine, then
  VKD3D-Proton, DXVK, NVAPI, DLSS and EOS loaded, and the title screen showed.

**A crash a few minutes in, from the first version of patch 0001.** That version delivered the SIGSYS from inside
FEX's syscall handler. Wine's SIGSYS handler always redirects the thread into its syscall dispatcher, and when a guest
handler changes RIP, FEX resumes at the top of its dispatcher on the host stack it was interrupted on (FEX's own
comment calls this "only safe inside the JIT"). The handler's frames and FEX's saved context, about 750 bytes, stayed
on the stack for every trapped syscall.
- In the game: both real runs closed after 4.5 and 10 minutes, with no crash report and no Windows exception. In
  both, the last thing logged was one Denuvo check thread (one of ~300, each about 1,000 trapped syscalls) that scans
  memory with `NtQueryVirtualMemory` and had reached about 11,400 trapped syscalls. Threads that survived made at
  most about 9,100.
- In isolation: a thread making direct syscalls stopped between 11,000 and 11,500 calls, with its 8 MB FEX host
  stack (`[anon:FEXMem_Misc]`) fully resident.
- With the deferred delivery, 200,000 trapped syscalls on one thread complete; `tools/syscall_check.c` now repeats
  30,000 on a new thread.

**Ruled out along the way** (each still failed the same way): reporting non-canonical faults as #GP like x86 does;
FEX's `SMCChecks=full`, `HideHypervisorBit` and other codegen options; FEX 2603 and FEX `main` (identical to 2610).
ARM64 Top Byte Ignore (a tagged non-canonical pointer reads without faulting) and FEX's segment selectors (CS=0x30)
also differ from x86, but Box64 passed despite them.

**Other FEX bugs found while testing**, not needed for this game:
- `cmpxchg r32, r32` with a register destination does not zero-extend it on the not-equal path;
- 32-bit-address `loop` leaves the upper half of RCX (a 2610 regression);
- 32-bit-address `movsb`/`stosb` crash;
- a faulting split-lock atomic kills the FEX process with SIGBUS.

**How it is set up.** `system/fex-patched.sh install` builds the system FEX's release with `fex/patches` and installs
it for the user next to the packaged FEX (never over it). It also adds an AppArmor rule so Steam's container can use
user namespaces under it. `profiles/launch/4078430.env` sets `FEX_BINARY=gamespark`, `FEX_NEEDSSECCOMP=1` and
`FEX_GSHWBP=1`. `tools/launch.sh` then starts only this game's process tree under the patched FEX; Steam stays on the
packaged one. FEX does not accept AI-written code (its `CONTRIBUTING.md`), so the patches stay local, and the findings
go upstream as a written report.

**Pitfalls met on the way.**
- Steam's launch options are stored per account: after the TV's Steam was switched to another household account,
  the game launched without GameSpark's wrapper.
- Steam re-asked for the EULA after the 2026-10-08 hotfix.
- Until "Don't ask again" is chosen, Steam's launch-option chooser (Play / Reinstall Epic Online Services) silently
  swallows launches sent through the Steam pipe.
- A standalone run that gets past Denuvo calls `steam.exe steam://run/4078430`; with a reachable Steam that would be
  a real launch and a Denuvo activation.

## STAR WARS: Galactic Racer: flash frames, hitches and audio

Playable since 2026-10-10 with no flicker: medium preset, ray tracing off, DLSS Super Resolution Performance and
Reflex on (in-game), plus three things from `profiles/launch/4078430.*`: Nanite off, the game on the 10 fast cores
from launch, and more audio buffering. Racing at 1080p (one race each, different tracks):

| Setup | Avg fps | Median frame | 99th pct frame | Flicker |
|---|---:|---:|---:|---|
| Medium, Nanite on, pinned to the X925 cores after launch | 75.6 | 12.7 ms | 24.7 ms | reduced; hitch about once a second |
| + `PROTON_CPU_TOPOLOGY` (fast cores from launch) | 102.5 | 9.5 ms | 15.1 ms | flash frames throughout |
| + `r.Nanite=0` (the profile) | 83.4 | 10.9 ms | 22.6 ms | none |

**Nanite off crashes Jakku's roguelike maps (2026-10-11).** With the profile's Engine.ini (`r.Nanite=0`,
`r.AllowOcclusionQueries=0`), every load of `L_Mastiff_LOOP_A`, a Jakku map in the roguelike mode, crashed about 1 s
after the map loaded: 4 of 4. `r.Nanite=0` alone is enough: without the occlusion-query line, `L_Mastiff_P2P_A` crashed
the same way.
- **The crash:** an access violation reading address 0x8 on "RenderThread 0" at `SWGR-Win64-Shipping.exe+0x827114`.
  The game's sentry-native minidumps recorded it; Unreal's own crash reporter wrote nothing.
- **The instruction:** `mov ebp, [r12+8]`, with r12 loaded from `[[this+0x258]+0x48]`, a null two pointers deep. It
  sits in the exe's main code section: Denuvo renamed that `.rsrc`, and its own VM is the 298 MB writable `.debug`.
- **Without the Engine.ini** (Nanite on), the same load passed and the run went on, but the flash frames came back.
- **Ruled out:** frame generation was still on in every run, because the in-game switch had not been saved, and
  vkd3d-proton logged no error before the crash (`PROTON_LOG=1`). The game files verified clean.
- **Why**, from the SparkHome session's reading of the exe:
  - **The crashing function** is Unreal's `FStaticMeshSceneProxy::CreateDynamicRayTracingGeometries`. It reads the
    mesh's render data (`+0x258`), then that data's ray-tracing proxy (`+0x48`), which is null. The call path is
    `CreateRenderThreadResources` from `FScene::BatchAddPrimitives`, the same in all four dumps.
  - **Why Nanite off:** with Nanite off, spline meshes get the non-Nanite `FSplineMeshSceneProxy`. It always asks for
    dynamic ray-tracing geometry, where the base proxy asks only when a ray-tracing proxy exists. Some spline meshes on
    the Mastiff maps have none. With Nanite on, as on Windows, they get `FNaniteSplineMeshSceneProxy` instead.
  - **Why ray tracing runs at all:** it is off in the game's menu, but vkd3d-proton reports DXR, and the game's code
    turns it on at every map load (2026-10-14, below).
- **Fix:** `VKD3D_CONFIG=nodxr` in `profiles/launch/4078430.env` hides DXR, so ray tracing stays off. Confirmed on
  2026-10-11 with Nanite still off: the Mastiff maps loaded, and there were no flash frames. Its effect on frame rate is
  not measured yet.
- **Replaced on 2026-10-13** by `r.RayTracing.Geometry.SplineMeshes=0` (and `r.RayTracing.Enable=0`) in the Engine.ini,
  because hiding DXR also switched off the game's lighting ("Galactic Racer: lighting", below). The Arcade time trial
  "Landspeeder Ace" is `L_Mastiff_LOOP_A`: about 20 launches with DXR visible and that line loaded it without a crash.
  **That was wrong:** neither line can prevent the crash, and the campaign crashed with them (2026-10-14, below). Arcade
  passed because its route lacks the meshes. `VKD3D_CONFIG=nodxr` is back.

**GPU hangs with dynamic frame generation (2026-10-11).** After 63 minutes on the fixed profile, the game froze: the
driver logged `Xid 109 ... CTX SWITCH TIMEOUT` on the game thread's channel, nothing reported a lost device, and the
game stayed frozen until it was closed. The two barrier test runs (below, under the next tests) ended the same way.
These three are the only Xid 109 lines in the Spark's kernel log, which goes back to 2025-10-02; about 15 hours of
earlier play had none. The cause is not established.
- **What came before:** the game runs DLSS frame generation in dynamic mode (`sl::DLSSGMode::eDynamic`), which keeps
  switching between off and 1 to 5 generated frames: 764 switches in the hour before the freeze. The stall began 0.13 s
  after a switch to 5 generated frames, which followed a frame slower than 100 ms. The one warning seen before this
  hang and in no other log that night, "Worker thread 'sl.dlssg' timed out", came 9.5 s before it.
- **But switching is routine:** 890 of that night's 925 switches had no hang within 30 s, and Xid 109 also hits other
  vkd3d-proton games on the same driver (580.173.02) with frame generation off
  ([vkd3d-proton #3165](https://github.com/HansKristian-Work/vkd3d-proton/issues/3165),
  [#3327](https://github.com/HansKristian-Work/vkd3d-proton/issues/3327),
  [open-gpu-kernel-modules #962](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/962)).
- **Outside NVIDIA's support:** NVIDIA's DLSS-G guide names a driver below 595.41 as a reason dynamic mode is
  unsupported. The Spark gets only R580, which dxvk-nvapi reports to the game as "580.99", yet the game's Streamline
  (2.11.1) logs "Dynamic MFG is supported". The game's own known issues list crashes "when using Frame Generation and
  DLSS" on NVIDIA 50-series cards, the same Blackwell generation as GB10.
- **What does not turn it off:** `r.Streamline.DLSSG.Enable=0` in Engine.ini (NVIDIA's Unreal plugin rewrites it from
  the game's setting; the run with it still switched 39 times), and the menu's provider setting alone
  (`CurrentFrameGenerationProvider=Off` was saved at 23:13 with `DLSSFrameGenerationMode=OnDynamic`, and 298 switches
  followed). The mode key is the one that counts.
- **The change:** `DLSSFrameGenerationMode=Off` in the game's `Saved/Config/Windows/GameUserSettings.ini`, made with
  the game closed. Even off, the DLSS-G plugin stays in the present path (Streamline's DLSS-G guide, section 12.1);
  `-slnodlssg` on the command line or `r.Streamline.Load.DLSSG=0` should keep it from loading at all. Both are in the
  exe, and neither is tested here.
- **Why it freezes instead of crashing:** vkd3d-proton releases the fences an app waits on when the device is lost only
  since [750061ae](https://github.com/HansKristian-Work/vkd3d-proton/commit/750061ae2be846d19d6364628eaf5ea4beb8e619)
  (2026-10-05), after this Proton's 44cf7c20, and here nothing reported a lost device anyway.
- **Not known yet:** whether frame generation causes the hangs, whether `Off` holds at a fresh launch, and whether the
  barrier line hangs without frame generation. One hang in 63 minutes means a short session without one proves little.

**What the flicker is.** Recorded with `x11grab` at 30 fps, it is single "flash frames": one frame that disagrees
with both neighbours while they agree with each other. In a flash frame, independently:
- the ground is missing (a dark plane and patches of sky where the terrain should be, while rocks, debris and buildings
  are drawn);
- meshes that are hidden from the player camera appear: the podracer's engines, of which normally only the energy
  binder and their shadows show; in another frame a vehicle body in the foreground vanished instead (read backwards:
  the frames around it are the broken ones, with the player's vehicle missing; 2026-10-19, below);
- there is no motion blur at all, where the frames 33 ms before and after are heavily blurred.

In a desert race about half of the moving frames had more than 1% of the lower half's 8x8-pixel tiles flash; at peaks
90%. That share overstates the bug: on the Nanite-off recording the same measure still flags 21% of racing frames
above 1%, from things the game does on purpose (camera cuts at takedowns and at the finish, a golden hologram of the
engines), but only 0.25% above 10% and none above 40%. Compare runs at 10% or 20%. Earlier, two other flickers had
been fixed in Engine.ini: background objects in the menu (hardware occlusion queries and Nanite's HZB occlusion:
`r.AllowOcclusionQueries=0`, `r.Nanite.Culling.HZB=0`) and the landscape in a frozen scene
(`r.Nanite.Streaming.ReservedResources=0`: Nanite's streaming pool as a plain buffer instead of a sparse one). The
flash frames in motion survived everything else:

| Change | Would have pointed at | Flash frames |
|---|---|---|
| `VKD3D_CONFIG=single_queue` | async compute racing graphics | still there |
| `VKD3D_DISABLE_EXTENSIONS=VK_EXT_mesh_shader` | Nanite's mesh-shader raster path | still there |
| `r.Nanite.PersistentThreadsCulling=0`, `r.Nanite.Streaming.Async=0`, `r.PSOPrecache.ProxyCreationWhenPSOReady=0`, `r.SkipDrawOnPSOPrecaching=0` | Nanite culling, streaming, shader precaching | still there |
| `r.Nanite.Tessellation=0` | displaced terrain | still there (the floor too) |
| `r.Nanite.Streaming.StreamingPoolSize=1536` (default 512; 2048 stops the game: "must be smaller than the largest allocation supported by the graphics hardware (2048MB)") | a streaming pool too small for the track | still there |
| `r.FinishCurrentFrame=1` (60 fps) | the CPU overwriting data the GPU is still reading | still there |
| `VKD3D_CONFIG=force_host_cached` | the GPU reading stale CPU-written upload memory (memory type 2, uncached, replaced by type 3, cached) | still there |
| `FEX_VECTORTSOENABLED=1 FEX_MEMCPYSETTSOENABLED=1 FEX_HALFBARRIERTSOENABLED=0` (58-63 fps) | x86 memory ordering lost in translation | still there |
| `r.Nanite=0` | Nanite | **gone** |

So it takes Nanite to trigger it, and it does not need the CPU to run ahead of the GPU. x86 memory ordering is unlikely
but not excluded: `FEX_HALFBARRIERTSOENABLED=0` is weaker than the default for unaligned accesses, and FEX never orders
stack accesses. `r.GPUScene.InstanceUploadViaCreate=0`, also tried, tested nothing: unlike every other setting here, it
is not in the game's binary. The game writes no Unreal log, so a setting without a visible effect is not confirmed to
have applied. Whether it breaks in Unreal, in vkd3d-proton or in the driver is not known yet. Nanite off was first
tried at the original high settings with ray tracing and ran too slowly; at medium with the fixes below it averages
83 fps.

A research pass (four lanes: vkd3d-proton, NVIDIA driver, FEX, Unreal 5.7 source, then a skeptic ranking them) found
no report of this exact symptom. The closest is Talos Principle 2 (Unreal 5): random single glitchy frames that went
away with a setting that turns Nanite off were an AMD driver bug in Mesa
([vkd3d-proton #1732](https://github.com/HansKristian-Work/vkd3d-proton/issues/1732)). The game shows the engines and
cuts the camera on purpose, so the signature to count is a single frame that reverts, keeps the camera pose and the
HUD, and loses the terrain or shows fully shaded engines without motion blur. Next tests, likeliest cause first:
- **vkd3d-proton's new barrier code.** This Proton Experimental (2026-10-01) carries vkd3d-proton master 44cf7c20, 439
  commits after v3.0.1. Since August those commits changed COPY barriers, ClearUAV, fence waits on NVIDIA and Reflex's
  queue handling, and no setting turns the first three off. The barrier change (238f157e) defers the legacy
  COPY_DEST-to-shader-resource transitions that Unreal makes for uploaded buffers, and it brought an open NVIDIA
  regression with intermittent flashes ([#3355](https://github.com/HansKristian-Work/vkd3d-proton/issues/3355): that
  early return skips a pending device-generated-commands flush). The cheapest test,
  `r.D3D12.PreferredBarrierImplementation=2` in Engine.ini (Unreal's enhanced barriers, which vkd3d-proton translates
  without deferring), hung the GPU in both runs with it on 2026-10-11 (Nanite on): at the menu about 70 s after launch,
  0.4 s after frame generation first switched on, the driver logged `Xid 109 ... CTX SWITCH TIMEOUT` on the game
  thread's channel. The five runs without the line got past that moment. Frame generation was on in every run, so
  whether the barriers hang without it is untested; Streamline 2.12.0 fixed "a D3D12 resource barrier mismatch [...] on
  Frame Generation output buffers", and the game ships 2.11.1 ("GPU hangs with dynamic frame generation" above). Next:
  Proton 11.0 as the game's
  compatibility tool (its vkd3d-proton, 212991fc, has none of these changes), the v3.0.1 DLLs, or a 44cf7c20 build
  with the fix proposed in #3355. Turning off `VK_EXT_device_generated_commands` is not a clean test: vkd3d then drops
  the state changes such indirect draws carry, which breaks rendering by itself.
- **NVIDIA's driver.** DGX Spark supports only the R580 branch, and the fixes that could matter are only in Vulkan
  betas: a "race condition between Vulkan graphics and DLSS" and "D32 formatted images [...] corrupted after being
  written by a transfer or compute stage" (595.44.15), a "skipped barrier after host transfer" (595.44.09). Test TSR
  instead of DLSS first; a driver change last. The Spark runs 615.71.09 since 2026-10-19, but frame generation is
  untested on it ([below](#star-wars-galactic-racer-nanite-on-after-a-driver-change-2026-10-19)).
- **Unreal's async compute and transient memory.** One run with `-DisableAsyncCompute` on the command line and
  `r.RDG.TransientAllocator=0`, `r.RDG.TransientExtractedResources=0` in Engine.ini; split them up if it helps.
- **Where in Nanite.** `r.Nanite.FilterPrimitives=0` (the per-view filter for hidden primitives and the landscape),
  then `r.Nanite.ProgrammableRaster=0` (masked materials); `r.SceneCapture.AllowRenderInMainRenderer=0` in case a
  scene capture, which by default renders without motion blur or an owner, replaces the main view.
- Cheap, low odds: Reflex off in-game; `VKD3D_DISABLE_EXTENSIONS=VK_EXT_descriptor_buffer`.

Ruled out on paper: the six wave64 pipelines that fail at startup ("Required WaveSize range [64, 64], but supported
range is [32, 32]") are Lumen, TSR, Substrate and hair-strand permutations that Unreal selects only when the GPU
reports 64-wide waves; and the dxil-spirv fix for "rapid flickering and disappearing surfaces" on NVIDIA
([#312](https://github.com/HansKristian-Work/dxil-spirv/issues/312)) applies only without `VK_NV_raw_access_chains`,
which this driver has.

**Hitches: pinning that did not hold.** At medium with Nanite on the frame log showed about 1.3 spikes a second
(median 26.6 ms against 12.3 ms frames), at irregular intervals, more on some sections of a track than others.
- Polling the GPU at 10 Hz with `nvidia-smi` during a race added no spikes, so GPU monitoring was not the cause.
- A 1 ms per-thread sampler (`/proc/<pid>/task/*/schedstat`) lined up with the frame log showed no single thread
  working longer in slow frames; the threads mostly waited. (MangoHud's `elapsed` clock starts 0.1-0.2 s before
  its CSV file exists; the offset was found where the submission threads' per-frame activity is sharpest.)
- The game used 7.4 cores while the 10 cores it was pinned to were 37% busy. `taskset -a` after launch only moves
  threads that exist: 172 of 181 threads were allowed on all 20 cores again, and threads named GameThread were last
  seen on A725 cores.
- `PROTON_CPU_TOPOLOGY=10:5,6,7,8,9,15,16,17,18,19` from launch keeps every thread on the X925 cores. The game then
  starts 11 worker threads instead of 24, and the 99th percentile frame fell from 24.7 to 15.1 ms. Proton sets this
  itself on arm64, but it checks `platform.machine()`, which says x86_64 under FEX. Per game: Cyberpunk lost 8% this
  way (E9 above).

**Audio dropouts.** `pw-top` showed the HDMI output running 128-sample (2.7 ms) cycles because Wine asked for very
little buffering, and each of the game's two streams underran about 15 times a minute. Raising PipeWire's minimum
cycle (`pw-metadata -n settings 0 clock.min-quantum 1024`) stopped it at once. Per game instead:
`PULSE_LATENCY_MSEC=60` gave 512-sample cycles and about 1.4 underruns a minute; `90` gives 1024-sample cycles and 5
underruns in 8 minutes.

**Engine.ini.** The game deletes `Saved/Config/Windows/Engine.ini` after reading it at startup, so `tools/launch.sh`
copies `profiles/launch/4078430.Engine.ini` into the prefix before every launch (`UE_PROJECT` names the folder).


## STAR WARS: Galactic Racer: lighting, hitches and where the CPU time goes (2026-10-13)

The player reported caves and shaded areas far too bright on many maps, Crait's white salt flat drawn black, texture
and lighting faults on the campaign's second map, and lag spikes.

**A repeatable race.** `bench/games/galacticracer.sh` drives the game by keyboard from launch to the Arcade time trial
"Landspeeder Ace" (Jakku, `L_Mastiff_LOOP_A`, open from the start): Space only on the title and photosensitivity
screens it reads with OCR, the main menu recognised by its red tab, never by trying keys (Space on the menu's Campaign
tab continues the player's campaign). It photographs the intro card (the same camera every run, to compare lighting)
and holds the throttle with no steering from there: the same straight, walls and crash every run. MangoHud logs from
the steady event page and `bench/ingest.py` keeps the 30 s from the throttle (`frames_window`), because a log hotkey
pressed while the game stalls is lost. Records now carry `p999_frame_ms`, `max_frame_ms` and `frames_over_50ms`.
`GR_RECORD=SECS` also records the screen and counts flash frames (`tools/flashframes.py`).

Player settings for every run: mostly High, view distance, shadows and effects Medium, 2560x1440 fullscreen on the 4K
TV, DLSS Super Resolution Performance, Reflex on, frame generation off, the frame cap lifted. Proton Experimental
`experimental-11.0-20261008` (vkd3d-proton 22307558, installed by Steam on 2026-10-12). Identical runs differ by up to
16% (57.1 and 66.6 fps): the first run after a settings change compiles pipelines in the race, so compare warm runs.

| Configuration | Avg fps | 1% low | Frames > 50 ms (30 s) | Lighting |
|---|---:|---:|---:|---|
| Old profile: Nanite off, DXR hidden (`nodxr`) | 73.5 | 30.9 | 8 | flat: no Lumen |
| DXR visible, ray tracing on, spline meshes out of it | 59.1 (windowed) | 15.7 | 23 | intended |
| **New profile:** DXR visible, `r.RayTracing.Enable=0`, spline meshes out of it | 64.8-66.6 (5 warm runs) | 20-26 | 13-20 | intended |
| New profile + DLSS Ultra Performance | 65.3 | 24.2 | 15 | intended |
| DXR visible, `r.RayTracing=0` | 72.8 | 24.8 | 15 | flat again |

**Why the lighting broke.** Hiding DXR (`VKD3D_CONFIG=nodxr`, 2026-10-11, against the Mastiff crash) made the game
light its levels without Lumen: an even light everywhere, so caves and the undersides of wrecks were as bright as open
sand. The intro card shows it plainly: washed-out midday with DXR hidden, a dusk scene with deep shadows with DXR
visible. The game picks Lumen only when Unreal may ray trace: `r.RayTracing=0` flattens it again although DXR is
visible. (Corrected 2026-10-14: an earlier line here said `r.RayTracing.Enable=0` kept the lighting without the ray
tracing scene. The game sets `r.RayTracing.Enable` back to 1 from code at every map load, so that run had ray tracing
on, and Lumen in this game runs only on hardware ray tracing.) Correct lighting cost about 10% against the flat
look (73.5 to about 66 fps). The game's baked lighting gives it back without ray tracing (2026-10-14, below).
Not verified: Crait drawn black and the campaign's second map, which the bench cannot reach (the campaign; Crait's
Arcade event is locked).

**The new profile** (`profiles/launch/4078430.*`, replaced 2026-10-14): DXR visible, `r.RayTracing.Enable=0`,
`r.RayTracing.Geometry.SplineMeshes=0` (the Mastiff crash; ineffective, see 2026-10-14), Nanite still off. Its recorded race had no flash frame
(worst 5.9% of tiles; Nanite on reached 65% in one frame).

**Nanite's flash frames survive vkd3d-proton 22307558.** With Nanite on, single frames lose the terrain (a sky-coloured
mirror plane where the ground was; rocks, wrecks and the vehicle drawn) or draw a mesh hidden from the player's camera
(the landspeeder's body in the over-the-shoulder view).
- `r.SceneCapture.AllowRenderInMainRenderer=0`: no change in kind (12 frames above 20%, 5 above 40%).
- `landscape.RenderNanite=0` (terrain through the classic landscape renderer, everything else Nanite): the terrain no
  longer vanishes; the hidden-mesh frames remain.
- Both symptoms are what a wrong per-view primitive filter gives (Nanite's filter of hidden and show-only primitives
  per view), as if the main view used another view's filter for one frame.
- Not aliasing: `r.RDG.TransientAllocator=0` (no aliasing of transient buffers) had more, 15 frames above 20% and 7
  above 40%, against 5 and 0 for the same run without it. Not ray tracing either (unproven: `r.RayTracing.Enable=0` did
  not actually hold, 2026-10-14): with the new profile's `r.RayTracing.Enable=0` they remain (the landspeeder's hidden body drawn for one frame in the intro, the ground gone
  to white sky). Nanite on was not faster with Lumen (51-56 fps recorded), so the profile keeps it off; the cost is
  Nanite's coarse fallback meshes.
- `tools/flashframes.py` now crops to the game's picture: a game that emulates a display mode the TV lacks (2560x1440
  on 4K) sits in one corner of an `x11grab` capture, which diluted every share.

**Where the CPU time goes** (`profile/profile.sh galacticracer L key 30`, new profile, racing; every thread of the game
and its wineserver):

| Layer | Share of the game's CPU |
|---|---:|
| The game's own x86 code (Unreal and Denuvo, translated) | 64.5% |
| Kernel (scheduler; IOMMU and TLB invalidation for GPU memory unmapped) | 13.8% |
| Wine (x86, translated) | 9.6% |
| NVIDIA driver (native arm64 through FEX's Vulkan thunk) | 5.2% |
| vkd3d-proton (x86, translated) | 4.9% |

- Two thirds of the CPU time is the game's own code, which only FEX's translation can speed up. Wine, vkd3d-proton and
  wineserver, the part an ARM64EC Proton would run natively, are about 20%: a ceiling of roughly 10-15%, worth it later,
  not the fix for these frame times.
- No thread is saturated: the game thread runs about half a core, the render threads about one, the GPU is 85% busy at
  about 2450 MHz. Unreal's worker threads keep about 4 of the 10 fast cores busy all the time; their hottest block
  (`FEX_BLOCKJITNAMING=1`) is a loop over 128 KB structures calling a try-function on each, the shape of the task
  scheduler stealing work while idle.
- `profile/analyze.py` now takes `pid:` filters (Unreal names 11 threads "GameThread"), files the patched FEX's own code
  under the FEX runtime, and labels the thunked arm64 NVIDIA driver as native.

**The hitches are first-time work, not shaders and not garbage collection.** They recur at the same moments of the race
in every run (about 1.5, 5, 7.5 and 21 s: the crash at 21 s has the longest, up to 660 ms), so content triggers them,
and every run is a fresh process. In the profile's 100 ms bins the pipeline-compile threads (the driver's `[vk*]`,
`PSOPrecompile`) stay near zero throughout; FEX's translator takes a full core just before the 1.3 s hitch (new code
translated); at the 6.8 s hitch the game thread keeps running while the render threads and workers drop to almost
nothing (game-thread work such as spawning or post-load). Incremental garbage collection
(`gc.AllowIncrementalReachability=1`, `gc.IncrementalReachabilityTimeLimit=0.002`,
`gc.IncrementalBeginDestroyEnabled=1`) changed nothing.

**Tried, no gain:**
- `nvidia-smi -lgc 3003,3003`: accepted, but the GPU stays near 2450 MHz under load (no throttle reason reported).
- `ntsync` (kernel 6.17 ships it; Proton's wineserver uses `/dev/ntsync` when present, 2776 handles held): 65.9 and
  65.2 fps against 64.8-66.6 with fsync. Unloaded again.
- Reflex off: 64.8 fps. DLSS Ultra Performance: 65.3 fps (the GPU is not the limit).
- FEX 2610's `DiskCache` (persistent translated code): the launch chain segfaults at once (Proton's tools under FEX).

**Measurement traps found on the way.**
- Unreal toggles fullscreen on F11 even with Shift held (`UGameViewportClient`), so `lib/menu.sh`'s `Shift_R+F11` log
  hotkey turned fullscreen runs windowed. It is `Shift_R+Scroll_Lock` now.
- Without a host tesseract, every `tools/ocr.sh` call ran a container, each adding and removing a network interface,
  the mechanism behind The Witcher 3's stutter (Wine keeps every interface it has seen). tesseract is installed now,
  and the helper containers run with `--network host` (as_root, the governor) or `--network none` (the OCR fallback).
- A launch right after a killed run fails: Steam waits for the previous process (`WaitingPrevProcess`, then
  `AppError_16`). `bench/run.sh` now waits for the app's reaper to exit, and a failed menu drive ends the run.
- The game pauses itself when a controller disconnects (a DualSense at 5% battery).

## STAR WARS: Galactic Racer: the campaign crash, and FEX throwing away its translations (2026-10-14)

The player could not continue the campaign (a crash every time) and had lag spikes and drops below 60 in races.

**The crash.** Three of three campaign loads of `L_Mastiff_LOOP_A` crashed 1-4 s after the map loaded (two by the
player, one of them Continue Campaign, and one in the bench) with the profile of 2026-10-13: DXR visible, `r.Nanite=0`,
`r.RayTracing.Enable=0`, `r.RayTracing.Geometry.SplineMeshes=0`. It is the crash of 2026-10-11:
`SWGR-Win64-Shipping.exe+0x827114` on RenderThread 0, `FStaticMeshSceneProxy::CreateDynamicRayTracingGeometries`
reading a null ray-tracing proxy.
- **Unreal 5.7** (public 5.7.0 source): `FSplineMeshSceneProxy` always asks for dynamic ray-tracing geometry, also for a
  mesh cooked without ray-tracing support, which has no ray-tracing proxy. The Nanite spline proxy that every Windows
  player gets asks only when the mesh supports ray tracing. `CreateRenderThreadResources` checks only
  `IsRayTracingEnabled()`. `r.RayTracing.Geometry.SplineMeshes` is read per frame where instances are gathered, not
  where the geometry is built, so it never protected against this crash. 5.3-5.6 have the same code, and an Epic forum
  thread (January 2025, 5.5.1) reports the same crash.
- **Why ray tracing was on** (the game's code, read in the exe): on every map load `UWorld::InitWorld` calls a function
  of the game's that sets `r.RayTracing.Enable` to 1 unless the level loaded baked lighting, at priority SetByCode,
  which outranks Engine.ini's `[SystemSettings]`. Our `r.RayTracing.Enable=0` never held past the main menu. The
  time-of-day lighting manager calls the same function, and each call recreates the render state of every component,
  which is the path that crashes.
- **Why Arcade did not crash:** about 20 Arcade loads of the same map with ray tracing on passed; the campaign's route
  adds the spline meshes that have no ray-tracing data.
- **Lumen needs hardware ray tracing in this game.** Its `DefaultEngine.ini` (unencrypted pak) sets
  `r.GenerateMeshDistanceFields=False`, so there is no software Lumen and, with DXR hidden, no indirect light at all: the
  flat look of 2026-10-11. The game has its own lighting for no ray tracing, its Global Illumination Low tier:
  `gfn.StaticLighting.UseVolumetricLightingIfAvailable` loads baked lighting (`<map>_<time of day>_BuiltData`, 57 ship)
  and sets `r.RayTracing.Enable=0` itself.

**The profile now** (`profiles/launch/4078430.*`): DXR hidden again (`VKD3D_CONFIG=nodxr`), so ray tracing cannot be
enabled whatever the game sets; Nanite off; and the baked lighting
(`gfn.StaticLighting.UseVolumetricLightingIfAvailable=1`, `r.SkylightIntensityMultiplier=0.8` as in that tier), which
brings back the dusk shadows in the first campaign race without ray tracing. The two ray tracing lines are gone. Nanite
on also avoids the crash with Lumen (the Windows setup) but costs about 20% in races and brings back the hidden-mesh
flash frames.

**A campaign route for the bench.** `GR_ROUTE=campaign bench/run.sh galacticracer LABEL` selects the Campaign tab,
presses Space only after reading "CONTINUE CAMPAIGN" on the card, reads map loads from the game's crash-reporter
breadcrumbs, waits through the intro card and the cutscene (letterboxed) for the race camera, and holds the throttle for
30 s of racing: 12 cars, The War Fields (reverse) on Jakku. The player's saves are archived before the launch and put
back after the game closes; their checksums were unchanged after every run today.

| Campaign race, 1440p, DLSS Performance, warm | Runs | Avg fps | Frames > 50 ms (30 s) | Crashes | Lighting |
|---|---:|---:|---:|---:|---|
| 2026-10-13 profile (DXR visible, Nanite off) | 1 | | | 1 of 1 | |
| DXR hidden, Nanite off (stock FEX) | 5 | 66.1-75.9 | 4-19 | 0 | flat |
| DXR visible, Nanite on, `landscape.RenderNanite=0` | 2 | 59.1, 59.7 | 12, 12 | 0 of 3 | Lumen |

**FEX threw away all its translated code every 20-70 s.** FEX keeps one buffer of translated code per process: 16 MB
at first, doubled up to 128 MB, and each time it is full every translation is dropped and code is translated again on
the thread that next runs it. This game translates about 600 MB in a session (Denuvo's VM and Unreal): in a 250 s
campaign run the buffer filled 6 times while the game started, once as the map loaded and once as the race began, and
the race's worst frames (226-475 ms) came in the 1.4 s after that last fill.
`fex/patches/0003` allocates one 1 GiB buffer at the start (`system/fex-patched.sh install`); the same run used 598 MB
of it and never filled it. Branches to code more than 128 MB away already go through an indirect jump. `[anon:FEXMemJIT]`
mappings in `/proc/<pid>/maps` show each new buffer.

| Campaign race, DXR hidden | Runs | Avg fps (mean) | p99 frame (mean) | Frames > 50 ms (mean) | Time in frames > 33 ms (mean) | Worst frame |
|---|---:|---:|---:|---:|---:|---:|
| Stock code buffer | 5 | 66.1-75.9 (71.2) | 33.1-48.1 ms (38.5) | 4-19 (10.6) | 1.1-3.1 s (1.8) | 130-596 ms |
| 1 GiB code buffer | 5 | 69.3-87.8 (75.5) | 26.4-36.2 ms (31.8) | 2-5 (3.6) | 0.7-1.2 s (0.9) | 122-145 ms |

Buffer fills, where the watcher ran: 8 in a stock run (6 more in a second one before it stopped), none in three 1 GiB
runs, which used 598-607 MB.

The remaining hitches come at the same race moments (about 4, 11, 17 and 24 s into the window), so they are content.

**Tried, no gain** (each against the same day's baseline):
- System latency bundle: CPU wake latency capped at 0 (PM QoS, cores stay out of power-down idle states), THP defrag
  `defer`, `vm.watermark_scale_factor=200`, RLIMIT_NICE 30 for Wine's thread priorities, wineserver on the fast cores
  (`TASKSET` in `tools/launch.sh`): 74.9, 73.1, 76.2 fps and 3-5 frames over 50 ms, the same as the baseline.
- Occlusion culling back on (`r.AllowOcclusionQueries=1 r.HZBOcclusion=1`) and
  `r.Shadow.Virtual.NonNanite.IncludeInCoarsePages=0`, with the baked lighting: GPU load 2-4 points lower, fps the same
  (71.3, 75.6). Not kept: the occlusion line was added against a menu flicker.
- FEX's lookup caches at their larger settings (`FEX_DISABLEL2CACHE=0 FEX_DYNAMICL1CACHE=0`): noise.
- FEX's persistent code cache (`DiskCache`, scoped to the game with `~/.config/fex-emu/AppConfig/SWGR-Win64-Shipping.exe.json`):
  it passed Denuvo and filled its 1 GiB file in one run, but warm runs had the same hitches (71.9, 70.4 fps; 13, 11
  frames over 50 ms). It is also unsafe with `fex/patches/0002`: a block cached while no breakpoint was armed would skip
  Denuvo's breakpoint check. Not used.

- Valve's Steam Frame block size (`FEX_MAXINST=500`), a CPU performance floor (CPPC `min_perf` at `max_perf` on the
  X925 policies; `scaling_min_freq` and `boost` do nothing in CPPC autonomous mode) and the game's first logical CPUs on
  cluster 1 (`PROTON_CPU_TOPOLOGY=10:15,16,17,18,19,5,6,7,8,9`; cluster 1 has 16 MB of L3, cluster 0 8 MB): 73.2, 73.7
  and 69.2 fps with 3-5 frames over 50 ms, against 72.0 and 70.4 fps with 5 and 7 for the profile. One run each;
  stopped there as noise.

**What is left.** On the final stack (profile, 1 GiB code buffer, frozen Proton) the campaign race ran at 66.8 and 70.7
fps (the first run right after a Steam client update). About a fifth of racing frames still take longer than 16.7 ms
(22% against 23% before the code-buffer patch and 34% with Nanite and Lumen), while frames over 50 ms fell from 0.5%
to 0.2-0.3%: the drops below 60 that remain are a broad band of 17-33 ms frames, the cost of translated game code with
no thread saturated, not spikes. Two of about 40 bench launches failed at startup today, both after quick kill-and-relaunch
cycles: once a "Failed to load SteamAPI" dialog, once an exit before the crash reporter started that left the game a
zombie with hung threads, holding Steam's reaper. `bench/run.sh` now ends such a leftover launch chain (the reaper's
process tree) when no live game is found.

**Proton is about to drop what Denuvo needs here.** Proton's bleeding-edge branch (2026-10-14) replaced Wine's
seccomp-based syscall trap with Syscall User Dispatch, which the Spark's kernel lacks; `fex/patches/0001` builds on the
seccomp trap. When Proton Experimental takes that change, the game will most likely stop starting. `tools/launch.sh` now
refuses to start a `FEX_NEEDSSECCOMP=1` game on a Proton whose `ntdll.so` has no seccomp trap.
Frozen 2026-10-14: the game runs on `GameSpark-Proton-Exp-20261008`, a copy of Proton Experimental 20261008 in
`compatibilitytools.d` with a `compatibilitytool.vdf` (`tools/steam-config.sh compat-tool 4078430 GameSpark-Proton-Exp-20261008`);
other games keep Proton Experimental. The prefix version is unchanged (11.0-100). Upgrade path: Syscall User Dispatch
emulation in the patched FEX (Box64 has one), then back to Proton Experimental.

**Not paths for this game** (research, 2026-10-14): Valve's ARM64EC Proton (the Steam Frame stack: Wine natively, FEX
only for the game) handles Denuvo's direct syscalls but drops x86 debug registers in both Wine's ARM64EC context
conversion and FEX's ARM64EC frontend, so Denuvo's per-thread breakpoint check would fail; it also needs the native
arm64 Steam client. Windows on Arm does not run on the Spark yet (no NVMe driver; the GPU driver crashed in a community
attempt). Box64 lacks both Denuvo features. The ARM lesson that transfers is FEX's code buffer above and, once it is
safe with the breakpoint patch, its disk cache.

## STAR WARS: Galactic Racer: benchmarks on the player's own races (2026-10-15)

The old bench held the throttle for 30 s on one straight (Landspeeder Ace), or in the first campaign race. That is
repeatable, but it isn't how the game is played: no corners, no set pieces, no other planets. The player raced 10 Arcade
events on four planets while their DualSense input was recorded. The bench now drives those events again, two ways: with
the player's own input, or with the game's AI at the wheel.

**Recording** (`bench/gr-record.sh start|stop`), while the player races:
- the pad's raw Bluetooth input reports (`tools/padreplay.py record`), about 450 per second with both clocks;
- a 440x200 screen strip at 30 fps (x 780-1220, y 100-300 at 4K), which holds the race clock and the lower edge of the
  2.39:1 letterbox bars. A full-screen 4K capture made the game feel laggy to the player; this strip did not.

`stop` cuts one race file per finished race, from the intro's first letterboxed frame to the finish cinematic. Each file
keeps the map, the game build and the letterbox edges in between. The event's position in the Arcade row is noted by hand
(`padreplay.py note RACE event_keys=Right*N`).

**How the game runs an Arcade event** (measured on the recordings, the exe and the menus):
- **Time trials** have a rolling start with no countdown.
  - The intro is letterboxed for 7.5-29 s; holding X skips it.
  - The clock starts under the start gate, 6.0 s after the intro ends (Crait, Skim Speeder Champion).
- **Set pieces** in a race are letterboxed for about 6 s (once per lap on Sentinel I). The race clock pauses 2-3 s in each.
- **The finish** is a letterboxed cinematic: 6.0 s for loop races, 5.0 s for podracers.
- **Crashes** are letterboxed too: a 3-6 s crash camera, then a respawn.
- **Physics** runs at a fixed 1/60 s step (Fuse ships `p.UseFixedSizeSubsteps=True`).
- **The Arcade tab** opens on the last event played.
  - Its cards form one row of 61, and Z/C jump between sections of it.
  - Holding Left (X key repeat) returns to the first card from anywhere; `Right*N` then lands exactly on card N.
- **Event titles** defeat tesseract. The bench checks the map that loads instead, read from the crash reporter's
  breadcrumbs.
- **Map codenames:** Mastiff = Jakku, Spaniel = Crait, Husky = Sentinel I, Dalmatian = Lantaana, Corgi = Ando Prime.
  `*_PLANE` maps host the podracer races.

**The replay route** (`GR_ROUTE=replay GR_RACE=NAME bench/run.sh galacticracer LABEL`):
- **Setup.** The bench backs up the saves and disconnects the player's DualSense; its PS button reconnects it.
- **The virtual pad.** A virtual DualSense (`padreplay.py twin`: uhid, run as root) appears before the game starts, so
  the game never sees a controller come or go.
  - It is built from the pad's own report descriptor and feature reports.
  - Its MAC has the locally administered bit set.
  - Its replayed reports have the PS button masked and the battery at full.
- **Navigation.** The bench drives the menus to the race's event by keyboard and checks the map that loads.
- **Sync.** A watcher (`padreplay.py watch`) reports letterbox edges from the same strip and keeps the strip as video.
  - The virtual pad starts the recorded input on the intro's first frame.
  - It re-aligns on every later edge that matches a recorded one within 2.5 s.
- **Measured window.** It runs from the intro's end to 5 s before the finish line, and then the game is killed: a finished
  Arcade event posts its time to the game's online leaderboard. `GR_REPLAY_FINISH=1` finishes the race;
  `GR_REPLAY_SECONDS=N` measures only the first N seconds.
- **`GR_DRIVER=ai`** sets the debug cvar `Race.AI.DriveLocalPlayer=1` ("Should automatically drive the player?"; not a
  cheat cvar, and the Shipping exe reads it). The game's AI then drives the player's vehicle and the virtual pad stays
  at rest. With the AI, the intros and pre-race cutscenes run their full length (the player skipped some). The race
  therefore starts at the end of the last letterbox before 8 s without one, seen live, and the run measures the 60 s
  after it by default.
- **Fixed-moment screenshots.** `GR_SHOTS="10 30"` takes screenshots that many seconds after the race's start.

**The player's input does not stay on their line** (Crait, Skim Speeder Champion and Jakku, Super Surge; 2 runs each):
- The replay started in sync: the intro's end came 37 and 68 ms off the recording, and the clock started 6.0 s later, as
  in the recording.
- The car then left the player's line and crashed into the crystals 20.7 s and 15.7 s after the intro. It crashed again
  every few seconds after that; the run's crash cameras are its unmatched edges.
- On Jakku's speeder bike at 70-78 fps it went the same way. Both replays were at the same spot 10 s after the intro
  (clock 3.79 and 3.75 s), then crashed 13 and 16 s after it.
- Contributing causes, none proven to be the whole story:
  - The mines render at 14-20 fps, in the player's session too, judged from repeated frames in the recorded strip and
    calibrated against MangoHud. At 50-70 ms per frame, when an input reaches the physics depends on where the frame
    boundaries fall.
  - Frames over 100 ms lose simulation time if Fuse keeps Unreal's cap on steps per frame (not verified). Run 1 lost
    about 200 ms that way before its crash.
  - The game has random events ("SYSTEM MALFUNCTION" banners), and its random seed differs every launch. `-FixedSeed`
    is parsed by the exe but untested.
  - A 30-60 ms error at 80 m/s is metres, and the tracks leave no room.
- Open-loop replay needs a game that simulates the same way every time; this one doesn't.

**The game's AI repeats itself** (same event, 2 runs, 60 s): clock 00:04.26/00:04.33 at +10 s, 00:24.32/00:24.37 at
+30 s, 00:44.30/00:44.37 at +50 s. The screenshots are the same scene. 35.1 and 35.8 fps, 1% low 12.9 and 13.0, 202
and 197 frames over 50 ms: a 2% spread. That is the benchmark to compare settings with. The player's recordings still
choose the events, and their input replay is good for the first ~15 s of a heavy map.

**Dataset (build 25880680):** `$SG_DATA/gr-inputs/races/`, 10 finished races.

| Race file | Planet | Event (gold) | Card | Window |
|---|---|---|---:|---:|
| sentinel-skim-speeder-ace | Sentinel I | Skim Speeder Ace (1:34) | 4 | 121.5 s |
| crait-skim-speeder-champion | Crait | Skim Speeder Champion (1:12) | 5 | 93.7 s |
| lantaana-six-limbed-fury | Lantaana | Six-Limbed Fury (podracer, 2:25) | 7 | 201.3 s |
| andoprime-veknoids-charm | Ando Prime | Veknoid's Charm (podracer, 2:22) | 8 | 198.8 s |
| lantaana-assassins-ploy | Lantaana | Assassin's Ploy (podracer, 1:46) | 9 | 161.6 s |
| andoprime-erkit-ambition | Ando Prime | Er'Kit Ambition (podracer, 1:42) | 10 | 132.9 s |
| crait-hope-of-the-toong | Crait | Hope of the Toong (podracer, 2:28) | 11 | 197.7 s |
| jakku-venting-machine | Jakku | Venting Machine (landspeeder, 1:36) | 43 | 156.8 s |
| jakku-super-surge-1, -2 | Jakku | Super Surge (speeder bike, 1:16) | 44 | 105.0, 90.3 s |

### Crait's salt flats render black: Nanite off

The player reported Crait's white salt rendering black. Crait is the `Spaniel` codename: the shipped asset names
include salt-flat audio, vulptex howls, crystal ravines, mine tunnels and salt landscape layers. The AI driver made a
clean A/B: the same podracer event (Hope of the Toong), 60 s from the race start, screenshots at the same race seconds.

| Profile arm | Salt | Avg fps | 1% low | Frames > 50 ms |
|---|---|---:|---:|---:|
| A0: the 10-14 profile (Nanite off, DXR hidden, baked lighting), 3 runs | black | 58.8, 55.3, 53.2 | 21.3, 21.0, 18.8 | 23, 24, 38 |
| A1: A0 without the forced baked lighting | black | 54.4 | 21.9 | 17 |
| A2: A0 with `r.Nanite=1 landscape.RenderNanite=0`, 2 runs | white | 73.1, 70.5 | 32.2, 33.4 | 11, 7 |
| A3: DXR visible, Nanite on, no baked lighting (Lumen, the Windows setup) | white | 60.8 | 29.2 | 7 |

- **Cause: Nanite off.** The planning agent suspected the forced baked lighting first; A1 rules it out. Nanite on renders
  the salt white with every lighting setup tried.
- **Nanite on is faster on every planet tried**, with DXR still hidden. The 10-14 measurement where it cost about 20%
  came with Lumen; A3 shows Lumen's cost here (-14% against A2).

  | Event (AI driving, 60 s) | Nanite off: avg / 1% low / > 50 ms | Nanite on | Avg |
  |---|---|---|---:|
  | Lantaana, Six-Limbed Fury (podracer) | 37.6 / 12.6 / 126 | 69.6 / 32.2 / 7 | +85% |
  | Crait, Hope of the Toong (podracer) | 58.8 / 21.3 / 23 | 73.1 / 32.2 / 11 | +24% |
  | Jakku, Venting Machine (landspeeder)* | 64.6 / 28.8 / 13 | 70.0 / 33.4 / 9 | +8% |
  | Jakku, Landspeeder Ace, screen recorded* | 49.4 / 20.3 / 13 | 62.9 / 24.2 / 7 | +27% |

  \* With 12-15 stray screen captures running: a bug in the edge watcher left its ffmpeg running after each replay run
  (fixed: the capture now dies with the watcher). Rerun clean, the Lantaana pair moved by 6% and kept its gap.
- **The red blotches in the air** (A0, A3) are absent in A2. They look like the red dust the racers kick up. Without a
  Windows reference it is unclear which is right.
- **Crash risk:** with DXR hidden (`nodxr`) ray tracing is off whatever the game sets, so A2 keeps the campaign crash fix.
- **Nanite on brings the flicker back** (corrected 2026-10-19: it is the player's vehicle missing from about a quarter
  of the frames, not a rare flash; next section). Nanite off was chosen on 2026-10-10 to stop whole-frame flashes, and
  the tests since then all ran with ray tracing live, since the game re-enables it on every map load. With ray tracing
  now truly off (`nodxr`), the vehicle flashes remain; the terrain flash stays fixed by `landscape.RenderNanite=0`. On
  Landspeeder Ace, 40 s recorded, with the AI driving:
  - Nanite off: no frame above 10% of tiles (worst 7.9%).
  - Nanite on: 4 frames above 10%, one above 40%, all of them the landspeeder's body changing for one frame. The
    flash count sees only those single-frame changes; the vehicle is missing for whole stretches between them.
- **The choice was left to the player:** Crait correct and every planet faster, against the vehicle flicker. The
  profile kept Nanite off until the driver change
  ([below](#star-wars-galactic-racer-nanite-on-after-a-driver-change-2026-10-19)).

## STAR WARS: Galactic Racer: a bench held at 18 fps, and the Nanite flicker read backwards (2026-10-19)

**Windows drawing behind the game.** On 2026-10-18 every bench run, including the plain profile that ran about 73 fps
on 10-14, ran at 16-18 fps (frames over 50 ms: 208-236 in 30 s), while games launched from SparkHome's tiles ran well.
- **No thread was busy:** the game thread used 10% of a core, vkd3d's queue thread 23%, the CPU ran at full clock, and
  the GPU was 20-26% busy. Frame times fell on multiples of the TV's refresh (16.7, 33, 50 ... 117 ms), with VSync off
  too: frames waited to be shown.
- **The windows behind the game kept drawing:** SparkHome's kiosk page (Chrome) and Steam's Big Picture, open under it
  and flagged as wanting attention, used about 1.5 cores with Xorg even with no game running (steamwebhelper ~55%,
  under FEX). The game's window was on top, fullscreen, focused, and asked the compositor to step aside.
- **Minimising both** (`tools/xinput.py iconify`) took the same run from 17.8 to 58.4 fps (frames over 50 ms: 233 to 8),
  the rest being the player's VSync at the TV's 60 Hz. SparkHome does the same for its own launches: it minimises its
  kiosk when it hands a tile's game the screen.
- **Fix:** `bench/run.sh` minimises SparkHome's kiosk and Big Picture before every launch and gives the kiosk the screen
  back after the run; measured Galactic Racer runs also turn VSync off (`bIsVSyncEnabled=False`, as `FrameRateLimit=0`
  lifts the cap). The plain profile then ran 104.2 fps (player's Medium settings, DLSS Ultra Performance; 1% low 44,
  5 frames over 50 ms in 30 s).
- **Not the cause:** the patched FEX rebuilt on 2026-10-17 (patch 0004 for Street Fighter 6; the previous build gave the
  same 18 fps), the player's settings changed that evening (the 10-15 settings gave the same 18 fps), Nanite and the AI
  driver (the plain profile gave the same), package updates (none since 10-15), a game update (build 25880680 still).
- **With the TV off** (HDMI disconnected) no game can show a frame: `bench/run.sh` now stops at once with "is the TV
  on?" instead of timing out in the menus minutes later.

**The Nanite flicker is the player's vehicle missing.** Since 2026-10-10 the flash frames were read as hidden meshes
drawn for one frame (the landspeeder's body, the podracer's engines), on the assumption that the chase camera hides
them. Side by side with Nanite off, it is the other way round:
- **Nanite off:** the landspeeder is in every sampled frame of the intro card and the race start (0:00.24, 0:00.77,
  0:01.24) and of the tunnels.
- **Nanite on:** at 0:00.26, 0:00.76, 1.78, 2.26, 2.76, 3.26 and 4.25 only the pilot (a skeletal mesh, not Nanite) and the
  engine glows are drawn over bare sand; the landspeeder is there at 1.27 and 3.78, and at 9.09 and 22.42. The podracer
  recordings kept the engines' shadows; the landspeeder frames checked so far are all in shade. A "flash" is the vehicle
  coming back for a frame, or leaving for one.
- **Measure** (`bodyvis.py` in `$SG_DATA` while this is open): edge density where the chase camera holds the vehicle;
  hand-labelled frames give 9-20 with the vehicle, 2.2-3.4 without, and 4.5-6.4 for the darkest tunnel frames with it,
  so a frame counts as drawn above 5. Landspeeder Ace, AI driving, 40 s: **Nanite off 97.5% drawn, Nanite on 72.2%**,
  with 5-second stretches at 41-56% at the start and 51% mid-race. One 40 s run per setting tells a fix from none.
- **What 39 runs showed (2026-10-19, 08:24-11:25, `$SG_DATA/q1019c.sh` taking arms from `q1019c.arms`).** One 40 s
  AI-driven Landspeeder Ace race per run (Medium, DLSS Performance, 1440p, chase camera), Engine.ini lines unless marked.
  Plain Nanite on drew the vehicle in 71.9, 69.7 and 73.2% of frames; Nanite off 96.3%. In this time trial the player's
  vehicle is the only moving Nanite object.
  - **The one change that helps:** occlusion and frustum culling off together (`r.Nanite.Culling.HZB=0`,
    `r.Nanite.Culling.Frustum=0`, with `r.Nanite.MaxCandidateClusters=33554432`, `MaxVisibleClusters=16777216` and
    `MaxNodes=8388608` so the extra work cannot overflow): 89.6%, and 89.7/90.2% with draw-distance, MinLOD and
    WPO-distance culling off too, at 55 fps instead of about 65. Apart, they do little: occlusion off 77.7%, frustum off
    75.1%, MinLOD and draw distance 78.2%, WPO distance 68.9%, the buffers alone 81.6%. So in a bad frame both tests
    reject the vehicle, yet with nothing culling it is drawn in the right place: the culling sees a wrong box or
    position for it, the rasterizer does not. With culling off about 5% of frames, mostly in the first 10 s, still lose it.
  - **It goes missing part by part:** at the edges of a gap the thin trim and struts are drawn while the big panels are
    not.
  - **Not timing:** a 30 fps cap in vkd3d-proton (`VKD3D_FRAME_RATE=30`, GPU 34% busy) 68.5%; `r.FinishCurrentFrame=1`
    72.6%; one frame of swapchain latency (`VKD3D_SWAPCHAIN_LATENCY_FRAMES=1`) 65.5%. `t.MaxFPS=30` in Engine.ini does
    not apply (the game's frame limit wins).
  - **Not the translation layers, as far as their switches reach:** vkd3d-proton 3.0.1, from before the August barrier,
    clear and copy rewrites, 77.6%; `single_queue` 75.0%; `force_raw_va_cbv` 70.4%; `force_host_cached` 66.5%;
    `VK_KHR_shader_maximal_reconvergence` hidden 71.8%; FEX's strictest memory ordering 80.2%; FEX without the Arm AFP
    float mode (`FEX_HOSTFEATURES=disableafp`) 72.8%.
  - **Not these Unreal paths:** software raster only (`r.Nanite.MinPixelsPerEdgeHW=10000`) 83.2%, and its frames still
    lose the whole body; hardware raster only (`r.Nanite.ComputeRasterization=0`) 70.7%; programmable raster off 66.9%;
    `r.Nanite.TestPrecacheDrawSkipping=1` 73.1% and the other PSO precache lines 77.1%; GPU-scene and material uploads
    with the sparse streaming pool off 70.2%; CPU-side parallel render work serialised 69.2%; dynamic primitives out of
    the scene-culling hierarchy (`r.SceneCulling.TreatInstancedDynamicAsUnCullable=1`) 72.6%; persistent-thread culling
    on 71.9%; view batching, HZB priming and two-pass off 79.7%; a 4x occluded-instance buffer 70.3%; coarser LOD
    (`r.Nanite.MaxPixelsPerEdge=4`) 76.6%; main-view LOD bias off 70.7%; raster sort and depth bucketing off 74.8%.
    Several of these left the frame rate unchanged, so their effect on the GPU is unconfirmed; the game's pak config
    sets no Nanite line that would override them (only `ProjectEnabled`, `VSMInvalidateOnLODDelta=1`,
    `Tessellation=0`, `AllowSkinnedMeshes=0`, so the vehicle is not a Nanite skinned mesh).
  - **One group hung the GPU** 18 s into the race (`Xid 109 ... CTX SWITCH TIMEOUT`): async raster, programmable,
    mesh-shader raster, shader bundles and `FastVisBufferClear=0` together. Programmable raster alone did not.
  - **Vulkan synchronisation validation** (one race, 28.9 fps under the layer) reported one kind of hazard, 10 times
    (its cap): `SYNC-HAZARD-WRITE-AFTER-WRITE`, an image layout transition on one queue after another queue's
    transition of the same image with nothing ordering them, mostly the same image. Which images and queues is not known
    yet. `single_queue` did not bring the vehicle back, so this does not explain it; it is a vkd3d-proton lead of its
    own (log `$SG_DATA/vklayers-val/syncval-0824.log`).
  - **Nobody else reports it** (search 2026-10-19): not on Windows (8 GPUs on 617.14, UE 5.7.4.0), AMD, the Steam Deck,
    or desktop NVIDIA on Linux drivers 595-615. Only this machine has NVIDIA 580.173.02 on GB10 (DGX Spark supports only
    R580), FEX, and the arm64 Vulkan driver behind FEX's thunks. 615.71.09 fixed a Blackwell compiler bug with nested
    divergence (stated for CUDA, reproduced on 580.173.02), and an open-kernel-module "geometry getting culled when it
    shouldn't be" in RE Engine games stopped on 615.71.09
    ([open-gpu-kernel-modules #1043](https://github.com/NVIDIA/open-gpu-kernel-modules/issues/1043)). A driver A/B is
    the next decisive test; R595 and later are not supported on DGX Spark yet.

## STAR WARS: Galactic Racer: Nanite on, after a driver change (2026-10-19)

**The Spark moved to kernel 7.0.0-1019-nvidia with NVIDIA 615.71.09** on 2026-10-19 at 14:31: the driver A/B the
previous section called for. Secure Boot loads only modules Canonical signed, and Canonical signs R615 only for that
kernel: `linux-image-7.0.0-1019-nvidia`, `linux-modules-nvidia-615-open-nvidia-hwe-24.04`, `nvidia-driver-615-open`,
plus NVIDIA's `nvidia-spark-grub-kho` (`kho=off`: without it kexec handover keeps about 9 GiB as CMA memory, which
breaks pinned allocations). It came up on the first boot with display, Vulkan, CUDA and WiFi working. The switch
script and the 580.173.02 packages are in `$SG_DATA/drivers/`.
- **Going back:** install the 580 packages, pin GRUB to the 6.17 entry, reboot, run `system/fex-system.sh ngx`, and put
  the Nanite-off profile back (`$SG_DATA/backups/profile-20261019-nanite-off/`).
- **The x86 copies of the driver must match it** (DLSS's NGX libraries in FEX's RootFS). `steam_start` now runs
  `system/fex-system.sh ngx` first, which installs the loaded driver's version (downloaded once, kept in
  `$SG_DATA/drivers/`). A Steam started before that keeps the old ones (`NVRM: API mismatch: the client
  'steamwebhelper' ... has the version 580.173.02` in the kernel log), and SparkHome starts Steam about 9 s after boot:
  after a driver change, restart Steam once.

**The vehicle flicker is gone.** Landspeeder Ace, AI driving, 40 s recorded, measured as in the previous section:

| Driver | Nanite | Vehicle drawn | Frames above 10% of tiles changed |
|---|---|---|---|
| 580.173.02, kernel 6.17, same day | on, terrain off | 63.5, 78.7, 71.0% | 2, 6, 5 |
| 615.71.09, kernel 7.0 | on, terrain off | 96.8, 96.8, 97.8% | 0, 0, 0 |
| 615.71.09, kernel 7.0 | on, terrain too | 97.9, 97.2% | 0, 0 |

Nanite off drew it in 96.3-97.5% of frames, so on 615 Nanite draws the vehicle as Nanite off does, and the terrain no
longer needs `landscape.RenderNanite=0`. Which of the two changes fixed it is not known: kernel 7.0 also has signed
modules for 580.178.04, the test that would tell.

**Every race measured runs above 70 fps with Nanite on.** AI driving, the player's Medium settings with DLSS
Performance at 2560x1440, 60 s from the race's start, one run each, nothing recording:

| Race | 580: Nanite off | 580: Nanite on, terrain off | 615: Nanite on, terrain off | 615: Nanite on, terrain too |
|---|---:|---:|---:|---:|
| Lantaana, Six-Limbed Fury (podracer) | 39.6 | 69.3 | 74.4 | 77.8 |
| Crait, Hope of the Toong (podracer) | 55.7 | 72.9 | 79.6 | 78.3 |
| Crait mines, Skim Speeder Champion | 44.1 | 76.9 | 81.2 | 85.1 |
| Jakku, Venting Machine (landspeeder) | 72.0 | 78.4 | 80.9 | 88.0 |
| Sentinel, Skim Speeder Ace | 70.3 | 82.8 | 87.4 | 90.5 |
| Ando Prime, Veknoid's Charm (podracer) | 51.7 | 77.2 | not run | not run |

- **615 is 3-9% faster** than 580 with the same settings, and Nanite on the terrain too adds up to 9% more (Crait
  -2%, within a run's spread). Landspeeder Ace, chase camera: 88.3 and 88.2 fps against 82.6 and 82.9.
- **The hitches are unchanged:** 1% lows 32-40 fps, 5-13 frames over 50 ms a minute.
- **Ando Prime was not re-run** after the TV went off mid-queue; on 580 it ran 77.2 with Nanite on.

**The profile has Nanite on since 2026-10-19 16:55** (`r.Nanite=1`; ray tracing stays hidden and the baked lighting
stays). The player's first evening on it was one 6.5-hour session (18:23 to 00:59) with no crash, and the kernel
logged no Xid in the 19 hours after the switch.

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

## DualSense haptics over Bluetooth (CONTROL Resonant, 2026-10-13)

CONTROL Resonant plays its haptics as USB audio through Sony's libScePad (statically linked; Wwise picks its
`AkScePadHapticsSink` or, failing that, `AkScePadRumbleSink`). Over Bluetooth that sound card does not exist, so the game
falls back to triggers only. `controller/dualsense-bt.c` (LD_PRELOAD) shows the Bluetooth pad to Proton as the USB pad,
and `controller/dualsense-bt-haptics.py` provides the stand-in sound card, sending channels 3-4 to the pad as Bluetooth
haptics (report 0x32, SAxense's format). Profile lines: `DUALSENSE_BT_HAPTICS=1`, `DUALSENSE_HAPTICS_GAIN=0.9`.

- **Working (measured by feel and by PipeWire links):** the game pairs the pad with the stand-in by container ID and
  opens two 4-channel streams into it; haptics, rumble and adaptive triggers all reach the pad over Bluetooth.
- **What it took, in the order it went wrong:**
  1. Proton's `winebus.so` is itself `dlopen()`ed, so its libudev is in no global scope: the shim's `dlsym(RTLD_NEXT)`
     returned NULL and calling it crashed winebus's hidraw scan (the game then saw only the SDL/XInput pad). The shim now
     asks the loaded libudev (`dlopen("libudev.so.1", RTLD_NOLOAD)`); its self-test covers that case.
  2. As USB it also needs `HID_PHYS` on interface 3 (winebus names it `...&MI_03`), the USB pad's version, and the
     "USB data/power plugged" status bits in input reports.
  3. **Never send a Bluetooth pad the feature reports a game writes.** libScePad writes feature 0x08 (48 bytes, USB
     setup) as it opens the pad; over Bluetooth the pad answered by dropping its link within 0.3 s, every launch, which
     looked like flat batteries and stopped the game before it reached the sound card. The shim now drops feature writes.
- **Diagnosing:** the shim logs to stderr inside Steam's container (its log file is not writable there), so its lines land
  in the journal under `steam[...]`. Steam's pre-launch "secondary session" runs Proton without launch options and writes
  registry entries for the pad (`BTHENUM\...`) that belong to no game session.
- **Not done:** the controller speaker (channels 1-2) over Bluetooth needs Sony's Bluetooth audio format.

## 32-bit games under FEX (Metal Gear Rising, 2026-10-13)

- **`PROTON_USE_WOW64=1` breaks them:** Proton cannot create the process ("Failed to create process ... 731").
- **The normal 32-bit path reaches the GPU** through the i386 NVIDIA libraries `system/fex-system.sh install_ngx` puts in
  FEX's RootFS: DXVK logs "Found device: NVIDIA GB10".
- **GameSpark's Vulkan layers (MangoHud, vkBasalt) are arm64** and only load in 64-bit games (through FEX's Vulkan
  thunk). `bench/run.sh` looks for 32-bit layers in `$SG_DATA/vklayers32` and has `WINE_FPS=1` meanwhile.
- **32-bit games are CPU-bound on x87:** a 32-bit Windows program returns every float through the x87 FPU, and FEX
  emulates its 80-bit precision in software. `FEX_X87REDUCEDPRECISION=1` (64-bit doubles) took Metal Gear Rising
  from 23.8 to 59.6 fps in the same VR scene at 4K. Its MSAA must then stay off: x2 gave 49.9 fps (lows 35), x8 22.
  WineD3D does not help: inside Steam's container the 32-bit GL thunk engages, yet the frame rate matched DXVK's,
  and Wine's fps trace (`WINEDEBUG=fps`) hangs WineD3D after its first frame.
- **Metal Gear Rising** caps its own resolution list at 1920x1080. Steam006's PC Fix 1.9.3 (installed with the
  `steam_api.dll` loader, not its `d3d9.dll`, so DXVK stays in front) renders 3840x2160. Its zip is WinZip AES:
  Python's zipfile and Info-ZIP cannot open it, Windows' `tar.exe` can. Backup and undo notes:
  `$SG_DATA/backups/235460/MANIFEST-pcfix.txt`.
- **Frame pacing beats raw speed there (2026-10-15):** in the prologue's first fight the game held 57.7 fps (lows
  54.6) with no thread above half a core and the GPU at 32%: the PC Fix's own 60 fps cap (`FPSMode = 1`) fights VSync at
  the TV's 59.94 Hz and loses about 2.5 frames a second. Uncapped (`FPSMode = 2`) with DXVK's limiter at 60
  (`d3d9.maxFrameRate = 60`) the same fight holds 59.9, lowest second 59.9. Neither `FEX_TSOENABLED=0` (56.7) nor
  shadows a step lower (56.0) helped.
- **How it loads mod files:** the game opens a loose file under `GameData/` only as a pair: it looks for `X.dat` on disk
  and then reads `X.dtt` from wherever the `.dat` came from, so a mod that ships only `.dtt` textures never loads
  (watched with inotify: `/tmp/cpkls/opens.py`). `core.dat` at the root (Beyond Ultra) and the `pl/em/wp/ba/ui0205`
  pairs (Better Textures, Raiden Remaster Remake, the animated visor) load. The UI atlas `ui/ui_core` and its
  controller variant `ui/360/ui_core` are never looked up on disk, even with a `.dat` beside them: they come only from
  `data000.cpk`. The Dualshock 3 Interface Mod (Nexus 712, button prompts) therefore needs the archive patched.
- **CRI CPK tools:** `cpkls.py` (list), `cpkx.py` (extract, CRILAYLA included) and `cpkpatch.py` (replace files: data
  appended before the ETOC, TOC rows and header patched in place) in `/tmp/cpkls/` while this note is fresh; copies
  belong in `tools/` once the patched archive is proven in game. The TOC's per-file `CRC` and the header's `TocCrc`
  are not any standard CRC-32 (zlib, BZIP2, MPEG-2, CRC-32C all fail); the patch leaves them as they were.

## 4K (2026-10-13)

The TV (TCL 50S425) offers 3840x2160 at 59.94 Hz only, as YCbCr 4:2:0, and no VRR, so a steady 60 needs a VSync'd
average above 60 with high lows. Frame generation stays off (dynamic mode hangs the GPU on R580; fixed 2x cannot lift a
VSync'd 50 to 60). At 4K the GPU becomes the limit where it was the CPU at 1080p.

| Game | Configuration | Avg fps | 1% low | Verdict |
|---|---|---|---|---|
| CONTROL Resonant | as found: 1440p render (DLSS Quality, transformer) | 35 | | GPU 94% |
| CONTROL Resonant | 1080p render (Performance), transformer, SDF off | 48.1 | 40.5 | fail |
| CONTROL Resonant | 720p render (Ultra Performance), GI/SSR 1, no motion blur | 64.6 | 52.6 | hitches only |
| CONTROL Resonant | **1080p render, older DLSS model (`m_bDLSSLegacy`), GI/SSR 1, no blur** | **64.1** | **51.0** | **pass, applied** |
| Galactic Racer | as found: 2560x1440 + DLSS Performance, scaled by the TV | 60.8 | 26.6 | kept |
| Galactic Racer | 4K output, Ultra Performance, lower GI/reflections/post (A, C) | 56.4-56.5 | 22-25 | slower |
| Divinity: OS2 | 4K, menu scene | 59.9 | 58.1 | pass |

- **The transformer DLSS model costs about 10 fps at 4K output on this GPU** (CONTROL, same render size).
- **Galactic Racer's lows are content hitches** at the same moments at any resolution; judge it on the average.
- **EULAs are per Steam account:** Cyberpunk, Tomb Raider and Witcher 3 had theirs accepted on another account, so
  `bench/run.sh` stops with "Steam wants ...'s EULA accepted" until someone accepts it at the TV.

## The Witcher 3 at 4K: DLSS only through OptiScaler, and a frame rate the render size barely moves (2026-10-15, 2026-10-17)

Every 4K "DLSS" run of The Witcher 3 measured native 4K with TAA: no run mapped `nvngx_dlss.dll` (`modules.txt`), so
DLSS Ultra Performance scored the same as Performance (53.5 vs 53.4 fps, GPU 93%). The game ships Streamline 2.14.1 and
DLSS 310.9.1. With dxvk-nvapi from Proton Experimental 20261008 Streamline loaded its plugins (`sl.common`, `sl.dlss`,
...) but never loaded NGX (`_nvngx.dll`); with 20261014 it does not load them at all. With `DXVK_NVAPI_LOG_LEVEL=info`
the whole run makes only `NvAPI_Initialize`, `NvAPI_SYS_GetDriverAndBranchVersion`, display lookups and three function
IDs dxvk-nvapi does not know (`0xad298d3f`, `0x593e8644`, `0x33c7358c`); it never enumerates GPUs, so
`DXVK_NVAPI_GPU_ARCH=AD100` changes nothing. CONTROL's DLSS, which calls NGX directly, works on the same machine.
Candidates: Streamline's development build (it logs why), or OptiScaler feeding the game's XeSS/FSR inputs to NGX.
XeSS and FSR load and work.

**OptiScaler 0.9.4 makes DLSS run (2026-10-17).** Installed as `bin/x64_dx12/dxgi.dll` with
`WINEDLLOVERRIDES=...;dxgi=n,b` (`MANIFEST-optiscaler.txt` in that folder lists what it changed; no game file was
replaced), with `Dx12Upscaler=dlss` it takes the game's XeSS calls and runs DLSS itself: its log shows NGX initialising
from `system32/_nvngx.dll` (result 1) and `DLSS v310.9.1` creating its feature; the game's FSR inputs are left alone
(`[Inputs]` FSR2/FSR3/FFX off). DLSS is expensive on GB10 at a 4K output, all the more from 1440p up.

Measured with candidate C's detail (the High preset's shadows, terrain, foliage, grass, LOD, crowd, GTAO), 4K output,
the player's save in Novigrad, 60 s standing (`bench/run.sh witcher3`):

| Upscaler (render size) | HairWorks | Avg fps | 1% low |
|---|---|---:|---:|
| none: the "DLSS" runs above (2160p, TAA) | Geralt | 53.4 | 38.6 |
| FSR Ultra Performance (1280x720) | Geralt | 55.9 | 38.8 |
| FSR Performance (1920x1080) | Geralt | 55.7 | 37.5 |
| FSR Quality (2560x1440) | Geralt | 56.1 | 38.5 |
| FSR Quality | off | **59.1** | 40.2 |
| FSR Quality, shadows 1024, less grass, foliage and crowd | off | 59.9 | 39.0 |
| FSR Quality, the game held to the X925 cores (`PROTON_CPU_TOPOLOGY`) | off | 56.3 | 27.7 |
| XeSS Balanced (its DP4a path) | Geralt | 48.0 | 34.4 |
| DLSS Performance (1920x1080), CNN model (preset E) | off | **55.4** | 36.9 |
| DLSS Performance, transformer model (preset K) | off | 49.6 | 34.1 |
| DLSS Quality (2560x1440), preset E / DLSS's default | off | 39.2 / 37.1 | 26.6 / 28.4 |
| DLAA (2160p) | off | 22.4 | 16.1 |

- **The render size barely matters:** from 720p to 2160p the game stays at 53-56 fps, the GPU reads ~93% busy and no
  thread is saturated (MainThread ~60%, RenderThread ~50% of a core, 16 job workers ~10% each). HairWorks costs ~3 fps;
  lowering shadows, grass, foliage and crowd buys almost nothing more. Holding the game to the fast cores loses: its job
  workers want all 20.
- **The player's settings (2026-10-17):** candidate D (`profiles/settings/292030/apply.sh D`: FSR Quality, HairWorks
  off, VSync on), the closest to 60. Candidate E is the DLSS choice (XeSS Performance in the game's menu, which
  OptiScaler runs as DLSS Performance with the CNN model: `RenderPresetPerformance=5`).
- **Bench harness:** one DLSS run ended on "You Are Dead": the menu keys (`space`) reached the game after the save had
  loaded, and Geralt died. No save was written (the bench never saves); the run just produced no result.

## Street Fighter 6: Denuvo, the window and the controller (2026-10-15, 2026-10-17)

RE Engine, DirectX 12 through VKD3D-Proton, Denuvo. It quit about a minute after every launch (also for the player).

- **Stock FEX:** about 1.5 s in, Denuvo's code faults (an access violation inside the protector's `.udata` section,
  with `rbp` holding a tagged value, `0x01000000_1dc66ef2`); no vectored handler takes it, Wine's unwinder reads
  `[rbp+8]` and faults again, recursively, until "stack overflow" ends the process. The FEX wiki lists the game as
  Unplayable (Denuvo).
- **Galactic Racer's recipe** (`FEX_BINARY=gamespark FEX_NEEDSSECCOMP=1 FEX_GSHWBP=1` on the frozen
  `GameSpark-Proton-Exp-20261008`) gets further: Denuvo raises a hard error and exits with `0xDEADC0DE` 3 s in.
  Wine only stubs `NtRaiseHardError`, so the message is invisible; frozen at that call (`SIGSTOP` when the Proton log
  shows it) the process held it on the stack: `Error at hooking API "NtProtectVirtualMemory"` and a dump of Wine's
  syscall stub. `WINEDEBUG=+virtual` shows the steps: a trampoline page allocated just above ntdll, the stub's page
  made `PAGE_EXECUTE_WRITECOPY`, protection restored, error.
- **Why the hook failed (found 2026-10-17):** Denuvo writes its hook with kernelbase's `WriteProcessMemory`, and Wine
  performs `NtWriteVirtualMemory` in wineserver with `process_vm_writev`. Under FEX's default page tracking (mtrack)
  the page was write-protected again by then, because FEX had translated the stub's return path on it right after the
  mprotect, so the write failed with `EFAULT`: `ERROR_PARTIAL_COPY`, the hard error, `0xDEADC0DE`. Stock FEX 2610 does
  the same; `adhoc/smcwx-20261017/smc_hook_check.c` reproduces it without the game.
- **`FEX_SMCCHECKS=full` booted it**, as it never write-protects, at a cost: ~3.5 min to the title and, in Training
  Mode at 4K (Luke vs Luke), 48.6 fps idle and 48.3 moving (lows 45.8) with the GPU 58% busy: CPU-bound with no thread
  saturated, because every instruction of the program checked its own bytes.
- **GameSpark's FEX patch 0004 (`FEX_GSSMCWX=1`, 2026-10-17)** keeps mtrack, but code pages the game makes writable
  stay unprotected and check their code before it runs (in this game only the hooked ntdll page, briefly). With it the
  title shows 54-55 s after the game starts, and Training Mode at 4K holds 59.9 fps idle and moving (lowest 59.3; VSync
  at the TV's 60 Hz), the GPU 57% busy, about 3 cores in use.
- **First boot** asks to accept the Terms of Service and offers shader warming (~25 min here, then
  `ShaderWarmed=TRUE` in the game folder's `config.ini`); SF6 also writes `shader.cache2` on a clean exit.
- **Borderless and FullScreen mode stall while booting:** the game sits on its health warning (for 10-16 min in five
  of six launches), then on a still frame, until its window is activated again. Switching to another window and back
  (EWMH activation) moves it on each time; re-activating the game window alone, plain X focus changes,
  `_NET_WM_BYPASS_COMPOSITOR=2` and `UseTakeFocus=N` in the X11 driver do not. `WindowMode=Normal` with
  `FullScreenDisplayMode=26` (3840x2160) boots by itself, but Wine draws a title bar over the top ~30 px. The player
  chose Borderless (2026-10-17): `BOOT_NUDGE=PRESS ANY BUTTON` in the profile starts `tools/boot-nudge.py`, which makes
  that switch through a 1-pixel window of its own while the screen stands still, until the title shows (two nudges; the
  title 55 s after the game starts, as in Normal mode). The game writes `config.ini` with CRLF line endings.
- **Graphics (2026-10-17):** with the CPU no longer the limit, lighting, shadows, meshes and shaders at High, bloom on,
  SSR as the game first set it and 16x anisotropic filtering hold the same 59.9 fps in Training Mode at 4K (lowest
  59.5, GPU 67%). The player's earlier settings: `$SG_DATA/backups/1364780/config.ini.player-20261017`.
- **Controllers (fixed 2026-10-17):** the developer opts the game into Steam Input for every controller type (Steam's
  `logs/controller.txt`: "Opted-in Controller Mask for AppId 1364780: ffff"), so Steam turns the DualSense into its own
  virtual Xbox pad for the game and Proton hides the real pad. That virtual pad gave the game nothing: no pad worked,
  only the keyboard and the DualSense's touchpad (a mouse in X). Forcing Steam Input off for the game
  (`UseSteamControllerConfig` 0 in `localconfig.vdf`, written while Steam was closed; Steam's UI uses 0 = off,
  1 = default, 2 = on) changed nothing: Steam kept the mask and the virtual pad. With the real pad also visible as raw
  HID the game still ignored it. What works: Proton shows the game the real DualSense as an XInput pad and hides Steam's
  virtual pads (`PROTON_DISABLE_HIDRAW=0x054c/0x0ce6,0x054c/0x0df2`, `SDL_GAMECONTROLLER_IGNORE_DEVICES=0x28de/0x11ff`,
  `SteamVirtualGamepadInfo=/dev/null` in `profiles/launch/1364780.env`). Wine also opened a second DualSense paired
  while the game ran (`controller/pair.sh DualSense`).
- **Online:** after the title it requests an encrypted app ticket through Steam and signs in to Capcom's servers
  (HTTPS to Google Cloud); the News panel and the player's CFN profile show.

## Hades II: 4K at 60 with room to spare, and NVIDIA's busy-wait (2026-10-20)

Supergiant's own engine on The Forge (DirectX 12 only, through VKD3D-Proton on Proton Experimental; Lua 5.2 scripts,
SDL2 input). Installed 2026-10-20 (10.6 GB); the player's Steam Cloud save (Night 96, backed up first to
`$SG_DATA/backups/1145350/`) loads and was not changed by the tests.

- **Frame rate:** at 3840x2160 with Graphics Quality High (the highest) and VSync, 59.9 fps at the main menu, in the
  Crossroads and through two minutes of non-stop attacks and casts in the Training Grounds (lowest 59.4), with the GPU
  16-31% busy.
- **Display:** the game starts windowed, under Wine's title bar. Options, Display, Borderless (`NoBorder = true` in
  `Saved Games/Hades II/GlobalSettingsWin.sjson`) fills the screen without a mode change.
- **Controllers:** Steam Input is not forced for it (Opted-in Controller Mask 1000), so pads reach the game directly.
- **Driving its menus:** XTest mouse clicks do not register (press and release fall within one frame), but hovering an
  item and pressing Return or Space does. The save-slot screen has a delete icon right below the slot: hover the
  slot, then Return. Pause, Quit returns to the main menu ("Quit for Now?"), whose Quit closes the game.
- **NVIDIA's driver busy-waits for each present.** VKD3D-Proton's `vkd3d-swapchain` thread used a whole core (99%)
  in each DirectX 12 game looked at (Street Fighter 6 too); `perf` puts the time in `libnvidia-glcore.so.615.71.09`
  and libc's atomics (spin locks). `__GL_YIELD=USLEEP`, NVIDIA's documented knob for how its OpenGL driver waits, also
  reaches this code: the thread drops to 3% of a core and the Hades II process from 184% to 62%, at the same 59.9 fps
  (main menu, 20 s each way). It is in Hades II's profile; worth measuring in the CPU-bound DirectX 12 games
  (Galactic Racer, The Witcher 3).

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
- **skate.**: EA Javelin anti-cheat does not support Proton, and the first start wants an EA sign-in.
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

## Crimson Desert: Denuvo passes, the intro video never shows (2026-10-27)

Pearl Abyss 2026, BlackSpace Engine, DirectX 12 through VKD3D-Proton, Denuvo (5 PCs a day). Installed 2026-10-27
(152 GB, build 25477059). Profile: `profiles/launch/3321460.env`.

- **Denuvo:** on the first launch, with Street Fighter 6's recipe (`FEX_BINARY=gamespark FEX_NEEDSSECCOMP=1 FEX_GSHWBP=1
  FEX_GSSMCWX=1`, `GameSpark-Proton-Exp-20261008`, the FEX Steam with the native Vulkan driver), the game opens its own
  4K window, shows its loading emblem, compiles shaders (~5 cores, GPU ~8%, about 5 min) and shows the Pearl Abyss logo.
  No hard error, no `0xDEADC0DE`.
- **Then it waits on the logo forever** (GPU 47-95%, ~2.4 cores, no disk reads; keys do nothing). The intro video is
  decoded through Media Foundation with a D3D11 device (DXVK) and handed to the D3D12 renderer through a shared NT
  handle; that handoff fails about 30 times a second: `fixme:d3dkmt:NtGdiDdDDIOpenResourceFromNtHandle ... semi-stub!`
  then DXVK `DxvkMemoryAllocator::createImageResource: Failed to open shared NT handle`. Proton also logs `Failed to find
  H264 bitstream filter` and writes the `h264-used` tag (the placeholder path for videos it has no transcode for; Steam
  had downloaded `transcoded_video.foz`, 1.47 GB, with the game).
- **Ruled out:** Proton Hotfix 20261007 (Valve's default for this game) fails the same way. `WINEDLLOVERRIDES=mfplat=d`
  stops the game at once (`MFPlat.DLL` is a static import). GE-Proton 11-11 has no seccomp syscall trap, so it cannot
  run Denuvo here. The video files are inside the packed archives (`0000`-`0035`), so they cannot be renamed away.
- **Next:** reproduce a D3D12 texture shared into D3D11 (`CreateSharedHandle` / `OpenSharedResource1`) outside the game,
  to find which layer fails on this stack (Wine's d3dkmt shared resources, vkd3d-proton's export, DXVK's import, or the
  thunked NVIDIA driver's external memory); then fix or work around it there.
- **Controllers (not tested yet):** the game reads a DualSense only over USB; the profile has Street Fighter 6's XInput
  fix. Steam showed "Grab a controller" and "plug in your DualSense" notices on the first launch.
- Logs: `$SG_DATA/logs/steam-3321460-{first-launch,hotfix,nomfplat}.log.gz`.
