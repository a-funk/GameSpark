# Methodology

## Benchmark runs (`bench/run.sh`)

1. Refuses to start if another run or the game is active (`flock` on `/tmp/gamespark-bench.lock`).
2. Optionally holds the lock files in `QUIET_LOCKS` so cron jobs skip their cycle during the run.
3. Starts `bench/telemetry.py` (1 Hz: GPU utilization, power, graphics clock, temperature from `nvidia-smi`;
   CPU utilization overall, on the fast cores and on the rest, from `/proc/stat`).
4. Sends `-applaunch <appid> <args>` through Steam's command pipe. The snap launcher drops command-line
   arguments, and Steam silently ignores pipe commands while it is loading, so the runner waits for
   `Game process added : AppID <appid>` in Steam's console log and resends up to four times.
5. Waits for the game process to exit and copies the game's own benchmark output (adapter `game_collect`).
6. `bench/ingest.py` builds the run record.

## Metrics

- **Average fps** comes from the game's per-frame log (frames / summed frame time), not the game's own
  average, so every game is measured the same way. The game's figure is kept as `reported_avg_fps`.
- **1% low** is the fps at the 99th-percentile frame time (nearest rank).
- **Frame generation**: Cyberpunk logs the rendered frame time in column 1 and the displayed frame time in the
  active generator's column. Records carry both (`avg_fps` displayed, `rendered_fps` rendered).
- **Telemetry means** cover only the benchmark window: from the result file's write time minus the benchmark
  length, to the write time.

## Repeatability

Two identical runs (B1, E1) differed by 2.2%. Treat differences under ~3% as noise unless repeated.
Steam downloads, shader pre-compilation and cron jobs all compete for the CPU; do not benchmark during them.

## Autotuning (`bench/tune.py`)

- The search space is the scheduler (`default`, `bpfland`) times the values in the adapter's `TUNE_KNOBS`
  (e.g. `ROTTR_API=dx11,dx12`). The first value of each knob is the default configuration.
- Adapter knobs are the outer loop. Each new combination starts with one discarded warm-up run, because the
  first run after a graphics API or driver change rebuilds shader caches (DX12: 118 then 126 fps).
- Each configuration then runs `--reps` times (default 2). The tuner pauses the governor and sets the scheduler
  itself; runs that recorded a different scheduler are discarded.
- A challenger replaces the default only if its mean is more than `--noise` (default 2%) faster. Single runs
  vary by up to ~3%; the mean of two varies by about 2%.
- The winner is written to `profiles/GAME.conf` with every configuration's mean as comments, and applied: the
  adapter's `game_prepare` runs with the winning knobs (e.g. writes the registry), and the governor applies
  `SCHED` whenever the game runs.
- A profile is specific to the Steam setup it was tuned on (`GAMESPARK_STEAM`, recorded in the header).

## CPU profiles (`profile/profile.sh`)

- perf samples every core at 499 Hz for 45 s, starting 50 s after the game process appears (the benchmark
  scene is running by then).
- GB10 exposes two CPU PMUs (X925 and A725), so `perf report` prints one section per PMU; `analyze.py` works on
  `perf script` output and counts every sample once.
- FEX names its code region `[anon:FEXMemJIT]`, which perf does not match against `/tmp/perf-<pid>.map`.
  `analyze.py` resolves sample addresses against those maps itself (binary search per process).
- FEX only writes maps when `FEX_LIBRARYJITNAMING=1` reaches the game process, which takes the Steam launch
  options; the `LibraryJITNaming` key in the snap's `Config.json` does not. The snap's private `/tmp` is
  `/tmp/snap-private-tmp/snap.steam/tmp` on the host.
- The game executable's code has no label (Wine maps it without a file name), so unlabeled translated samples
  in game threads are attributed to the game, marked "inferred".
- Labeling costs nothing measurable (58.3 and 59.6 fps with it, 57.5-59.3 without).
