#!/system/bin/sh
# Delegate the cgroup v2 memory controller down to each Droidspaces container.
#
# THE PROBLEM
# -----------
# In cgroup v2 a controller is only usable in a cgroup if the *parent* lists it
# in cgroup.subtree_control. A container's cgroup is
#
#     /sys/fs/cgroup/droidspaces/<name>
#
# so BOTH /sys/fs/cgroup and /sys/fs/cgroup/droidspaces must carry "+memory"
# before /sys/fs/cgroup/droidspaces/<name>/memory.max exists:
#
#   root            cgroup.subtree_control = memory
#     droidspaces/  cgroup.subtree_control = memory
#       bagda/      -> memory.max, memory.swap.max, memory.events, memory.stat
#
# Without it the container cgroup's cgroup.controllers is empty, Droidspaces'
# ds_cgroup_apply_limits() finds no "memory" and warns
#   [CGROUP] 'memory' controller not supported, limit skipped.
# and the container is simply uncapped.
#
# WHY THIS HAS TO BE ON THE HOST
# ------------------------------
# The container runs in its own cgroup namespace, so its /sys/fs/cgroup *is* its
# own subtree. It cannot see, let alone write, its parent's subtree_control. Only
# the host can. Droidspaces itself does not do this - its cgroup.c only reads
# cgroup.controllers to decide whether a limit is possible.
#
# WHY IT LOOPS
# ------------
# /sys/fs/cgroup/droidspaces is created when a container starts and removed when
# it stops, so the delegation has to be (re)applied, not set once at boot.

LOG=/data/local/Droidspaces/Logs/cgroupv2-guard.log
SEEN=/data/adb/modules/saipan-cgroupv2/.delegated
mkdir -p /data/local/Droidspaces/Logs 2>/dev/null

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG" 2>/dev/null; }

ROOT=/sys/fs/cgroup
MID=$ROOT/droidspaces

delegate() {
	# Root level. Harmless and idempotent to rewrite; the root cgroup is exempt
	# from the "no processes in a cgroup with subtree_control" rule.
	if ! grep -qw memory "$ROOT/cgroup.subtree_control" 2>/dev/null; then
		if echo "+memory" > "$ROOT/cgroup.subtree_control" 2>/dev/null; then
			log "root: enabled +memory"
		fi
	fi

	# Middle level - only exists while a container does.
	[ -d "$MID" ] || return 0
	if [ -w "$MID/cgroup.subtree_control" ] &&
		! grep -qw memory "$MID/cgroup.subtree_control" 2>/dev/null; then
		if echo "+memory" > "$MID/cgroup.subtree_control" 2>/dev/null; then
			log "droidspaces/: enabled +memory"
		fi
	fi

	# Report once per container when the controller actually lands. The marker
	# cannot live inside the cgroup - cgroupfs has no writable regular files -
	# so it goes in the module directory.
	for c in "$MID"/*; do
		[ -d "$c" ] || continue
		n=$(basename "$c")
		[ -e "$c/memory.max" ] || continue
		grep -qxF "$n" "$SEEN" 2>/dev/null && continue
		echo "$n" >> "$SEEN" 2>/dev/null
		log "$n: memory controller delegated (memory.max present)"
	done
	return 0
}

log "saipan-cgroupv2 guard starting"
while :; do
	delegate
	sleep 5
done
