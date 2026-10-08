#!/bin/bash
# Boot straight into Steam Big Picture on the TV.
# Usage: system/console-mode.sh enable [snap|fex] | disable
#   enable   GDM automatic login for the current user + a GNOME autostart entry running tools/steam-console.sh
#            with that Steam setup (default snap; fex needs system/fex-system.sh, see lib/env.sh)
#   disable  remove both (GDM config restored from the backup taken on enable)
# Automatic login means anyone at the TV gets this desktop session.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
USER_NAME=$(id -un); AUTOSTART=$HOME/.config/autostart/gamespark-console.desktop
case "${1:-}" in
  enable)
    as_root sh -c "[ -f /etc/gdm3/custom.conf.gamespark.bak ] || cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.gamespark.bak; \
      grep -q '^AutomaticLoginEnable=true' /etc/gdm3/custom.conf || \
      sed -i 's/^\[daemon\]\$/[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$USER_NAME/' /etc/gdm3/custom.conf"
    mkdir -p "$(dirname "$AUTOSTART")"
    SETUP=${2:-snap}; case $SETUP in snap|fex) ;; *) die "setup must be snap or fex" ;; esac
    printf '[Desktop Entry]\nType=Application\nName=Steam console mode\nExec=env GAMESPARK_STEAM=%s %s\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=5\n' \
      "$SETUP" "$ROOT/tools/steam-console.sh" > "$AUTOSTART"
    echo "enabled: autologin for $USER_NAME, autostart $AUTOSTART ($SETUP Steam)" ;;
  disable)
    as_root sh -c "[ -f /etc/gdm3/custom.conf.gamespark.bak ] && cp /etc/gdm3/custom.conf.gamespark.bak /etc/gdm3/custom.conf"
    rm -f "$AUTOSTART"; echo "disabled" ;;
  *) die "usage: $0 enable [snap|fex] | disable" ;;
esac
