#!/bin/bash
# Boot straight into Steam Big Picture on the TV.
# Usage: system/console-mode.sh enable|disable
#   enable   GDM automatic login for the current user + a GNOME autostart entry running tools/steam-console.sh
#   disable  remove both (GDM config restored from the backup taken on enable)
# Automatic login means anyone at the TV gets this desktop session.
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
USER_NAME=$(id -un); AUTOSTART=$HOME/.config/autostart/spark-gaming-console.desktop
case "${1:-}" in
  enable)
    as_root sh -c "[ -f /etc/gdm3/custom.conf.spark-gaming.bak ] || cp /etc/gdm3/custom.conf /etc/gdm3/custom.conf.spark-gaming.bak; \
      grep -q '^AutomaticLoginEnable=true' /etc/gdm3/custom.conf || \
      sed -i 's/^\[daemon\]\$/[daemon]\nAutomaticLoginEnable=true\nAutomaticLogin=$USER_NAME/' /etc/gdm3/custom.conf"
    mkdir -p "$(dirname "$AUTOSTART")"
    printf '[Desktop Entry]\nType=Application\nName=Steam console mode\nExec=%s\nX-GNOME-Autostart-enabled=true\nX-GNOME-Autostart-Delay=5\n' \
      "$ROOT/tools/steam-console.sh" > "$AUTOSTART"
    echo "enabled: autologin for $USER_NAME, autostart $AUTOSTART" ;;
  disable)
    as_root sh -c "[ -f /etc/gdm3/custom.conf.spark-gaming.bak ] && cp /etc/gdm3/custom.conf.spark-gaming.bak /etc/gdm3/custom.conf"
    rm -f "$AUTOSTART"; echo "disabled" ;;
  *) die "usage: $0 enable|disable" ;;
esac
