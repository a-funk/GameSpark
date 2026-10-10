#!/bin/bash
# GameSpark's patched FEX: the system FEX's release plus fex/patches/*.patch, built from source and installed for this
# user. It never replaces /usr/bin/FEX; a game opts in with FEX_BINARY=gamespark in profiles/launch/<appid>.env, and
# tools/launch.sh then starts that game's process tree (Proton, wineserver, the game) under it.
# Why: Denuvo-protected games need behaviour FEX 2610 lacks (docs/FINDINGS.md, Galactic Racer). The patches are local
# only: FEX does not accept AI-generated code, so findings go upstream as reports.
#
# Usage: system/fex-patched.sh install|status|uninstall
#   install    build the release that matches the system FEX package (tag FEX-<version>) with fex/patches applied,
#              copy FEX and FEXServer to $SG_DATA/fex/<version>-gs-<patch hash>/bin, point $SG_DATA/fex/current at
#              it, and allow it user namespaces in AppArmor (Steam's container runs bwrap; /etc/apparmor.d/gamespark-fex).
#              Re-run after the FEX package updates: the build must match the system FEXServer and thunk libraries.
#   status     installed build, the version it was built from, the system FEX version, AppArmor profile
#   uninstall  remove the builds, sources and the AppArmor profile
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
VARIANT=$(lscpu | grep -qE "dit|flagm2" && echo armv8.4 || echo armv8.2)   # same choice as system/fex-system.sh
DIR=$SG_DATA/fex
PROFILE=/etc/apparmor.d/gamespark-fex
# Submodules the FEX and FEXServer targets need (the test-binary submodules are large and unused).
SUBMODULES="External/vixl Source/Common/cpp-optparse External/fmt External/drm-headers External/xxhash
  External/Vulkan-Headers External/jemalloc_glibc External/range-v3 External/zydis External/unordered_dense
  External/rpmalloc External/tracy External/Catch2"

system_version() {   # e.g. 2610 from package version 2610-1~n
  local v; v=$(dpkg-query -W -f='${Version}' "fex-emu-$VARIANT" 2>/dev/null) || return 1
  echo "${v%%-*}"
}

patch_hash() { cat "$ROOT"/fex/patches/*.patch | sha256sum | cut -c1-8; }
# The patched FEX talks to the system FEXServer and loads the system thunks, so it must match the installed package;
# dpkg stamps file times from the package, so size + mtime changes with every package build.
fingerprint() { stat -Lc '%s %Y' /usr/bin/FEXServer 2>/dev/null; }

install_build() {
  local ver name src out tmp
  ver=$(system_version) || die "fex-emu-$VARIANT is not installed (system/fex-system.sh install)"
  name=$ver-gs-$(patch_hash); src=$DIR/src/FEX-$ver; out=$DIR/$name/bin
  if [ -x "$out/FEX" ]; then
    echo "already built: $out"
  else
    as_root sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq clang lld llvm ninja-build cmake git python3 >/dev/null" ||
      die "could not install the build tools"
    rm -rf "$src"; mkdir -p "$DIR/src"
    git -c advice.detachedHead=false clone -q --depth 1 --branch "FEX-$ver" https://github.com/FEX-Emu/FEX.git "$src" ||
      die "could not clone FEX-$ver from github.com/FEX-Emu/FEX (git error above)"
    for m in $SUBMODULES; do git -C "$src" submodule update -q --init --depth 1 "$m" || die "submodule $m"; done
    for p in "$ROOT"/fex/patches/*.patch; do
      git -C "$src" apply --check "$p" 2>/dev/null || die "$(basename "$p") does not apply to FEX-$ver; update fex/patches"
      git -C "$src" apply "$p"
    done
    mkdir -p "$src/build"
    (cd "$src/build" && cmake -G Ninja .. -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr \
      -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ -DUSE_LINKER=lld -DENABLE_LTO=OFF -DBUILD_TESTING=OFF \
      -DBUILD_FEXCONFIG=OFF -DENABLE_CCACHE=OFF -DCMAKE_CXX_SCAN_FOR_MODULES=OFF >"$src/cmake.log" 2>&1) ||
      die "cmake failed, see $src/cmake.log"
    ninja -C "$src/build" -j"$(nproc)" FEX FEXServer >"$src/build.log" 2>&1 || die "build failed, see $src/build.log"
    tmp=$DIR/$name.tmp; rm -rf "$tmp" "${DIR:?}/${name:?}"   # only reached without $out/FEX, so $DIR/$name is incomplete
    { mkdir -p "$tmp/bin" && cp "$src/build/Bin/FEX" "$src/build/Bin/FEXServer" "$tmp/bin/" &&
      echo "$ver" > "$tmp/built-from" && mv "$tmp" "$DIR/$name"; } || { rm -rf "$tmp"; die "could not copy the build to $DIR/$name"; }
  fi
  ln -sfn "$name" "$DIR/current"
  fingerprint > "$DIR/$name/system-fex"   # tools/launch.sh and status compare it with the installed package
  # The profile attaches by path; bwrap inside Steam's container needs unprivileged user namespaces (Ubuntu 24.04
  # restricts them to binaries with a profile that allows it, like /etc/apparmor.d/FEX for the packaged FEX).
  # The profile is written by the root shell itself, from arguments: nothing is staged in a shared directory.
  # shellcheck disable=SC2016  # $1 and $2 are the root shell's arguments
  as_root sh -c 'printf "abi <abi/4.0>,\ninclude <tunables/global>\n# GameSpark patched FEX builds (system/fex-patched.sh)\nprofile gamespark-fex %s/*/bin/FEX flags=(unconfined) {\n  userns,\n}\n" "$1" > "$2" && apparmor_parser -r "$2"' \
    _ "$DIR" "$PROFILE" || die "could not load $PROFILE"
  echo "installed: $DIR/current -> $name"
}

case ${1:-} in
  install) install_build ;;
  status)
    echo "System FEX: $(system_version || echo 'not installed')"
    if [ -x "$DIR/current/bin/FEX" ]; then
      echo "Patched FEX: $(readlink "$DIR/current") (built from $(cat "$DIR/current/built-from" 2>/dev/null || echo '?'))"
      [ "$(cat "$DIR/current/built-from" 2>/dev/null)" = "$(system_version)" ] ||
        echo "  WARNING: built from a different FEX release than the system package; re-run: system/fex-patched.sh install"
      [ "$(cat "$DIR/current/system-fex" 2>/dev/null)" = "$(fingerprint)" ] ||
        echo "  WARNING: the system FEX package changed since this build was installed; re-run: system/fex-patched.sh install"
      [ "$(readlink "$DIR/current")" = "$(system_version)-gs-$(patch_hash)" ] || echo "  note: fex/patches changed since this build"
    else
      echo "Patched FEX: not installed"
    fi
    echo "AppArmor profile: $([ -f "$PROFILE" ] && echo installed || echo missing)" ;;
  uninstall)
    as_root sh -c "[ -f $PROFILE ] && apparmor_parser -R $PROFILE 2>/dev/null; rm -f $PROFILE" ||
      echo "warning: could not remove $PROFILE (needs sudo or the docker group)" >&2
    rm -rf "$DIR"
    echo "removed $DIR"; [ -e "$PROFILE" ] || echo "removed $PROFILE" ;;
  *) echo "usage: $0 install|status|uninstall" >&2; exit 2 ;;
esac
