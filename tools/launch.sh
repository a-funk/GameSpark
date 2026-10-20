#!/bin/bash
# Steam launch options for GameSpark-managed games (set once per game; Steam must be restarted to change them):
#   /path/to/gamespark/tools/launch.sh %command%
# Every launch then applies, without touching Steam's config:
#   profiles/launch/<appid>.env   the game's own settings (in this repo), e.g. PROTON_DISABLE_HIDRAW=...,
#                                 SWAP_FROM / SWAP_TO to start a different executable (skip a launcher), or
#                                 EXTRA_ARGS=... appended to the game's command line (split on spaces), or
#                                 TASKSET=CPUS to start the whole launch chain on those CPUs (taskset -c), so
#                                 processes Wine does not place itself, wineserver above all, stay on the game's cores,
#                                 PROTON_DIR=DIR to launch DIR/proton instead of the game's Proton (run.env: try
#                                 a copy with other DLLs for one run), or
#                                 BOOT_NUDGE=TEXT for games that stall while booting until their window is
#                                 activated again (tools/boot-nudge.py, until TEXT shows on screen), or
#                                 FEX_BINARY=gamespark to run the game under GameSpark's patched FEX build
#                                 (system/fex-patched.sh; FEX_BINARY=/path/to/FEX for any other build). If that
#                                 build is missing the game is not started: its FEX_* settings need it.
#                                 Its "# summary: ..." line says in one line what the profile does, for front
#                                 ends (SparkHome shows it on the game's tile).
#   profiles/launch/<appid>.Engine.ini  an Unreal Engine game's Engine.ini, written into its Wine prefix before every
#                                 launch (with UE_PROJECT=<folder under AppData/Local> in the .env)
#   $SG_DATA/launch/run.env       settings for every game while a benchmark run is active (bench/run.sh writes and
#                                 removes it), e.g. MangoHud frame-time logging
#   $SG_DATA/launch/run.Engine.ini  Engine.ini lines for that run (bench/run.sh ENGINE_INI=...), over the profile's
# Both are KEY=VALUE lines (no quotes needed; # comments allowed). A CONTAINER_ prefix sets the variable inside Steam's
# container instead (inserted as "env KEY=VALUE" before Proton): pressure-vessel replaces the Vulkan layer variables
# (VK_IMPLICIT_LAYER_PATH, VK_ADD_IMPLICIT_LAYER_PATH, ...) on the way in. What was applied is appended to
# $SG_DATA/launch/launches.log.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SG_DATA=${SG_DATA:-$HOME/.local/share/gamespark}
D=$SG_DATA/launch
app=${SteamAppId:-${SteamGameId:-0}}
applied=() inner=()
for f in "$ROOT/profiles/launch/$app.env" "$D/run.env"; do
  [ -f "$f" ] || continue
  while IFS= read -r line; do
    [[ $line =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    if [[ $line == CONTAINER_* ]]; then inner+=("${line#CONTAINER_}"); else export "${line?}"; fi
  done < "$f"
  applied+=("$(basename "$f")")
done
args=("$@")
if [ -n "${SWAP_FROM:-}" ] && [ -n "${SWAP_TO:-}" ]; then
  for i in "${!args[@]}"; do [[ ${args[$i]} == *"$SWAP_FROM" ]] && args[i]=${args[$i]%"$SWAP_FROM"}$SWAP_TO; done
fi
# PROTON_DIR=DIR: this launch runs DIR/proton instead of the Proton Steam picked, e.g. a copy of the game's Proton with
# other vkd3d-proton DLLs (Proton copies its DLLs into the prefix at every launch, so the next launch puts its own back).
if [ -n "${PROTON_DIR:-}" ]; then
  for i in "${!args[@]}"; do
    [[ ${args[$i]} == */proton ]] && { args[i]=$PROTON_DIR/proton; applied+=("Proton $PROTON_DIR"); break; }
  done
fi
# shellcheck disable=SC2206  # EXTRA_ARGS is a space-separated list by design
[ -n "${EXTRA_ARGS:-}" ] && args+=($EXTRA_ARGS)
if [ ${#inner[@]} -gt 0 ]; then   # before the Proton script, i.e. inside the container
  for i in "${!args[@]}"; do
    [[ ${args[$i]} == */proton ]] && { args=("${args[@]:0:i}" env "${inner[@]}" "${args[@]:i}"); break; }
  done
fi
# Under the FEX Steam every x86 child re-executes the FEX binary it was started with, so starting the launch chain
# with another FEX moves the whole game (Proton, wineserver, the game) onto it and leaves Steam alone.
fexbin=${FEX_BINARY:-} warn=
if [ "$fexbin" = gamespark ]; then
  fexbin=$SG_DATA/fex/current/bin/FEX
  # It talks to the system FEXServer and thunks: a package update since the install needs a rebuild.
  [ "$(stat -Lc '%s %Y' /usr/bin/FEXServer 2>/dev/null)" = "$(cat "$SG_DATA/fex/current/system-fex" 2>/dev/null)" ] ||
    warn=" WARNING: the system FEX package changed since the patched build was installed; run system/fex-patched.sh install"
fi
if [ -n "$fexbin" ]; then
  if [ -x "$fexbin" ]; then args=("$fexbin" "${args[@]}"); else warn=" not launched: run system/fex-patched.sh install"; fexbin="$fexbin (missing)"; fi
fi
# FEX_NEEDSSECCOMP=1 games (Denuvo's direct NT syscalls) rely on Proton's seccomp syscall trap. Proton builds that
# trap with Syscall User Dispatch instead (bleeding-edge from 2026-10-14) would let those syscalls through, and this
# kernel has no SUD: refuse to start rather than fail inside Denuvo. Pin such a game to a frozen Proton.
noseccomp=
if [ "${FEX_NEEDSSECCOMP:-}" = 1 ]; then
  for a in "${args[@]}"; do
    [[ $a == */proton ]] || continue
    grep -qs "Installing seccomp filters" "${a%/proton}/files/lib/wine/x86_64-unix/ntdll.so" ||
      { noseccomp=1; warn+=" not launched: ${a%/proton} has no seccomp syscall trap (FEX_NEEDSSECCOMP needs it)"; }
    break
  done
fi
# PROTON_CPU_TOPOLOGY places the game's Windows processes; wineserver (a Unix process, ~15k wakeups/s for Galactic
# Racer) keeps the mask it starts with, which is all cores, and ran on the slow cores. An affinity set here is inherited
# by the whole chain.
[ -n "${TASKSET:-}" ] && args=(taskset -c "$TASKSET" "${args[@]}") && applied+=("taskset $TASKSET")
# Unreal Engine games: profiles/launch/<appid>.Engine.ini replaces the game's Saved/Config/Windows/Engine.ini in the
# Wine prefix on every launch (UE_PROJECT in the .env names its folder under AppData/Local). A one-time copy is not
# enough: Galactic Racer deletes the file after reading it at startup.
ini=$ROOT/profiles/launch/$app.Engine.ini
if [ -f "$ini" ]; then
  cfg=${STEAM_COMPAT_DATA_PATH:-}/pfx/drive_c/users/steamuser/AppData/Local/${UE_PROJECT:-}/Saved/Config/Windows
  # A benchmark run's $D/run.Engine.ini (bench/run.sh ENGINE_INI=...) replaces the profile's lines key by key and
  # adds its own at the end ([SystemSettings] is the profile's last section).
  run_ini=$D/run.Engine.ini; [ -f "$run_ini" ] || run_ini=/dev/null
  if [ -n "${UE_PROJECT:-}" ] && [ -n "${STEAM_COMPAT_DATA_PATH:-}" ] && mkdir -p "$cfg" &&
     { awk -F= 'FILENAME == ARGV[1] { if (/^[A-Za-z]/) over[$1]; next } !($1 in over)' "$run_ini" "$ini"
       grep -E '^[A-Za-z]' "$run_ini" || :; } > "$cfg/Engine.ini"; then
    applied+=("$(basename "$ini")")
    [ "$run_ini" = /dev/null ] || applied+=("run.Engine.ini ($(grep -E '^[A-Za-z]' "$run_ini" | xargs))")
  else
    warn+=" WARNING: $(basename "$ini") not applied (needs UE_PROJECT and Steam's STEAM_COMPAT_DATA_PATH)"
  fi
fi
# DualSense haptics over Bluetooth (controller/dualsense-bt.sh): DUALSENSE_BT_HAPTICS=1, with the pad on Bluetooth,
# starts a stand-in for its USB sound card until this launch ends and shows the pad to Proton as a USB one
# (LD_PRELOAD), so games that play haptics as USB audio pair the two. Off with the pad on USB (works natively).
if [ "${DUALSENSE_BT_HAPTICS:-}" = 1 ]; then
  if dsbt=$("$ROOT/controller/dualsense-bt.sh" start $$); then
    export LD_PRELOAD="$dsbt${LD_PRELOAD:+:$LD_PRELOAD}"
    export DUALSENSE_BT_LOG="${dsbt%/*}/shim.log"   # what the library changed (dualsense-bt.sh status)
    applied+=("DualSense Bluetooth haptics")
  else
    applied+=("DualSense Bluetooth haptics off: $dsbt")
  fi
fi
# Games that stall while booting until their window is activated again (Street Fighter 6 in Borderless mode under
# Wine): BOOT_NUDGE=TEXT starts tools/boot-nudge.py, which switches focus to a 1-pixel window and back while the
# screen stands still, until TEXT shows (the title's "PRESS ANY BUTTON"), 5 minutes pass or this launch ends.
if [ -n "${BOOT_NUDGE:-}" ]; then
  env -u LD_PRELOAD setsid python3 -I "$ROOT/tools/boot-nudge.py" "$app" "$BOOT_NUDGE" $$ >> "$D/boot-nudge.log" 2>&1 < /dev/null &
  applied+=("boot nudge until \"$BOOT_NUDGE\"")
fi
[ -n "$warn" ] && echo "launch.sh:$warn" >&2
mkdir -p "$D" && echo "$(date '+%F %T') app $app applied: ${applied[*]:-none}${SWAP_TO:+ (exe -> $SWAP_TO)}${inner[*]:+ (in container: ${inner[*]})}${EXTRA_ARGS:+ (args: $EXTRA_ARGS)}${fexbin:+ (FEX: $fexbin)}$warn" >> "$D/launches.log"
# Fail closed: the game's FEX_* settings assume that build (stock FEX with FEX_NEEDSSECCOMP=1 loops on trapped syscalls).
[[ $fexbin == *" (missing)" ]] && exit 1
[ -n "$noseccomp" ] && exit 1
exec "${args[@]}"
