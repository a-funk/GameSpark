#!/bin/bash
# Regression gate: re-run every tuned game of the running Steam setup at its profile settings and compare with the
# mean the profile recorded (bench/tune.py --check). Run it after changing FEX, drivers, Proton or the scheduler;
# a change that helps one game must not quietly cost another.
# Usage: bench/matrix.sh [--tolerance PCT]      (Steam running; takes about 5 minutes per game)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
steam_running || die "Steam is not running (tools/steam-console.sh starts it)"
fail=0
for conf in "$ROOT"/profiles/"$GAMESPARK_STEAM"/*.conf; do
  [ -e "$conf" ] || continue
  grep -q "<- chosen" "$conf" || { echo "skipped    $(basename "$conf" .conf): hand-written profile"; continue; }
  out=$(python3 -I "$ROOT/bench/tune.py" "$(basename "$conf" .conf)" --check "$@"); rc=$?
  grep -E "^(ok|REGRESSION|FAILED) " <<<"$out" || echo "$out" | tail -3
  [ $rc = 0 ] || fail=1
done
exit $fail
