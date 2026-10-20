# shellcheck shell=bash disable=SC2034  # variables are read by bench/run.sh
# STAR WARS: Galactic Racer (Unreal Engine 5, DirectX 12 via VKD3D-Proton; Denuvo). Sourced by bench/run.sh.
#
# No built-in benchmark: the Visuals page's "Run Benchmark" is Unreal's few-second hardware probe that suggests quality
# levels. game_drive starts the Arcade time trial "Landspeeder Ace" (Jakku, open from the start) from the main menu by
# keyboard (Q/E tabs, Z/C categories, Space select), photographs the track flyover at fixed times (the same camera path
# every run: compare the pictures between settings), then holds the throttle (W, no steering) from the start while
# MangoHud logs frame times: the same straight and the same walls every run. Time trials keep nothing when quit, so
# the run ends by killing the game. Needs the game's Steam launch options set to tools/launch.sh (the GameSpark
# profile: patched FEX for Denuvo) and system/frametimes.sh install.
# Env: GR_CANDIDATE=P0|U|A|B|C  one of the 4K candidates of profiles/settings/4078430/candidates.sh (P0 = the 2560x1440
#      file found on 2026-10-13, U = 3840x2160 + DLSS Ultra Performance, A = U with GI/reflections/post one step down,
#      B = 3840x2160 + DLSS Performance + textures 3, C = A with lower view distance/effects/foliage/shading), written
#      into GameUserSettings.ini for this run.
#      GR_SET="Key=Value ..."  more GameUserSettings.ini values for this run, after the candidate, e.g.
#      DLSSSuperResolutionMode=Balanced or sg.ShadowQuality=2. Measured runs also lift the game's frame cap
#      (FrameRateLimit=0) and VSync. The player's file is put back after every run (game_cleanup).
#      ENGINE_INI="r.A=1 ..." (bench/run.sh) adds Engine.ini cvars for the run, over profiles/launch/4078430.Engine.ini.
#      Warm-up: the first run after a settings change compiles pipelines in the race (57 against 66 fps); discard it.
#      GR_ROUTE=campaign  Continue Campaign instead of the time trial: the route players take, and the one that crashed on
#      2026-10-14 (null ray tracing proxy ~4 s after L_Mastiff_LOOP_A loads). The player's saves are backed up before the
#      launch and put back after the game has closed (game_cleanup), so a test leaves the campaign where it was. The map
#      load is read from the game's crash-reporter breadcrumbs; campaign.txt says whether the game outlived the window.
#      GR_ROUTE=replay GR_RACE=NAME  a race a player drove, driven again by the player's own input (tools/padreplay.py):
#      NAME is a race file in $SG_DATA/gr-inputs/races (or a path). The bench reaches the race's event by its notes
#      (event_keys: keys from the Arcade tab's first card, e.g. Right*5; event_re, optional: words its event page shows)
#      and checks the map the game loads. A virtual DualSense plays the recorded input from the intro on, re-aligned on
#      every letterbox edge (set pieces, the finish), seen in a small screen strip. The player's DualSense is disconnected for the run (its PS
#      button reconnects it) and the saves are backed up and put back as in the campaign route. frames_window covers
#      the intro's end to 5 s before the finish line, where the run ends: a finished Arcade event posts its time to the
#      game's online leaderboard (GR_REPLAY_FINISH=1 finishes; GR_REPLAY_SECONDS=N measures only the race's first N
#      seconds, e.g. about a lap; GR_SHOTS="20 40" screenshots that many seconds after the intro's end, the same
#      moments in every run, at the cost of a hitch each). replay.txt says how closely the game followed the recording.
#      GR_DRIVER=ai: the same event and window, but the game's AI drives the player's vehicle (Race.AI.DriveLocalPlayer)
#      and the virtual pad stays at rest; measures GR_REPLAY_SECONDS (default 60) from the intro's end. Races keep the game's
#      Steam build they were recorded on (note buildid); a later build warns, since an update can change the tracks.
#      GR_RECORD=SECS  also record the screen (x11grab, 30 fps, 960x540, on the A725 cores the game doesn't use) from
#      the throttle on, and count flash frames (tools/flashframes.py -> flash.json). Costs the X server and memory
#      bandwidth: compare frame rates only between runs that both record or both don't.
APPID=4078430
GAME_NAME="STAR WARS: Galactic Racer"
GAME_API="DirectX 12 (VKD3D-Proton)"
GAME_EXE='STAR WARS Galactic Racer/Griffin/Binaries/Win64/SWGR-Win64-Shipping.exe'   # under steamapps/common (64-bit)
GAME_PROC='^[A-Z]:.*SWGR-Win64-Shipping\.exe'
LAUNCH_ARGS=''
LAUNCH_WAIT=600   # Denuvo's first-launch checks under FEX take a while
# MangoHud logs FRAMES seconds from the event page (its hotkey is lost if pressed during a stall, as at the race start
# with new shaders); ingest.py keeps the GR_WINDOW seconds from the throttle on (frames_window).
[ "${GR_ROUTE:-}" = campaign ] && : "${FRAMES:=150}"   # loading, intro card and cutscene come first (~45 s)
gr_buildid() { sed -n 's/^[[:space:]]*"buildid"[[:space:]]*"\([0-9]*\)".*/\1/p' "$STEAM_ROOT/steamapps/appmanifest_$APPID.acf"; }
gr_race_note() {  # KEY: a note of the replay route's race (tools/padreplay.py note)
  python3 -I -c 'import json, sys; print(json.loads(open(sys.argv[1], "rb").readline())["race"].get(sys.argv[2], ""))' "$GR_RACE" "$1"
}
if [ "${GR_ROUTE:-}" = replay ]; then
  case ${GR_RACE:?GR_ROUTE=replay needs GR_RACE} in */*) ;; *) GR_RACE=$SG_DATA/gr-inputs/races/${GR_RACE%.rec}.rec ;; esac
  [ -f "$GR_RACE" ] || die "no race $GR_RACE"
  if [ "${GR_DRIVER:-}" = ai ]; then   # the game's own AI drives the player's vehicle (a debug cvar the Shipping exe reads)
    ENGINE_INI="${ENGINE_INI:+$ENGINE_INI }Race.AI.DriveLocalPlayer=1"
    : "${GR_REPLAY_SECONDS:=60}"       # its pace isn't the player's: end well before any finish
  fi
  # MangoHud logs from the event page: loading, the intro, then the race (or its first GR_REPLAY_SECONDS)
  : "${FRAMES:=$(gr_race_note seconds | awk -v n="${GR_REPLAY_SECONDS:-0}" '{ s = $1; if (n > 0 && n + 15 < s) s = n + 15; printf "%d", s + 60 }')}"
fi
: "${FRAMES:=75}" "${FRAMES_DELAY:=key}" "${GR_WINDOW:=30}"
GR_INI="${GR_INI:-$(compat_user $APPID)/AppData/Local/StarWarsGalacticRacer/Saved/Config/Windows/GameUserSettings.ini}"
GR_PLAYER_INI=$SG_DATA/launch/GameUserSettings.player.ini   # the player's file for the run; present only until restored
GR_LOCAL="$(compat_user $APPID)/AppData/Local/StarWarsGalacticRacer"
GR_SAVED=$GR_LOCAL/Saved   # SaveGames/<steamid64>/GriffinRun.0.6.sav (campaign), GriffinSave.6.sav (profile)
GR_PLAYER_SAVES=$SG_DATA/launch/GalacticRacer.SaveGames.player.tgz   # campaign route: the saves, until restored
# shellcheck source=lib/menu.sh
. "$ROOT/lib/menu.sh"
# shellcheck source=profiles/settings/lib.sh
. "$ROOT/profiles/settings/lib.sh"
# shellcheck source=profiles/settings/4078430/candidates.sh
. "$ROOT/profiles/settings/4078430/candidates.sh"

# KEY=VALUE pairs into an ini on stdin -> stdout: each key's line replaced in place (keys are literal: sg.X, Y[3]);
# a line's CRLF stays.
gr_ini_set() {
  awk -v kv="$*" 'BEGIN { n = split(kv, a, " "); for (i = 1; i <= n; i++) { k = a[i]; sub(/=.*/, "", k); v[k] = a[i] } }
    { k = $0; sub(/=.*/, "", k); if (k in v) { print v[k] (substr($0, length($0)) == "\r" ? "\r" : ""); next } } 1'
}

gr_restore() {  # the player's file back, once the game has closed (it writes the file on exit)
  [ -f "$GR_PLAYER_INI" ] || return 0
  for _ in $(seq 30); do pgrep -f "$GAME_PROC" >/dev/null || break; sleep 1; done
  pgrep -f "$GAME_PROC" >/dev/null && { echo "warning: $GAME_NAME is still running; its settings stay as they are" >&2; return 1; }
  cp -p "$GR_PLAYER_INI" "$GR_INI" && rm -f "$GR_PLAYER_INI"
}

game_prepare() {  # runs with the game closed: the game rewrites the file when it exits
  local -a keys=()
  [ -f "$GR_INI" ] || die "no $GR_INI: launch the game once first"
  # A file left by a run that died before restoring is the player's: put it back before taking a new copy.
  [ -f "$GR_PLAYER_INI" ] && { gr_restore || die "an earlier run's settings are still in place (see above)"; }
  case ${GR_CANDIDATE:-} in
    '') ;;
    P0) keys=("${GR_P0[@]}") ;;
    U) keys=("${GR_U[@]}") ;;
    A) keys=("${GR_A[@]}") ;;
    B) keys=("${GR_B[@]}") ;;
    C) keys=("${GR_C[@]}") ;;
    *) die "GR_CANDIDATE=$GR_CANDIDATE: P0, U, A, B or C" ;;
  esac
  mkdir -p "$SG_DATA/launch"
  sg_backup "$APPID" "$GR_INI" "bench run ${GR_CANDIDATE:-settings}" > /dev/null || die "backup failed"
  cp -p "$GR_INI" "$GR_PLAYER_INI"
  if [ ${#keys[@]} -gt 0 ]; then
    python3 -I "$ROOT/profiles/settings/ini_set.py" "$GR_INI" "${keys[@]}" || { cp -p "$GR_PLAYER_INI" "$GR_INI"; rm -f "$GR_PLAYER_INI"; die "candidate $GR_CANDIDATE not applied (the file is unchanged)"; }
  fi
  # Measured runs lift both caps: the frame limit and VSync, which holds the 60 Hz TV at 60 (the player's on 2026-10-18).
  gr_ini_set ${BENCH_RUN:+FrameRateLimit=0.000000 bIsVSyncEnabled=False} ${GR_SET:-} < "$GR_INI" > "$GR_INI.new" && cp "$GR_INI.new" "$GR_INI"
  rm -f "$GR_INI.new"
  cp "$GR_INI" "$1/GameUserSettings.ini"
  if [ "${GR_ROUTE:-}" = campaign ] || [ "${GR_ROUTE:-}" = replay ]; then   # a finished race can save a best time
    GR_RUN_DIR=$1
    [ -f "$GR_PLAYER_SAVES" ] && { gr_restore_saves || die "an earlier run's saves are still in place (see above)"; }
    tar -C "$GR_SAVED" -czf "$GR_PLAYER_SAVES.tmp" SaveGames && gr_saves_ok "$GR_PLAYER_SAVES.tmp" \
      && cp "$GR_PLAYER_SAVES.tmp" "$SG_DATA/backups/galacticracer-saved-$(date +%Y%m%d-%H%M%S)-bench.tgz" \
      && cp "$GR_PLAYER_SAVES.tmp" "$1/SaveGames.tgz" && mv "$GR_PLAYER_SAVES.tmp" "$GR_PLAYER_SAVES" \
      || { rm -f "$GR_PLAYER_SAVES.tmp"; die "saves backup failed (nothing launched, nothing changed)"; }
  fi
  if [ "${GR_ROUTE:-}" = replay ]; then
    local built now
    built=$(gr_race_note buildid) now=$(gr_buildid)
    [ -n "$built" ] && [ "$built" != "$now" ] && echo "warning: the race was recorded on build $built, the game is $now" | tee "$1/build-warning" >&2
    gr_twin_start "$1" || die "no virtual DualSense (see twin.log)"
  fi
  gr_describe "$1"
}

gr_saves_ok() { tar -tzf "$1" 2>/dev/null | grep -q '^SaveGames/.*/GriffinRun.*\.sav$'; }   # TGZ holds a campaign save

gr_restore_saves() {  # campaign route: the player's saves back once the game has closed. Fresh mtimes, so Steam Cloud
  # sees a local change and uploads it rather than preferring the copy the test run synced. Nothing is deleted: the
  # test's own SaveGames is moved into the run dir (or next to the original if the run dir is unknown).
  [ -f "$GR_PLAYER_SAVES" ] || return 0
  local tmp keep
  for _ in $(seq 60); do pgrep -f "$GAME_PROC" >/dev/null || pgrep -f "[r]eaper SteamLaunch AppId=$APPID " >/dev/null || break; sleep 1; done
  pgrep -f "$GAME_PROC" >/dev/null && { echo "warning: $GAME_NAME is still running; saves NOT restored ($GR_PLAYER_SAVES)" >&2; return 1; }
  gr_saves_ok "$GR_PLAYER_SAVES" || { echo "warning: $GR_PLAYER_SAVES has no campaign save; saves NOT restored" >&2; return 1; }
  tmp=$(mktemp -d "$GR_SAVED/.restore.XXXXXX") && tar -C "$tmp" -xzmf "$GR_PLAYER_SAVES" && compgen -G "$tmp/SaveGames/*/GriffinRun*.sav" >/dev/null \
    || { echo "warning: could not unpack $GR_PLAYER_SAVES; saves NOT restored" >&2; rm -rf "${tmp:?}"; return 1; }
  keep=${GR_RUN_DIR:-$GR_SAVED}/SaveGames.after-test-$(date +%H%M%S)
  { [ ! -e "$GR_SAVED/SaveGames" ] || mv "$GR_SAVED/SaveGames" "$keep"; } && mv "$tmp/SaveGames" "$GR_SAVED/SaveGames" && rmdir "$tmp" \
    && rm -f "$GR_PLAYER_SAVES" && echo "saves restored (the test run's copy: $keep)" \
    || { echo "warning: saves NOT restored cleanly; backup $GR_PLAYER_SAVES, test copy $keep, unpacked $tmp" >&2; return 1; }
}

game_cleanup() { gr_twin_stop; gr_restore || true; gr_restore_saves || true; }   # EXIT trap of bench/run.sh

# Replay route: the screen strip where the letterbox edges show (padreplay.py STRIP at 4K, scaled to the display).
gr_strip() { xdpyinfo | awk '/dimensions:/ { split($2, d, "x"); printf "%dx%d+%d+%d\n", d[1] * 440 / 3840, d[2] * 200 / 2160, d[1] * 780 / 3840, d[2] * 100 / 2160 }'; }

gr_twin_start() {  # $1 run dir: the virtual DualSense (root, for /dev/uhid), at rest until the race's intro starts. The
  # recorded pad goes off Bluetooth first, or the game would read two pads.
  local mac
  mac=$(python3 -I -c 'import json, sys; u = json.loads(open(sys.argv[1], "rb").readline())["uevent"]
print("".join(l[9:] for l in u.splitlines() if l.startswith("HID_UNIQ=")))' "$GR_RACE")
  if [ -n "$mac" ] && bluetoothctl info "$mac" 2>/dev/null | grep -q "Connected: yes"; then
    bluetoothctl disconnect "$mac" >/dev/null && echo "disconnected the player's DualSense ($mac) for the replay: its PS button reconnects it"
  fi
  # A twin an earlier run left behind holds the MAC this one needs (the kernel refuses a second).
  local pids; pids=$(pgrep -f '^python3 -I [^ ]*/padreplay\.py twin ' | xargs)
  [ -n "$pids" ] && { echo "ending a virtual DualSense left by an earlier run ($pids)"; as_root kill $pids; sleep 1; }
  : > "$1/edges.txt"
  # On the A725 cores, away from the game's; at normal priority, since it keeps the input's timing.
  as_root taskset -c "$(gr_slow_cpus)" python3 -I "$ROOT/tools/padreplay.py" twin "$GR_RACE" "$1/edges.txt" \
    "$(( FRAMES + 600 ))" --summary "$1/replay.json" --log "$1/twin.log" --idle "$([ "${GR_DRIVER:-}" = ai ] && echo 1)" \
    > "$1/twin.out" 2>&1 8>&- &   # not holding run.sh's lock (fd 8)
  # The twin logs this once hid-playstation has bound it (a hidraw node the game can open).
  for _ in $(seq 40); do grep -qs "idle until the race starts" "$1/twin.log" && break; sleep 0.5; done
  grep -qs "idle until the race starts" "$1/twin.log" || { cat "$1/twin.out" "$1/twin.log" 2>/dev/null; return 1; }
}

gr_twin_stop() {  # the twin ends on a stop line (no root needed); the edge watcher by pid
  [ -n "${GR_RUN_DIR:-}" ] && [ -f "$GR_RUN_DIR/edges.txt" ] || return 0
  echo "0 stop" >> "$GR_RUN_DIR/edges.txt"
  [ -s "$GR_RUN_DIR/watch.pid" ] && kill "$(cat "$GR_RUN_DIR/watch.pid")" 2>/dev/null
  rm -f "$GR_RUN_DIR/watch.pid"
}

gr_val() { tr -d '\r' < "$GR_INI" | sed -n "s/^$1=//p" | head -1; }

gr_describe() {  # $1 run dir: the run's resolution and preset, for the record
  echo "$(gr_val ResolutionSizeX)x$(gr_val ResolutionSizeY)" > "$1/resolution"
  echo "DLSS $(gr_val DLSSSuperResolutionMode) (frame gen $(gr_val DLSSFrameGenerationMode)) · candidate ${GR_CANDIDATE:-as is} · GI $(gr_val sg.GlobalIlluminationQuality), reflections $(gr_val sg.ReflectionQuality), post $(gr_val sg.PostProcessQuality), textures $(gr_val sg.TextureQuality)" > "$1/preset"
}

# Mean colour of a region, in 1280x720 coordinates whatever the screen's size: "R G B".
gr_rgb() {  # PNG X Y W H
  ffmpeg -loglevel error -i "$1" -vf "scale=1280:720,crop=$4:$5:$2:$3,scale=1:1" -frames:v 1 -f rawvideo \
    -pix_fmt rgb24 - | od -An -tu1 | xargs
}

# The main menu's active tab sits on a red pill (about 177,81,60); the others on the beige background.
gr_tab_active() {  # PNG TAB
  local x
  case $2 in CAMPAIGN) x=90 ;; SCENARIOS) x=232 ;; ARCADE) x=378 ;; MULTIPLAYER) x=505 ;; *) return 2 ;; esac
  gr_rgb "$1" "$x" 42 95 20 | awk '{ exit !($1 > $3 + 50) }'
}

gr_on_menu() {  # PNG: exactly one of the main menu's four tabs is red, the other three neutral grey (dark text on beige
  # averages about 125-145 in all channels); title screens are white, game scenes rarely neutral in all three boxes
  local x red=0 grey=0
  for x in 90 232 378 505; do
    case $(gr_rgb "$1" "$x" 42 95 20 | awk '{ d = $1 - $3; g = $1 - $2
      print (d > 50) ? "red" : (d > -20 && d < 20 && g > -10 && g < 10 && $1 >= 115 && $1 <= 165) ? "grey" : "other" }') in
      red) red=$((red + 1)) ;; grey) grey=$((grey + 1)) ;;
    esac
  done
  [ "$red" = 1 ] && [ "$grey" = 3 ]
}

gr_slow_cpus() {  # every CPU fast_cpus (lib/env.sh) doesn't list
  local fast c out=
  fast=",$(fast_cpus),"
  for c in /sys/devices/system/cpu/cpu[0-9]*; do c=${c##*cpu}; [[ $fast == *",$c,"* ]] || out+=${out:+,}$c; done
  echo "$out"
}

gr_shot() { [ -n "${MENU_REPLAY:-}" ] || "$ROOT/tools/shot.sh" "$1" >/dev/null; }

# The newest map the game logged (crash-reporter breadcrumbs of the running session): "<UTC time> <map>".
gr_last_map() {
  local run
  run=$(ls -td "$GR_LOCAL"/.sentry-native/*.run 2>/dev/null | head -1) || return 1
  [ -n "$run" ] || return 1
  # sentry-native alternates two breadcrumb files: keep the load with the latest timestamp (ISO times sort as text)
  cat "$run"/__sentry-breadcrumb* 2>/dev/null | LC_ALL=C tr -c '[:print:]' '\n' | awk '
    /^20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]T/ { t = $0 } /PostLoadMapWithWorld/ { want = 1; next }
    want && /^L_/ { if (t > mt) { m = $0; mt = t }; want = 0 } END { if (m != "") print mt, m }'
}

gr_card_text() {  # PNG: the title of the Campaign tab's big card (white over poster art: crop, black on white, OCR)
  ffmpeg -loglevel error -y -i "$1" -vf 'scale=1280:720,crop=320:90:45:530,scale=1280:360,format=gray,lutyuv=y=if(gt(val\,200)\,0\,255)' \
    -frames:v 1 "${1%.png}-card.png" && "$ROOT/tools/ocr.sh" "${1%.png}-card.png"
}

gr_race_view() {  # PNG: the race camera is on (cutscenes and the loading screen are letterboxed or black)
  local top bot
  top=$(gr_rgb "$1" 0 0 1280 60 | awk '{ print int(($1 + $2 + $3) / 3) }')
  bot=$(gr_rgb "$1" 0 660 1280 60 | awk '{ print int(($1 + $2 + $3) / 3) }')
  [ "${top:-0}" -gt 30 ] && [ "${bot:-0}" -gt 30 ]
}

gr_drive_campaign() {  # $1 run dir, $2 game pid: Continue Campaign; did the game survive the map? Then race 30 s.
  local out=$1 i t0 map='' tl
  for i in 1 2 3 4 5; do
    gr_tab_active "$out/menu.png" CAMPAIGN && break
    menu_send key "q~0.15"; menu_pause 2; gr_shot "$out/menu.png"
  done
  gr_tab_active "$out/menu.png" CAMPAIGN || { echo "the Campaign tab never came up"; return 1; }
  # The card zooms in when the tab opens: read it up to three times before giving up.
  for i in 1 2 3; do
    gr_card_text "$out/menu.png" | tr -s "\n" " " > "$out/campaign-tab.txt"
    grep -qi "CONTINUE CAMPAIGN" "$out/campaign-tab.txt" && break
    menu_pause 2; gr_shot "$out/menu.png"
  done
  grep -qi "CONTINUE CAMPAIGN" "$out/campaign-tab.txt" || { echo "no CONTINUE CAMPAIGN card on the Campaign tab (see campaign-tab.txt)"; return 1; }
  gr_tab_active "$out/menu.png" CAMPAIGN || { echo "the Campaign tab is no longer active"; return 1; }
  frames_start; local t_log; t_log=$(date +%s.%N)
  menu_send key "space~0.15"
  t0=$(date +%s)
  for i in $(seq 240); do
    kill -0 "$2" 2>/dev/null || { echo "crashed: the game exited while loading, $(( $(date +%s) - t0 )) s after Continue" | tee "$out/campaign.txt"; return 1; }
    map=$(gr_last_map) && [ "${map#* }" != L_FrontEnd ] && break
    map=; sleep 1
  done
  [ -n "$map" ] || { echo "no map load logged within 240 s" | tee "$out/campaign.txt"; return 1; }
  tl=$(date +%s)
  echo "map ${map#* } loaded (logged ${map%% *}), $(( tl - t0 )) s after Continue"
  # The 2026-10-14 crash came 3.7 s after the map loaded (still behind the loading screen).
  sleep 5
  kill -0 "$2" 2>/dev/null || { echo "crashed: within 5 s of ${map#* } loading" | tee "$out/campaign.txt"; return 1; }
  # Then the event's intro card and a cutscene (letterboxed), then the grid with the race camera.
  for i in $(seq 120); do
    kill -0 "$2" 2>/dev/null || { echo "crashed: ${map#* } stopped $(( $(date +%s) - tl )) s after it loaded" | tee "$out/campaign.txt"; return 1; }
    gr_shot "$out/campaign-wait.png"
    gr_race_view "$out/campaign-wait.png" && break
    sleep 1
  done
  gr_race_view "$out/campaign-wait.png" || { echo "no race view within 120 s of ${map#* } loading" | tee "$out/campaign.txt"; return 1; }
  mv "$out/campaign-wait.png" "$out/campaign-grid.png"
  echo "race view $(( $(date +%s) - tl )) s after the map loaded: throttle"
  date +%s.%N > "$out/throttle_at"   # wall clock, to line up other recordings with frames_window
  menu_send key "w~$(( GR_WINDOW + 10 ))" &
  awk -v a="$t_log" -v b="$(date +%s.%N)" -v w="$GR_WINDOW" 'BEGIN { printf "%.2f %d\n", b - a, w }' > "$out/frames_window"
  if [ -n "${GR_RECORD:-}" ]; then   # as in the time trial: count flash frames (game_collect)
    taskset -c "$(gr_slow_cpus)" ffmpeg -loglevel error -f x11grab -framerate 30 \
      -video_size "$(xdpyinfo | awk '/dimensions:/ { print $2 }')" -i "$DISPLAY" -t "$GR_RECORD" -vf scale=960:540 \
      -c:v libx264 -preset ultrafast -crf 10 "$out/race.mkv" &
  fi
  wait
  gr_shot "$out/campaign-end.png"
  if kill -0 "$2" 2>/dev/null; then
    echo "survived: ${map#* } running $(( $(date +%s) - tl )) s after it loaded" | tee "$out/campaign.txt"
  else
    echo "crashed: ${map#* } stopped $(( $(date +%s) - tl )) s after it loaded" | tee "$out/campaign.txt"; return 1
  fi
  local left; left=$(awk -v a="$t_log" -v f="$FRAMES" -v now="$(date +%s.%N)" 'BEGIN { s = a + f + 15 - now; print (s > 0 ? int(s) : 0) }')
  sleep "$left"
  compgen -G "$out/frames/*_summary.csv" >/dev/null || { echo "no frame log: the hotkey was lost"; kill "$2"; return 1; }
}

gr_arcade_first_card() {  # $1 run dir: the Arcade tab's first card (Landspeeder Ace)
  local i
  for i in 1 2 3 4 5; do
    gr_tab_active "$1/menu.png" ARCADE && break
    menu_send key "e~0.15"; menu_pause 2; gr_shot "$1/menu.png"
  done
  gr_tab_active "$1/menu.png" ARCADE || { echo "the Arcade tab never came up"; return 1; }
  # The tab opens on the last event played. Its cards form one row (Z/C jump between sections of it, dropping presses
  # during the scroll); holding Left (X key repeat, ~25/s) runs back to the first card from anywhere.
  menu_send key "Left~5"
  menu_pause 1.5
}

gr_drive_replay() {  # $1 run dir, $2 game pid: the race's event, driven by the recorded input (gr_twin_start)
  local out=$1 keys re k i t_log map=''
  keys=$(gr_race_note event_keys) re=$(gr_race_note event_re)
  [ -n "$keys" ] || { echo "$GR_RACE has no event_keys note (keys from the first Arcade card: tools/padreplay.py note RACE event_keys=Right*5)"; return 1; }
  gr_arcade_first_card "$out" || return 1
  for k in $keys; do menu_send key "$k~0.15"; menu_pause 0.6; done
  menu_pause 1.5
  menu_press event "NEXT GOAL|MEDAL TIMES" 1 key "space~0.15" || return 1
  [ -z "$re" ] || screen_has event "$re" || { echo "not the race's event (its page lacks /$re/)"; return 1; }
  # The watcher also keeps the strip (hud.mkv: the race clock, for checking a replay against the recording afterwards).
  taskset -c "$(gr_slow_cpus)" nice -n 10 python3 -I "$ROOT/tools/padreplay.py" watch "$out/edges.txt" "$(( FRAMES + 60 ))" \
    "$(gr_strip)" "$out/hud.mkv" &
  echo $! > "$out/watch.pid"
  frames_start; t_log=$(date +%s.%N)
  menu_send key "space~0.15"   # START EVENT: from here the twin waits for the intro's first letterbox frame
  # The event titles defeat OCR; the map the game loads (3-5 s before the intro) says whether this is the race's event.
  for i in $(seq 120); do
    kill -0 "$2" 2>/dev/null || { echo "the game exited while loading"; return 1; }
    map=$(gr_last_map) && [ "${map#* }" != L_FrontEnd ] && break
    map=; sleep 1
  done
  [ "${map#* }" = "$(gr_race_note map)" ] || { echo "loaded '${map#* }', not the race's $(gr_race_note map)"; return 1; }
  if [ -n "${GR_SHOTS:-}" ]; then   # screenshots N s after the race starts: the same race moments in every run
    (
      for _ in $(seq 1200); do [ -s "$out/race_start" ] && break; sleep 0.1; done
      [ -s "$out/race_start" ] || exit 0
      for t in $GR_SHOTS; do
        sleep "$(awk -v a="$(cat "$out/race_start")" -v t="$t" -v now="$(date +%s.%N)" 'BEGIN { s = a + t - now; print (s > 0 ? s : 0) }')"
        gr_shot "$out/shot-$t.png"
      done
    ) &
  fi
  # The race starts where the replay's intro ends (the recording's second edge, as this run showed it). With the AI
  # driving, intros and pre-race cutscenes run their full length (the player skipped some): the race starts at the end
  # of the last letterbox before 8 s without one. The measured window ends 5 s before the finish line, as the replay
  # expects it by now: a finished Arcade event posts its time to the game's online leaderboard. GR_REPLAY_SECONDS ends
  # it earlier (with the AI, always: its pace isn't the player's), GR_REPLAY_FINISH=1 at the finish.
  local window
  window=$(python3 -I - "$out" "$2" "${GR_DRIVER:-replay}" "${GR_REPLAY_SECONDS:-0}" "${GR_REPLAY_FINISH:-}" "$FRAMES" <<'PY'
import json, os, sys, time
out, pid, driver, part, finish, frames = sys.argv[1], sys.argv[2], sys.argv[3], float(sys.argv[4]), sys.argv[5], float(sys.argv[6])
deadline, race_start = time.time() + frames + 30, None
while time.time() < deadline and os.path.exists(f"/proc/{pid}"):
    now, end, done = time.time(), None, False
    if driver == "ai":
        try:
            e = [(int(t) / 1e9, k) for t, k in (l.split() for l in open(out + "/edges.txt") if l.strip()) if k != "stop"]
        except (OSError, ValueError):
            e = []
        if race_start is None:
            race_start = next((t for i, (t, k) in enumerate(e) if k == "end" and now - t >= 8
                               and not any(k2 == "start" and t2 < t + 8 for t2, k2 in e[i + 1:])), None)
        if race_start is not None:
            end = race_start + part
            done = now >= end
    else:
        try:
            r = json.load(open(out + "/replay.json"))
        except (OSError, ValueError):
            r = None
        if r and r["edges"][0]["matched"] and len(r["edges"]) >= 3:
            e = r["edges"]
            race_start = e[1]["live_ns"] / 1e9 if e[1]["matched"] or race_start is None else race_start
            end = e[-1]["live_ns"] / 1e9 - (0 if finish else 5)
            if part:
                end = min(end, e[1]["live_ns"] / 1e9 + part)
            done = r["done"] if finish and not part else now >= end
    if race_start is not None and not os.path.exists(out + "/race_start"):
        open(out + "/race_start", "w").write(f"{race_start:.3f}\n")
    if done:
        sys.exit(print(f"{race_start:.3f} {min(now, end):.3f}"))
    time.sleep(0.1)
sys.exit(1)
PY
  ) || { echo "the race never reached its window's end (the game exited, or no intro was seen: edges.txt)"; return 1; }
  if [ -z "${GR_REPLAY_FINISH:-}" ]; then
    # MangoHud writes its log only when logging ends: end it with the hotkey, and press once more if a stall ate it.
    menu_send key "$FRAMES_KEY~0.3"
    for i in $(seq 30); do compgen -G "$out/frames/*_summary.csv" >/dev/null && break; sleep 0.1; done
    compgen -G "$out/frames/*_summary.csv" >/dev/null || menu_send key "$FRAMES_KEY~0.3"
    for i in $(seq 30); do compgen -G "$out/frames/*_summary.csv" >/dev/null && break; sleep 0.1; done
  fi
  # replay.txt: each recorded edge, whether this run showed it, and the corrections (how far the game drifted);
  # frames_window: from the race's start to the window's end, as this run showed them.
  python3 -I - "$out" "$t_log" $window "${GR_DRIVER:-replay}" <<'PY' || return 1
import json, sys
out, t_log, a, stop, driver = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), float(sys.argv[4]), sys.argv[5]
r = json.load(open(out + "/replay.json"))
e = r["edges"]
live = [(int(t) / 1e9, k) for t, k in (l.split() for l in open(out + "/edges.txt") if l.strip()) if k != "stop"]
with open(out + "/replay.txt", "w") as f:
    f.write(f"{driver}: window {stop - a:.1f} s from the race's start (race {'finished' if r['done'] else 'stopped before the finish'})")
    if driver == "ai":
        f.write("; letterbox edges, s after the intro: " + " ".join(f"{k[0]}{t - live[0][0]:.1f}" for t, k in live) + "\n")
    else:
        f.write(f"; edges seen {sum(x['matched'] for x in e)}/{len(e)}; corrections ms {r['corrections_ms']}\n")
        for x in e:
            f.write(f"  {x['kind']:5s} recorded {x['recorded_s']:7.2f} s  {'seen' if x['matched'] else 'not seen'}\n")
open(out + "/frames_window", "w").write(f"{a - t_log:.2f} {stop - a:.2f}\n")
print(open(out + "/replay.txt").read().splitlines()[0])
PY
  if [ -z "${GR_REPLAY_FINISH:-}" ]; then
    kill "$2"; return 0   # before the finish line (run.sh sees the game gone and collects)
  fi
  gr_shot "$out/finish.png"
  local left; left=$(awk -v a="$t_log" -v f="$FRAMES" -v now="$(date +%s.%N)" 'BEGIN { s = a + f + 15 - now; print (s > 0 ? int(s) : 0) }')
  sleep "$left"
  compgen -G "$out/frames/*_summary.csv" >/dev/null || { echo "no frame log: the hotkey was lost"; kill "$2"; return 1; }
}

game_drive() {  # $1 run dir, $2 game pid
  local out=$1 i t0 luma
  MENU_DIR=$out
  # The title screen ("PRESS [Space] TO CONTINUE") and the photosensitivity notice (its CONTINUE focused) take Space; the main menu is recognised by its tab highlight, never
  # by trying keys: Space on the menu's Campaign tab continues the player's campaign.
  for i in $(seq 60); do
    gr_shot "$out/menu.png"
    gr_on_menu "$out/menu.png" && break
    "$ROOT/tools/ocr.sh" "$out/menu.png" | grep -qiE "TO CONTINUE|GAME CODE|PHOTOSENSITIVITY|READ THIS NOTICE" && menu_send key "space~0.15"
    [ -n "${MENU_REPLAY:-}" ] && break
    sleep 4
  done
  gr_on_menu "$out/menu.png" || { echo "main menu never showed"; return 1; }
  [ "${GR_ROUTE:-}" = campaign ] && { gr_drive_campaign "$out" "$2"; return; }
  [ "${GR_ROUTE:-}" = replay ] && { gr_drive_replay "$out" "$2"; return; }
  gr_arcade_first_card "$out" || return 1
  # The event page (its START EVENT button, white on dark, is focused but OCR can't read it).
  menu_press event "NEXT GOAL|MEDAL TIMES" 1 key "space~0.15" || return 1
  screen_has event "KESTAR BOOL|SOREN ZAKS" || { echo "not the Landspeeder Ace event (its medal holders)"; return 1; }
  frames_start; local t_log; t_log=$(date +%s.%N)   # the log starts on this steady page
  menu_send key "space~0.15"
  # The loading screen is black; the flyover is the first bright picture. Its frames are the same every run.
  t0=$(date +%s)
  for i in $(seq 120); do
    gr_shot "$out/load.png"
    luma=$(gr_rgb "$out/load.png" 0 0 1280 720 | awk '{ print int(($1 + $2 + $3) / 3) }')
    [ "${luma:-0}" -gt 25 ] && break
    [ -n "${MENU_REPLAY:-}" ] && break
    sleep 1
  done
  echo "flyover after $(( $(date +%s) - t0 )) s"
  # The time trial's clock starts about 2 s into the intro card (JAKKU / LANDSPEEDER ACE over the track): throttle
  # and frame log from here, so every run covers the same seconds. OCR can't read the race HUD over the scene.
  gr_shot "$out/flyover.png"
  if [ "$("$ROOT/tools/ocr.sh" "$out/flyover.png" | grep -cE "PAUSED|RESUME|RETRY")" -ge 3 ]; then
    echo "the game paused itself: resuming"; menu_send key "Escape~0.15"; menu_pause 1
  fi
  menu_send key "w~$(( GR_WINDOW + 10 ))" &
  awk -v a="$t_log" -v b="$(date +%s.%N)" -v w="$GR_WINDOW" 'BEGIN { printf "%.2f %d\n", b - a, w }' > "$out/frames_window"
  if [ -n "${GR_RECORD:-}" ] && [ -z "${MENU_REPLAY:-}" ]; then
    taskset -c "$(gr_slow_cpus)" ffmpeg -loglevel error -f x11grab -framerate 30 \
      -video_size "$(xdpyinfo | awk '/dimensions:/ { print $2 }')" -i "$DISPLAY" -t "$GR_RECORD" -vf scale=960:540 \
      -c:v libx264 -preset ultrafast -crf 10 "$out/race.mkv" &
  fi
  echo "throttle from $(date +%T), $(cut -d" " -f1 "$out/frames_window") s into the frame log"
  wait
  # MangoHud writes its log FRAMES seconds after the hotkey; without one by then the hotkey was lost: end the run.
  local left; left=$(awk -v a="$t_log" -v f="$FRAMES" -v now="$(date +%s.%N)" 'BEGIN { s = a + f + 15 - now; print (s > 0 ? int(s) : 0) }')
  [ -n "${MENU_REPLAY:-}" ] && return 0
  sleep "$left"
  compgen -G "$out/frames/*_summary.csv" >/dev/null || { echo "no frame log: the hotkey was lost"; kill "$2"; return 1; }
}

game_collect() {  # $1 run dir: the result is the frame log
  game_cleanup
  find "$GR_LOCAL/.sentry-native/reports" -name '*.dmp' -newer "$1/meta.json" -exec cp {} "$1/" \; 2>/dev/null
  [ -f "$1/race.mkv" ] && python3 -I "$ROOT/tools/flashframes.py" "$1/race.mkv" "$1/flash" > "$1/flash.json"
  compgen -G "$1/frames/*_summary.csv" >/dev/null
}
