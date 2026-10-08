#!/bin/bash
# Screenshot the TV. Usage: tools/shot.sh [OUT.png]   (default: $SG_DATA/shots/<time>.png); prints the path.
# Steam toasts and the friends list can appear in captures: check before sharing.
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
F=${1:-$SG_DATA/shots/$(date +%Y%m%dT%H%M%S).png}; mkdir -p "$(dirname "$F")"
gnome-screenshot -f "$F" 2>/dev/null && echo "$F"
