#!/bin/bash
# Offline checks: shell syntax, Python self-tests, and shellcheck when installed. Runs anywhere (no Spark needed).
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); cd "$ROOT" || exit 1
fail=0
mapfile -t SH < <(git ls-files '*.sh' 2>/dev/null)
[ ${#SH[@]} -gt 0 ] || mapfile -t SH < <(find . -name '*.sh' -not -path './.git/*')
for f in "${SH[@]}"; do
  bash -n "$f" || { echo "syntax: $f"; fail=1; }
done
for t in bench/ingest.py bench/tune.py profile/analyze.py tools/steamcfg.py tools/winereg.py tools/gamepad.py; do
  out=$(python3 -I "$t" --selftest 2>&1) && echo "ok   $t" || { echo "FAIL $t"; echo "$out"; fail=1; }
done
for f in bench/telemetry.py bench/cyberpunk2077_settings.py controller/xbox-watch.py controller/evdev32_check.py tools/xinput.py; do
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" || { echo "parse: $f"; fail=1; }
done
# launch.sh on a stand-in game: profile variables reach the command, the Engine.ini lands in the prefix
t=$(mktemp -d); mkdir -p "$t/tools" "$t/profiles/launch"; cp tools/launch.sh "$t/tools/"
printf 'UE_PROJECT=TestGame\nGS_TEST=ok\n' > "$t/profiles/launch/999.env"
printf '[SystemSettings]\nr.Test=1\n' > "$t/profiles/launch/999.Engine.ini"
# shellcheck disable=SC2016  # $GS_TEST is for the inner shell
out=$(SteamAppId=999 STEAM_COMPAT_DATA_PATH="$t/compat" SG_DATA="$t/data" bash "$t/tools/launch.sh" bash -c 'echo "$GS_TEST"')
if [ "$out" = ok ] && cmp -s "$t/profiles/launch/999.Engine.ini" \
     "$t/compat/pfx/drive_c/users/steamuser/AppData/Local/TestGame/Saved/Config/Windows/Engine.ini"; then
  echo "ok   launch.sh"
else
  echo "FAIL launch.sh (output: $out)"; fail=1
fi
rm -rf "$t"
if command -v x86_64-w64-mingw32-gcc >/dev/null; then
  t=${TMPDIR:-/tmp}/gamespark-shim-test
  x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -shared -o "$t.dll" shim/shim.c shim/powrprof.def -lpsapi \
    && x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -mwindows -o "$t.exe" shim/igcs_cost.c -lwininet -liphlpapi \
    && x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -mwindows -o "$t-check.exe" shim/shim_check.c -lwininet -lpowrprof \
    && echo "ok   shim" || fail=1
  for c in faultprobe hwbp_check syscall_check; do
    x86_64-w64-mingw32-gcc -Wall -Wextra -Werror -mwindows -o "$t-$c.exe" "tools/$c.c" && echo "ok   $c" || fail=1
    rm -f "$t-$c.exe"
  done
  rm -f "$t.dll" "$t.exe" "$t-check.exe"
fi
if command -v shellcheck >/dev/null; then shellcheck -x -S warning "${SH[@]}" && echo "ok   shellcheck" || fail=1; fi
[ $fail = 0 ] && echo "all checks passed"; exit $fail
