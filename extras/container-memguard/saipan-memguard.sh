#!/bin/sh
# Give the containers >=90% of the phone's memory, in a way that actually binds.
#
# WHY THIS IS NOT JUST "write a limit on /docker":
#
# cgroup v1 enforces memory limits hierarchically only when memory.use_hierarchy is 1, and on
# this kernel it defaults to 0. Measured: a child cgroup reached 1008 MB under a 256 MB parent
# cap with failcnt 0 - the cap was never consulted. From mm/memcontrol.c:
#
#     if ((!parent_memcg || !parent_memcg->use_hierarchy) && (val == 1 || val == 0)) {
#             if (!memcg_has_children(memcg))
#                     memcg->use_hierarchy = val;
#             else
#                     retval = -EBUSY;
#     }
#
# so use_hierarchy=1 can only be set on a cgroup that has NO children. Docker's own /docker
# cannot be used: it has children as soon as a container runs, and even stopping Docker and
# removing them left the write refused. Hence a cgroup of our own, created before dockerd
# starts (this script runs Before=docker.service) and selected with Docker's cgroup-parent.
#
# It is fresh every boot, so it is always childless at the moment it is configured, and the
# cap then applies to every container underneath it.
#
# TWO THINGS THAT MAKE THE DIFFERENCE BETWEEN A CAP AND A COMFORTABLE ILLUSION:
#
#   * memory.memsw.limit_in_bytes, not just memory.limit_in_bytes. A memory-only cap is
#     satisfied by swapping, so the process carries on. Measured: a 256 MB memory cap held at
#     255 MB while a 1024 MB allocation continued happily. zram made the difference.
#   * write order. The invariant memory.limit <= memory.memsw.limit holds at all times, so
#     lowering means memory first and raising means memsw first. A fixed order silently fails
#     one direction.
#
# Sizing: 90% of RAM and 90% of RAM+swap, so containers keep at least 90% of the handset
# available while a runaway is still stopped short of starving Android.
set -u

CG=${MEMGUARD_CGROUP:-/sys/fs/cgroup/memory/saipan-guard}
PCT=${MEMGUARD_PCT:-90}
LOG=${MEMGUARD_LOG:-/var/log/saipan-memguard.log}

log() { echo "$(date -Is) $*" >> "$LOG" 2>/dev/null; }

mem_kb=$(awk '/^MemTotal/{print $2}' /proc/meminfo)
swap_kb=$(awk '/^SwapTotal/{print $2}' /proc/meminfo)
mem_b=$(awk -v k="$mem_kb" -v p="$PCT" 'BEGIN{printf "%.0f", k*1024*p/100}')
memsw_b=$(awk -v k="$mem_kb" -v s="$swap_kb" -v p="$PCT" 'BEGIN{printf "%.0f", (k+s)*1024*p/100}')

mkdir -p "$CG" 2>/dev/null || { log "cannot create $CG"; exit 1; }

if [ "$(cat "$CG/memory.use_hierarchy" 2>/dev/null)" != "1" ]; then
  if echo 1 > "$CG/memory.use_hierarchy" 2>/dev/null; then
    log "use_hierarchy enabled on $CG - hierarchical limits are now enforced"
  else
    log "ERROR: could not enable use_hierarchy on $CG; a cap here would NOT bind"
  fi
fi

cur_memsw=$(cat "$CG/memory.memsw.limit_in_bytes" 2>/dev/null || echo 0)
if [ "$mem_b" -le "${cur_memsw:-0}" ] 2>/dev/null; then
  echo "$mem_b" > "$CG/memory.limit_in_bytes" 2>/dev/null
  echo "$memsw_b" > "$CG/memory.memsw.limit_in_bytes" 2>/dev/null
else
  echo "$memsw_b" > "$CG/memory.memsw.limit_in_bytes" 2>/dev/null
  echo "$mem_b" > "$CG/memory.limit_in_bytes" 2>/dev/null
fi

log "caps applied: memory $(awk -v b="$mem_b" 'BEGIN{printf "%d", b/1048576}') MB, memory+swap $(awk -v b="$memsw_b" 'BEGIN{printf "%d", b/1048576}') MB (${PCT}% of RAM / RAM+swap)"
log "in force: use_hierarchy=$(cat "$CG/memory.use_hierarchy" 2>/dev/null) memory=$(cat "$CG/memory.limit_in_bytes" 2>/dev/null) memsw=$(cat "$CG/memory.memsw.limit_in_bytes" 2>/dev/null)"
exit 0
