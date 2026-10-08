#!/bin/bash
# Steam launch-option wrapper that swaps the executable Steam starts, e.g. to skip a game's own launcher (the
# Rockstar and Larian launchers are embedded browsers that render poorly under Proton on this machine).
#   launch options:  /path/to/gamespark/tools/launch-swap.sh FROM TO %command%
# Every argument ending in FROM gets that suffix replaced by TO. No quotes or backslashes are needed in the launch
# options, which Steam stores in a VDF file. Example (Divinity: Original Sin 2, skip the Larian launcher):
#   tools/steam-config.sh launch-options 435150 "$PWD/tools/launch-swap.sh /bin/SupportTool.exe /DefEd/bin/EoCApp.exe %command%"
from=${1:?usage: launch-swap.sh FROM TO COMMAND...} to=${2:?usage: launch-swap.sh FROM TO COMMAND...}; shift 2
args=()
for a in "$@"; do
  [[ $a == *"$from" ]] && a=${a%"$from"}$to
  args+=("$a")
done
exec "${args[@]}"
