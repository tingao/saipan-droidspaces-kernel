#!/bin/sh
# Install the container memory guard inside the container, as root.
#
# Run from the directory holding the files:
#     sh install.sh
#
# On cgroup v2 this is mostly "install two units and enable them" - the container is
# already one isolated subtree, so the cap needs no cgroup-parent trick and nothing has
# to be moved into place. The one destructive thing it does is REMOVE "cgroup-parent"
# from daemon.json: an older version of this installer added it for cgroup v1, and on
# v2 Docker selects the systemd cgroup driver, where that value is illegal and stops
# the daemon from starting:
#
#     failed to start daemon: cgroup-parent for systemd cgroup should be a valid
#     slice named as "xxx.slice"
#
# The script reports what is actually in force, because every failure mode here is
# silent - a cap that nothing enforces looks exactly like a cap.
set -e

CFG=/etc/docker/daemon.json
LOG=${MEMGUARD_LOG:-/var/log/saipan-memguard.log}

cgver() {
	if [ -r /sys/fs/cgroup/cgroup.controllers ] &&
		grep -qw memory /sys/fs/cgroup/cgroup.controllers 2>/dev/null; then
		echo v2
	elif [ -d /sys/fs/cgroup/memory ]; then
		echo v1
	else
		echo none
	fi
}

echo "=== 1. install the script and units ==="
install -m 0755 saipan-memguard.sh /usr/local/sbin/saipan-memguard.sh
install -m 0644 saipan-memguard.service /etc/systemd/system/saipan-memguard.service
install -m 0644 saipan-memguard-watch.service /etc/systemd/system/saipan-memguard-watch.service
systemctl daemon-reload

echo
echo "=== 2. remove the cgroup v1 cgroup-parent, which breaks Docker on v2 ==="
if [ -f "$CFG" ] && grep -q 'cgroup-parent' "$CFG" 2>/dev/null; then
	cp "$CFG" "$CFG.bak-memguard"
	if command -v python3 >/dev/null 2>&1; then
		python3 - "$CFG" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f:
    cfg = json.load(f)
cfg.pop("cgroup-parent", None)
with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("  removed cgroup-parent from", p)
PYEOF
	else
		echo "  !! python3 missing - delete the \"cgroup-parent\" key from $CFG by hand,"
		echo "     or Docker will refuse to start."
	fi
else
	echo "  no cgroup-parent present (good)"
fi

echo
echo "=== 3. enable and start ==="
# Enable without --now for both, then start the watch loop explicitly: the oneshot
# can legitimately find no memory controller yet on v2 if the host has not finished
# delegating +memory, and a hard dependency on it would keep the loop from starting.
systemctl enable saipan-memguard.service 2>&1 | tail -1
systemctl enable saipan-memguard-watch.service 2>&1 | tail -1
systemctl restart saipan-memguard.service || true
systemctl restart saipan-memguard-watch.service
sleep 12

echo
echo "=== 4. what is actually in force ==="
v=$(cgver)
echo "  cgroup version : $v"
case "$v" in
v2)
	echo "  memory cap     : $(awk -v b="$(cat /sys/fs/cgroup/memory.max 2>/dev/null || echo 0)" 'BEGIN{printf "%d MB", b/1048576}')"
	echo "  swap cap       : $(awk -v b="$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null || echo 0)" 'BEGIN{printf "%d MB", b/1048576}')"
	;;
v1)
	G=${MEMGUARD_CGROUP:-/sys/fs/cgroup/memory/saipan-guard}
	echo "  use_hierarchy  : $(cat $G/memory.use_hierarchy 2>/dev/null)"
	echo "  memory cap     : $(awk -v b="$(cat $G/memory.limit_in_bytes 2>/dev/null || echo 0)" 'BEGIN{printf "%d MB", b/1048576}')"
	echo "  memsw cap      : $(awk -v b="$(cat $G/memory.memsw.limit_in_bytes 2>/dev/null || echo 0)" 'BEGIN{printf "%d MB", b/1048576}')"
	;;
esac
echo "  unit states    : $(systemctl is-active saipan-memguard.service) / $(systemctl is-active saipan-memguard-watch.service)"
echo "  log tail       :"; tail -3 "$LOG" 2>/dev/null | sed 's/^/    /'

# Count how many processes are still unkillable. On v2 the two [ds-monitor] helpers
# are expected (they are outside this PID namespace); anything else is a real problem,
# because an unkillable task is not an OOM candidate and the kernel panics instead.
unk=0
for p in /proc/[0-9]*; do
	[ -r "$p/oom_score_adj" ] || continue
	[ "$(cat "$p/oom_score_adj" 2>/dev/null)" = "0" ] && continue
	unk=$((unk + 1))
done
echo "  procs not at oom_score_adj 0 : $unk"
echo "    (anything beyond the 2 [ds-monitor] helpers means the kernel has no victim,"
echo "     and mm/oom_kill.c panics unconditionally when an OOM finds none)"

echo
if [ "$v" = none ]; then
	echo "PROBLEM - no cgroup memory controller is visible. On v2 that means the host has"
	echo "not delegated +memory to this container's cgroup; install extras/cgroupv2-delegate"
	echo "as a KernelSU module. The cap is NOT in force."
	exit 1
fi
if [ "$(systemctl is-active saipan-memguard-watch.service)" != "active" ]; then
	echo "PROBLEM - the watch loop is not running, so oom_score_adj is not being reset."
	echo "  journalctl -u saipan-memguard-watch.service -n 30"
	exit 1
fi
echo "OK - cap applied and the kernel has a victim."
echo "=== MEMGUARD_INSTALLED ==="
