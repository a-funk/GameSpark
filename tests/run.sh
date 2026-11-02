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
for t in bench/ingest.py bench/tune.py profile/analyze.py tools/steamcfg.py tools/winereg.py tools/gamepad.py tools/xinput.py tools/boot-nudge.py \
         tools/padreplay.py; do
  out=$(python3 -I "$t" --selftest 2>&1) && echo "ok   $t" || { echo "FAIL $t"; echo "$out"; fail=1; }
done
# lib/env.sh display_mode on xrandr --current output (no X server needed): the primary output's current mode
mode=$(bash -c '. lib/env.sh; xrandr() { printf "%s\n" "Screen 0: minimum 8 x 8, current 3840 x 2160" \
  "HDMI-0 connected primary 3840x2160+0+0 (normal) 1110mm x 620mm" "   3840x2160     30.00 +  59.94*   29.97" \
  "   1920x1080     60.00    59.94  " "USB-C-0 disconnected (normal)"; }; display_mode; GAME_RES=2560x1440 game_res')
[ "$mode" = "$(printf '3840x2160 59.94\n2560x1440')" ] && echo "ok   display_mode" || { echo "FAIL display_mode: $mode"; fail=1; }
for f in bench/telemetry.py bench/cyberpunk2077_settings.py controller/xbox-watch.py controller/evdev32_check.py; do
  python3 -I -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$f" || { echo "parse: $f"; fail=1; }
done
# launch.sh on a stand-in game: profile variables reach the command, the Engine.ini lands in the prefix
t=$(mktemp -d); mkdir -p "$t/tools" "$t/profiles/launch"; cp tools/launch.sh "$t/tools/"
printf 'UE_PROJECT=TestGame\nGS_TEST=ok\n' > "$t/profiles/launch/999.env"
printf '[SystemSettings]\nr.Test=1\n' > "$t/profiles/launch/999.Engine.ini"
# shellcheck disable=SC2016  # $GS_TEST is for the inner shell
out=$(SteamAppId=999 STEAM_COMPAT_DATA_PATH="$t/compat" SG_DATA="$t/data" bash "$t/tools/launch.sh" bash -c 'echo "$GS_TEST"')
if [ "$out" = ok ] && ! grep -q WARNING "$t/data/launch/launches.log" && cmp -s "$t/profiles/launch/999.Engine.ini" \
     "$t/compat/pfx/drive_c/users/steamuser/AppData/Local/TestGame/Saved/Config/Windows/Engine.ini"; then
  echo "ok   launch.sh"
else
  echo "FAIL launch.sh (output: $out)"; fail=1
fi
# ...and a run's run.Engine.ini replaces the profile's line for the same key and adds its own
mkdir -p "$t/data/launch"; printf 'r.Test=2\nr.Extra=3\n' > "$t/data/launch/run.Engine.ini"
SteamAppId=999 STEAM_COMPAT_DATA_PATH="$t/compat" SG_DATA="$t/data" bash "$t/tools/launch.sh" true
if [ "$(cat "$t/compat/pfx/drive_c/users/steamuser/AppData/Local/TestGame/Saved/Config/Windows/Engine.ini")" = \
     "$(printf '[SystemSettings]\nr.Test=2\nr.Extra=3')" ]; then
  echo "ok   launch.sh run.Engine.ini"
else
  echo "FAIL launch.sh run.Engine.ini"; fail=1
fi
rm -rf "$t"
# launch.sh fails closed for a FEX_NEEDSSECCOMP=1 game on a Proton without the seccomp syscall trap (Syscall User
# Dispatch builds), and starts it on one with the trap
t=$(mktemp -d); mkdir -p "$t/tools" "$t/profiles/launch" "$t/P/files/lib/wine/x86_64-unix"; cp tools/launch.sh "$t/tools/"
printf 'FEX_NEEDSSECCOMP=1\n' > "$t/profiles/launch/998.env"
printf '#!/bin/sh\necho started\n' > "$t/P/proton"; chmod +x "$t/P/proton"
printf 'x Installing seccomp filters. x' > "$t/P/files/lib/wine/x86_64-unix/ntdll.so"
a=$(SteamAppId=998 SG_DATA="$t/data" bash "$t/tools/launch.sh" "$t/P/proton" 2>/dev/null)
printf 'x syscall user dispatch x' > "$t/P/files/lib/wine/x86_64-unix/ntdll.so"
b=$(SteamAppId=998 SG_DATA="$t/data" bash "$t/tools/launch.sh" "$t/P/proton" 2>/dev/null; echo "exit $?")
[ "$a" = started ] && [ "$b" = "exit 1" ] && echo "ok   launch.sh seccomp guard" || { echo "FAIL launch.sh seccomp guard ($a / $b)"; fail=1; }
rm -rf "$t"
# Galactic Racer's campaign route: the newest map from the game's crash-reporter breadcrumbs (msgpack strings), and a
# save archive without a campaign save is refused
t=$(mktemp -d); mkdir -p "$t/.sentry-native/a.run" "$t/s/SaveGames/1"
printf '\x85\xa9timestamp\xbb2026-10-15T01:22:45.326720Z\xa7message\xb4PostLoadMapWithWorld\xa4data\x81\xa3Map\xaaL_FrontEnd\x85\xa9timestamp\xbb2026-10-15T01:45:27.040449Z\xa7message\xb4PostLoadMapWithWorld\xa4data\x81\xa3Map\xb0L_Mastiff_LOOP_A\xa5level\xa4info' \
  > "$t/.sentry-native/a.run/__sentry-breadcrumb1"
echo x > "$t/s/SaveGames/1/GriffinSave.6.sav"; tar -C "$t/s" -czf "$t/nocampaign.tgz" SaveGames
echo x > "$t/s/SaveGames/1/GriffinRun.0.6.sav"; tar -C "$t/s" -czf "$t/campaign.tgz" SaveGames
out=$(ROOT=$ROOT GR_T=$t bash -c '. lib/env.sh; . bench/games/galacticracer.sh; GR_LOCAL=$GR_T; gr_last_map
  gr_saves_ok "$GR_T/campaign.tgz" && echo yes; gr_saves_ok "$GR_T/nocampaign.tgz" || echo no' 2>&1)
[ "$out" = "$(printf '2026-10-15T01:45:27.040449Z L_Mastiff_LOOP_A\nyes\nno')" ] && echo "ok   galacticracer campaign helpers" ||
  { echo "FAIL galacticracer campaign helpers: $out"; fail=1; }
rm -rf "$t"
for f in profiles/launch/*.env; do   # SparkHome shows it on the game's tile
  grep -q '^# summary: .' "$f" || { echo "FAIL $f has no '# summary: ...' line"; fail=1; }
done
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
