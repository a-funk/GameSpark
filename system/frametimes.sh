#!/bin/bash
# Frame-time capture for any game (MangoHud), including games without a built-in benchmark.
# Usage: system/frametimes.sh install|status
#
# Under FEX's Vulkan thunking a game's Vulkan calls run through the native arm64 loader inside Steam's container, so
# the layer has to be arm64. install builds a self-contained copy of Ubuntu's arm64 MangoHud in $SG_DATA/vklayers
# (its spdlog/fmt dependencies are not in Steam's runtime), which the container sees at the same path. bench/run.sh
# FRAMES=SECS then turns it on for one run through tools/launch.sh, setting VK_IMPLICIT_LAYER_PATH inside the
# container: pressure-vessel's own value there overrides VK_ADD_IMPLICIT_LAYER_PATH.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
V=$SG_DATA/vklayers
case "${1:-status}" in
  install)
    as_root sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mangohud patchelf >/dev/null" || die "apt failed"
    lib=$(dpkg -L mangohud | grep -m1 '/libMangoHud.so$') && json=$(dpkg -L mangohud | grep -m1 'implicit_layer.d/.*\.json$')
    mkdir -p "$V"
    cp "$lib" "$V/"
    for dep in $(ldd "$lib" | grep -oE '/[^ ]*lib(spdlog|fmt)\.[^ ]*'); do cp -L "$dep" "$V/"; done
    patchelf --set-rpath '$ORIGIN' "$V/libMangoHud.so"
    sed "s|\"library_path\": *\"[^\"]*\"|\"library_path\": \"$V/libMangoHud.so\"|" "$json" > "$V/MangoHud.json"
    "$0" status ;;
  status)
    [ -f "$V/MangoHud.json" ] && grep -q "$V/libMangoHud.so" "$V/MangoHud.json" || die "not installed ($0 install)"
    MANGOHUD=1 VK_ADD_IMPLICIT_LAYER_PATH=$V VK_LOADER_DEBUG=layer vulkaninfo --summary 2>&1 \
      | grep -q "Insert instance layer \"VK_LAYER_MANGOHUD" && echo "frame capture ready: $V" || die "layer does not load (vulkaninfo)" ;;
  *) die "usage: $0 install|status" ;;
esac
