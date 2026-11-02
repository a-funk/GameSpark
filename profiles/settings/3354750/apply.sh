#!/bin/bash
# skate. (3354750, EA / Full Circle, Frostbite, DirectX 12): nothing to apply yet.
# Usage: profiles/settings/3354750/apply.sh A|B|C|show|revert   (A, B and C print the menu entries of candidates.sh)
# Why there is no file to edit:
#   - The game has never been started here (Steam: LastPlayed 0; the prefix is empty), so it has written no settings. Its
#     file name and format are unknown; Frostbite games keep a binary profile under Documents/<game>/, which is not a
#     thing to edit blind. After a first start, find it with:  find <prefix> -newer <install>/Skate.exe -type f
#   - It probably cannot be started: EA says skate. does not support Linux, Proton or the Steam Deck because of EA Javelin
#     anti-cheat (EAAntiCheat.GameServiceLauncher.exe in the install; Steam runs EAAntiCheat.Installer.exe --install on the
#     first launch), and testers running it under Wine get an error that names Wine and Proton, after the anti-cheat
#     service crashes. EA mentions a future Javelin for Linux and ARM, no date. The only community workaround, ReSkate,
#     runs a frozen older build with no anti-cheat: not something to install here.
#   - Steam also shows an update waiting (3 GB: build 25414733 -> 25617022) and the game wants an EA account sign-in.
# So nothing is written; `show` prints what A, B or C would set in the menus if it ever starts. Not measured.
ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
# shellcheck source=profiles/settings/3354750/candidates.sh
. "$ROOT/profiles/settings/3354750/candidates.sh"
set -u

case ${1:-} in
  A) printf '%s\n' "${SKATE_A[@]}" ;;
  B) printf '%s\n' "${SKATE_B[@]}" ;;
  C) printf '%s\n' "${SKATE_C[@]}" ;;
  show) echo "no settings file: skate. has never been started on this machine (see the header of $0)" ;;
  revert) echo "nothing to revert: GameSpark has not changed any skate. file" ;;
  *) echo "usage: $0 A|B|C|show|revert" >&2; exit 2 ;;
esac
