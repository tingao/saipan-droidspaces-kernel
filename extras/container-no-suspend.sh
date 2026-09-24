#!/bin/sh
# Stop the CONTAINER from ever suspending the PHONE.
#
# The prior S8/S21 projects hit this: the container's systemd-logind saw the handset's
# lid/power/idle events and ran systemd-suspend.service, which (with hardware access
# enabled) suspends the whole phone. It only failed with "Device or resource busy" by
# luck. On a headless server phone a successful suspend means the box goes off the air
# until somebody touches it.
set -e

echo "=== 1. logind: ignore the handset's lid / power / idle events ==="
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/10-no-sleep.conf <<'EOF'
# The container may see the handset's lid/power events. It must never act on them:
# a suspend here suspends the whole phone.
[Login]
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleLidSwitchDocked=ignore
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
IdleAction=ignore
EOF
echo "  wrote /etc/systemd/logind.conf.d/10-no-sleep.conf"

echo
echo "=== 2. mask every path into sleep ==="
for u in sleep.target suspend.target hibernate.target hybrid-sleep.target \
         systemd-suspend.service systemd-hibernate.service systemd-hybrid-sleep.service; do
  systemctl mask "$u" >/dev/null 2>&1 || true
  printf '  %-32s %s\n' "$u" "$(systemctl is-enabled $u 2>&1)"
done

echo
echo "=== 3. reset any previous failure state ==="
systemctl reset-failed systemd-suspend.service 2>/dev/null || true
systemctl daemon-reload

echo
echo "=== 4. verify ==="
echo -n "  is-system-running : "; systemctl is-system-running 2>&1 || true
echo -n "  failed units      : "; systemctl --failed --no-legend 2>/dev/null | wc -l
echo "  a suspend attempt now:"
systemctl suspend 2>&1 | head -3 | sed 's/^/    /'
echo -n "  host wake_lock    : "; cat /sys/power/wake_lock 2>/dev/null || echo "(not visible)"
echo "=== CONTAINER_NO_SUSPEND_GUARD_DONE ==="
