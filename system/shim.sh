#!/bin/bash
# Win32 call cache for games that poll a call Wine makes slow (shim/shim.c has the why). The shim is a proxy for a
# DLL the game imports, installed next to the game's executable; the game's profiles/launch/<appid>.env names both
# and turns the proxy on:
#   SHIM=powrprof@bin/x64_dx12            proxy DLL (shim/<name>.def) @ executable folder inside the install dir
#   WINEDLLOVERRIDES=powrprof=n,b         load it (Wine falls back to its own DLL if the file is missing)
# Usage: system/shim.sh install|status|uninstall APPID      (install builds it with mingw-w64, apt-installed if needed)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
APP=${2:?usage: $0 install|status|uninstall APPID}
spec=$(sed -n 's/^SHIM=//p' "$ROOT/profiles/launch/$APP.env" 2>/dev/null)
[ -n "$spec" ] || die "profiles/launch/$APP.env has no SHIM= line"
name=${spec%@*}
inst=$(sed -n 's/^[[:space:]]*"installdir"[[:space:]]*"\(.*\)"/\1/p' "$STEAM_ROOT/steamapps/appmanifest_$APP.acf" 2>/dev/null)
[ -n "$inst" ] || die "app $APP is not installed"
dll=$SG_DATA/shim/$name.dll target="$STEAM_ROOT/steamapps/common/$inst/${spec#*@}/$name.dll"
ours() { grep -q "gamespark-shim" "$1" 2>/dev/null; }   # never touch a DLL the game ships itself
case ${1:-} in
  install)
    [ -f "$target" ] && ! ours "$target" && die "$target exists and is not the shim"
    command -v x86_64-w64-mingw32-gcc >/dev/null \
      || as_root sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq gcc-mingw-w64-x86-64 >/dev/null" || die "apt failed"
    mkdir -p "$SG_DATA/shim"
    x86_64-w64-mingw32-gcc -O2 -Wall -Wextra -shared -s -o "$dll" "$ROOT/shim/shim.c" "$ROOT/shim/$name.def" -lpsapi \
      || die "build failed"
    cp "$dll" "$target" && "$0" status "$APP" ;;
  status) cmp -s "$dll" "$target" && echo "shim installed: $target" || die "not installed ($0 install $APP)" ;;
  uninstall) ours "$target" && rm "$target"; echo "removed $target" ;;
  *) die "usage: $0 install|status|uninstall APPID" ;;
esac
