#!/bin/bash
# Steam launch options for GameSpark-managed games (set once per game; Steam must be restarted to change them):
#   /path/to/gamespark/tools/launch.sh %command%
# Every launch then applies, without touching Steam's config:
#   profiles/launch/<appid>.env   the game's own settings (in this repo), e.g. PROTON_DISABLE_HIDRAW=...,
#                                 SWAP_FROM / SWAP_TO to start a different executable (skip a launcher), or
#                                 EXTRA_ARGS=... appended to the game's command line (split on spaces)
#   $SG_DATA/launch/run.env       settings for every game while a benchmark run is active (bench/run.sh writes and
#                                 removes it), e.g. MangoHud frame-time logging
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
# shellcheck disable=SC2206  # EXTRA_ARGS is a space-separated list by design
[ -n "${EXTRA_ARGS:-}" ] && args+=($EXTRA_ARGS)
if [ ${#inner[@]} -gt 0 ]; then   # before the Proton script, i.e. inside the container
  for i in "${!args[@]}"; do
    [[ ${args[$i]} == */proton ]] && { args=("${args[@]:0:i}" env "${inner[@]}" "${args[@]:i}"); break; }
  done
fi
mkdir -p "$D" && echo "$(date '+%F %T') app $app applied: ${applied[*]:-none}${SWAP_TO:+ (exe -> $SWAP_TO)}${inner[*]:+ (in container: ${inner[*]})}${EXTRA_ARGS:+ (args: $EXTRA_ARGS)}" >> "$D/launches.log"
exec "${args[@]}"
