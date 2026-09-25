#!/bin/sh
# saipan-memguard -- keep the container inside a memory cap the kernel will enforce.
#
# Works on both cgroup versions, because this handset has now run both.
#
#   v2 (current)  the whole container lives in one host-side subtree,
#                 /sys/fs/cgroup/droidspaces/bagda, and inside the container that
#                 subtree *is* /sys/fs/cgroup. So the cap is simply
#                     /sys/fs/cgroup/memory.max
#                     /sys/fs/cgroup/memory.swap.max
#                 and it covers every process by construction - no sweeping.
#
#   v1 (legacy)   the container has no subtree of its own (Droidspaces documents
#                 cgroup isolation as unavailable with --force-cgroupv1), so
#                 systemd writes its slices next to Android's at the hierarchy
#                 root. The cap therefore needs a cgroup of our own plus a sweep
#                 that keeps moving processes into it.
#
# WHY THE SWEEP/ADJ HALF EXISTS AT ALL, on either version
# -------------------------------------------------------
# Droidspaces sets oom_score_adj to -1000 on itself and every container process
# inherits it (src/utils.c, ds_oom_protect: "Set oom_score_adj to -1000
# (unkillable)"). -1000 is OOM_SCORE_ADJ_MIN: such a task is not a candidate in
# oom_kill() at all. The result, captured in /sys/fs/pstore/dmesg-ramoops-0, was
#
#     Kernel panic - not syncing: Out of memory and no killable processes...
#      (7)[10025:unattended-upgr]
#
# because mm/oom_kill.c panics unconditionally when a non-memcg, non-sysrq OOM
# finds no victim, and panic_on_oom=0 here so it is not tunable. A capped cgroup
# full of unkillable tasks does not fail safe: it wedges the workload at the cap
# (measured: alive after 30 s, usage pinned at exactly the limit, zero kills) and
# the phone panics later anyway. So the score has to be reset.
#
# SIZING: 90% of RAM for memory, 90% of swap for swap. On v1 the equivalent single
# knob was memory+swap = 90% of (RAM+swap); splitting it the same way keeps the
# combined ceiling identical. The swap half is not optional - a memory-only cap is
# satisfied by swapping, measured: a 256 MB memory cap held at 255 MB while a
# 1024 MB allocation carried on, because zram absorbed it.
set -u

MODE=${1:-once}
PCT=${MEMGUARD_PCT:-90}
INTERVAL=${MEMGUARD_INTERVAL:-10}
LOG=${MEMGUARD_LOG:-/var/log/saipan-memguard.log}

# v1 fallback paths
CG=${MEMGUARD_CGROUP:-/sys/fs/cgroup/memory/saipan-guard}
CGREL=${CG#/sys/fs/cgroup/memory}

log() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

mem_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
swap_kb=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
mem_b=$(awk -v k="$mem_kb" -v p="$PCT" 'BEGIN{printf "%.0f", k*1024*p/100}')
sw_b=$(awk -v k="$swap_kb" -v p="$PCT" 'BEGIN{printf "%.0f", k*1024*p/100}')

# Which cgroup version is actually backing this container?
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

apply_v2() {
	[ "$(cat /sys/fs/cgroup/memory.max 2>/dev/null)" = "$mem_b" ] || \
		echo "$mem_b" > /sys/fs/cgroup/memory.max 2>/dev/null
	[ "$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)" = "$sw_b" ] || \
		echo "$sw_b" > /sys/fs/cgroup/memory.swap.max 2>/dev/null
}

apply_v1() {
	mkdir -p "$CG" 2>/dev/null || return 1
	if [ "$(cat "$CG/memory.use_hierarchy" 2>/dev/null)" != "1" ]; then
		echo 1 > "$CG/memory.use_hierarchy" 2>/dev/null ||
			log "ERROR: could not enable use_hierarchy on $CG; a cap here would NOT bind"
	fi
	memsw_b=$((mem_b + sw_b))
	cur_memsw=$(cat "$CG/memory.memsw.limit_in_bytes" 2>/dev/null || echo 0)
	if [ "$mem_b" -le "${cur_memsw:-0}" ] 2>/dev/null; then
		echo "$mem_b"   > "$CG/memory.limit_in_bytes" 2>/dev/null
		echo "$memsw_b" > "$CG/memory.memsw.limit_in_bytes" 2>/dev/null
	else
		echo "$memsw_b" > "$CG/memory.memsw.limit_in_bytes" 2>/dev/null
		echo "$mem_b"   > "$CG/memory.limit_in_bytes" 2>/dev/null
	fi
}

apply_limits() {
	case "$(cgver)" in
	v2)
		apply_v2
		log "caps applied (v2): memory.max=$(cat /sys/fs/cgroup/memory.max 2>/dev/null) memory.swap.max=$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null) [${PCT}% of RAM / swap]"
		;;
	v1)
		apply_v1 || { log "cannot create $CG"; return 1; }
		log "caps applied (v1): memory=$(cat "$CG/memory.limit_in_bytes" 2>/dev/null) memory+swap=$(cat "$CG/memory.memsw.limit_in_bytes" 2>/dev/null) [${PCT}% of RAM / RAM+swap]"
		;;
	*)
		log "no cgroup memory controller visible; cap NOT applied"
		return 1
		;;
	esac
}

# Every process in this PID namespace is in the container, so this only has to
# fix the score - there is nowhere to move anything to on v2. On v1 it also has
# to move anything systemd placed outside the guard back into it.
fix_procs() {
	moved=0
	adjfixed=0
	ver=$(cgver)

	for d in /proc/[0-9]*; do
		pid=${d#/proc/}
		[ -d "$d" ] || continue

		if [ "$ver" = v1 ]; then
			cur=$(sed -n 's/^[0-9]*:memory:\(.*\)$/\1/p' "$d/cgroup" 2>/dev/null)
			if [ -n "$cur" ]; then
				case "$cur" in
				"$CGREL" | "$CGREL"/*) ;;
				*) echo "$pid" > "$CG/cgroup.procs" 2>/dev/null && moved=$((moved + 1)) ;;
				esac
			fi
		fi

		a=$(cat "$d/oom_score_adj" 2>/dev/null)
		if [ -n "$a" ] && [ "$a" != "0" ]; then
			echo 0 > "$d/oom_score_adj" 2>/dev/null && adjfixed=$((adjfixed + 1))
		fi
	done

	[ "$moved" -gt 0 ] && log "moved $moved process(es) into $CGREL"
	[ "$adjfixed" -gt 0 ] && log "reset oom_score_adj on $adjfixed process(es) so the kernel has a victim"
	return 0
}

case "$MODE" in
once)
	apply_limits || exit 1
	exit 0
	;;
watch)
	apply_limits >/dev/null 2>&1 || true
	log "watch loop started (cgroup $(cgver), interval ${INTERVAL}s)"
	while :; do
		fix_procs
		apply_limits >/dev/null 2>&1 || true
		sleep "$INTERVAL"
	done
	;;
*)
	echo "usage: $0 [once|watch]" >&2
	exit 2
	;;
esac
