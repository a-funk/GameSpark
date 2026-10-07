#!/bin/bash
# System-wide FEX (PPA build tuned for the CPU) with its own x86 RootFS, graphics thunking on, and Valve's
# Steam launcher running under it: a second Steam next to the snap (the snap keeps working).
# Why: the snap bundles FEX 2603 (armv8.0 build) and its Steam container cannot reach the native Vulkan driver
# (docs/FINDINGS.md). Steps follow Mitchell Augustin's fex_autoinstall proof of concept
# (https://github.com/MitchellAugustin/fex_autoinstall), reimplemented here.
#
# Usage: system/fex-system.sh install|share-snap|status|uninstall
#   Launch Steam afterwards with: FEXBash steam   (or GAMESPARK_STEAM=fex tools/steam-console.sh)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
VARIANT=$(lscpu | grep -qE "dit|flagm2" && echo armv8.4 || echo armv8.2)
FEX_CFG=${XDG_CONFIG_HOME:-$HOME/.config}/fex-emu          # FEX 2610+ (older builds used ~/.fex-emu)
ROOTFS_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/fex-emu/RootFS
TMP=$(mktemp -d /tmp/gamespark-fex.XXXXXX); trap 'rm -rf "$TMP"' EXIT

install_packages() {
  as_root sh -c "add-apt-repository -y ppa:fex-emu/fex >/dev/null && apt-get update -qq && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq fex-emu-$VARIANT fex-emu-wine mesa-vulkan-drivers >/dev/null"
  curl -fsSL -o "$TMP/steam-launcher.deb" https://repo.steampowered.com/steam/archive/stable/steam-launcher_latest_all.deb
  chmod 644 "$TMP/steam-launcher.deb"; chmod 755 "$TMP"
  as_root sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y -qq $TMP/steam-launcher.deb >/dev/null"
}

install_rootfs_and_config() {
  local sqsh fs
  sqsh=$(ls "$ROOTFS_DIR"/*.sqsh 2>/dev/null | head -1)
  if [ -z "$sqsh" ]; then
    # Headless (with a display it prompts and shows a progress window on the TV); keep the image compressed.
    env -u DISPLAY -u WAYLAND_DISPLAY FEXRootFSFetcher -y -a
    sqsh=$(ls "$ROOTFS_DIR"/*.sqsh 2>/dev/null | head -1)
  fi
  [ -n "$sqsh" ] || die "FEXRootFSFetcher produced no image in $ROOTFS_DIR"
  fs=$(basename "$sqsh" .sqsh)
  # Extracted, because the DLSS step writes NVIDIA's x86 libraries into it.
  [ -d "$ROOTFS_DIR/$fs" ] || unsquashfs -q -d "$ROOTFS_DIR/$fs" "$sqsh" >/dev/null
  mkdir -p "$FEX_CFG"
  [ -f "$FEX_CFG/Config.json" ] && cp "$FEX_CFG/Config.json" "$FEX_CFG/Config.json.bak-$(date +%s)"
  # Unlisted options keep FEX's built-in defaults; graphics calls go to the native arm64 driver.
  printf '{"Config":{"RootFS":"%s"},"ThunksDB":{"Vulkan":1,"GL":1}}\n' "$fs" > "$FEX_CFG/Config.json"
}

# Ubuntu 24.04 restricts unprivileged user namespaces; Steam (running as /usr/bin/FEX), its container (bwrap)
# and FEXBash need them.
install_apparmor() {
  local p
  for p in steam:/usr/bin/steam FEX:/usr/bin/FEX FEXBash:/usr/bin/FEXBash bwrap:/{usr/,}bin/bwrap; do
    printf 'abi <abi/4.0>,\ninclude <tunables/global>\nprofile %s %s flags=(unconfined) {\n  userns,\n  include if exists <local/%s>\n}\n' \
      "${p%%:*}" "${p#*:}" "${p%%:*}" > "$TMP/${p%%:*}"
  done
  chmod 644 "$TMP"/steam "$TMP"/FEX "$TMP"/FEXBash "$TMP"/bwrap
  as_root sh -c "cp $TMP/steam $TMP/FEX $TMP/FEXBash $TMP/bwrap /etc/apparmor.d/ && \
    apparmor_parser -r /etc/apparmor.d/steam /etc/apparmor.d/FEX /etc/apparmor.d/FEXBash /etc/apparmor.d/bwrap"
}

# DLSS under Proton needs NVIDIA's x86 NGX DLLs and libraries inside the RootFS, matching the host driver.
install_ngx() {
  local ver fs dso d
  ver=$(cat /sys/module/nvidia/version 2>/dev/null || nvidia-smi --query-gpu=driver_version --format=csv,noheader)
  fs=$ROOTFS_DIR/$(python3 -I -c 'import json,os; print(json.load(open(os.path.expanduser(os.environ.get("XDG_CONFIG_HOME", "~/.config") + "/fex-emu/Config.json")))["Config"]["RootFS"])')
  curl -fsSL -o "$TMP/nv.run" "https://download.nvidia.com/XFree86/Linux-x86_64/$ver/NVIDIA-Linux-x86_64-$ver.run"
  (cd "$TMP" && sh nv.run -x --target nv >/dev/null)
  mkdir -p "$fs/usr/lib/x86_64-linux-gnu/nvidia/wine"
  cp "$TMP"/nv/*.dll "$fs/usr/lib/x86_64-linux-gnu/nvidia/wine/"
  for d in "x86_64-linux-gnu:$TMP/nv" "i386-linux-gnu:$TMP/nv/32"; do
    for dso in "${d#*:}"/*.so."$ver"; do
      cp -f "$dso" "$fs/lib/${d%%:*}/"
      ( cd "$fs/lib/${d%%:*}" && b=$(basename "$dso" | cut -d. -f1-2) && ln -sf "$(basename "$dso")" "$b.0" && ln -sf "$(basename "$dso")" "$b.1" && ln -sf "$(basename "$dso")" "$b.2" )
    done
  done
  echo "NGX libraries for driver $ver installed into $fs"
}

case "${1:-status}" in
  install)
    install_packages && install_rootfs_and_config && install_apparmor && install_ngx && "$0" status ;;
  status)
    echo "FEX: $(dpkg-query -W -f='${Package} ${Version}' "fex-emu-$VARIANT" 2>/dev/null || echo not installed)"
    echo "Steam launcher: $(dpkg-query -W -f='${Version}' steam-launcher 2>/dev/null || echo not installed)"
    echo "RootFS: $(ls "$ROOTFS_DIR" 2>/dev/null | tr '\n' ' ')"
    echo "Config: $(cat "$FEX_CFG/Config.json" 2>/dev/null)"
    FEXGetConfig --tso-emulation-info 2>/dev/null | sed 's/^/TSO: /' ;;
  share-snap)
    # Run Valve's launcher (under this FEX) on the snap's Steam folder: same login, library, Proton prefixes and
    # settings, so only FEX differs between the two setups. Only one of the two Steams may run at a time.
    SNAP_STEAM=$HOME/snap/steam/common/.local/share/Steam
    [ -d "$SNAP_STEAM" ] || die "no snap Steam folder at $SNAP_STEAM"
    pgrep -f "[u]buntu12_32/steam " >/dev/null && die "close Steam first"
    if [ ! -L "$HOME/.local/share/Steam" ]; then
      [ -e "$HOME/.local/share/Steam" ] && mv "$HOME/.local/share/Steam" "$HOME/.local/share/Steam.fex-own"
      ln -s "$SNAP_STEAM" "$HOME/.local/share/Steam"
    fi
    mkdir -p "$HOME/.steam"
    cp "$HOME/snap/steam/common/.steam/registry.vdf" "$HOME/.steam/registry.vdf"   # remembered account name for auto-login
    echo "Steam folder: $(readlink "$HOME/.local/share/Steam")" ;;
  uninstall)
    as_root sh -c "apt-get remove -y -qq fex-emu-$VARIANT fex-emu-wine steam-launcher >/dev/null; add-apt-repository -y -r ppa:fex-emu/fex >/dev/null; \
      rm -f /etc/apparmor.d/steam /etc/apparmor.d/FEX /etc/apparmor.d/FEXBash /etc/apparmor.d/bwrap"
    echo "Removed packages and profiles. RootFS and config left in $ROOTFS_DIR and $FEX_CFG (delete by hand)." ;;
  *) die "usage: $0 install|status|uninstall" ;;
esac
