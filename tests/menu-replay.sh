#!/bin/bash
# Replay an adapter's menu steps against the screenshots a real run saved, sending no input: checks that every
# OCR pattern still matches its screen, and that a wrong screen is refused. Needs OCR (tesseract or Docker).
# Usage: tests/menu-replay.sh RUN_DIR GAME      e.g. ~/.local/share/gamespark/runs/<...>-rdr2-dx12-2 rdr2
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
RUN=${1:?run dir}; GAME=${2:?game}
# shellcheck source=/dev/null
. "$ROOT/bench/games/$GAME.sh"
T=$(mktemp -d)
cp "$RUN"/*.png "$T/"
sleep 600 & G=$!; trap 'kill $G 2>/dev/null; rm -rf "$T"' EXIT   # stands in for the game process
MENU_REPLAY=1 game_drive "$T" $G > "$T/log" 2>&1 || { cat "$T/log"; die "replay failed on the saved screens"; }
grep "would send" "$T/log"
# A wrong screen must stop the run: show each later step the first screen instead.
first=$(ls -tr "$RUN"/*.png | head -1)
for f in "$T"/*.png; do [ "$f" = "$T/$(basename "$first")" ] || cp "$first" "$f"; done
MENU_REPLAY=1 game_drive "$T" $G > "$T/log" 2>&1 && { cat "$T/log"; die "replay accepted the wrong screens"; }
echo "ok   $GAME menu replay ($(basename "$RUN")): steps match, wrong screens refused"
