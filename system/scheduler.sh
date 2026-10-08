#!/bin/bash
# Make sched_ext's scx_bpfland the system scheduler, preferring the fastest cores (GB10: Cortex-X925).
# Measured on Cyberpunk 2077: +12% average fps vs the default scheduler, matching manual core pinning.
# scx_lavd is avoided: it panics on GB10 (cpu_order.rs unwrap on missing CPU cluster info, scx 1.1.2).
#
# Usage: system/scheduler.sh install|enable|disable|status
#   install  apt-get install scx (Canonical's nvidia-desktop PPA on DGX OS), then enable
#   enable   write /etc/default/scx and enable scx.service (persists across reboots)
#   disable  stop and disable scx.service (back to the kernel's default scheduler)
set -u
ROOT=$(cd "$(dirname "$0")/.." && pwd); . "$ROOT/lib/env.sh"
SCHED=${SCX_SCHEDULER:-scx_bpfland}; FLAGS=${SCX_FLAGS:--m performance}
case "${1:-status}" in
  install)
    as_root sh -c "DEBIAN_FRONTEND=noninteractive apt-get install -y scx" | tail -1
    "$0" enable ;;
  enable)
    [ -d /sys/kernel/sched_ext ] || die "kernel has no sched_ext"
    as_root sh -c "[ -f /etc/default/scx.orig ] || cp /etc/default/scx /etc/default/scx.orig; printf 'SCX_SCHEDULER=%s\nSCX_FLAGS=\"%s\"\n' '$SCHED' '$FLAGS' > /etc/default/scx && systemctl enable --now scx.service && systemctl restart scx.service"
    sleep 3; "$0" status ;;
  disable)
    as_root systemctl disable --now scx.service; sleep 1; "$0" status ;;
  status)
    echo "sched_ext: $(cat /sys/kernel/sched_ext/state 2>/dev/null || echo unavailable) $(cat /sys/kernel/sched_ext/root/ops 2>/dev/null)"
    echo "scx.service: $(systemctl is-enabled scx.service 2>/dev/null) / $(systemctl is-active scx.service 2>/dev/null)"
    echo "fast cores: $(fast_cpus)" ;;
  *) die "usage: $0 install|enable|disable|status" ;;
esac
