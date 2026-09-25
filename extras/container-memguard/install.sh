#!/bin/sh
# Install the container memory guard inside the container, as root.
#
# Run from the directory holding the three files:
#     sh install.sh
#
# It installs the script and unit, enables the unit, points Docker at the guard cgroup, and
# then reports what is actually in force - because a silent failure here means the cap does
# nothing at all, which is exactly the trap this directory exists to avoid.
set -e

GUARD=${MEMGUARD_CGROUP:-/sys/fs/cgroup/memory/saipan-guard}
CFG=/etc/docker/daemon.json

echo "=== 1. install the script and unit ==="
install -m 0755 saipan-memguard.sh /usr/local/sbin/saipan-memguard.sh
install -m 0644 saipan-memguard.service /etc/systemd/system/saipan-memguard.service
systemctl daemon-reload
systemctl enable saipan-memguard.service 2>&1 | tail -1

echo
echo "=== 2. point Docker at the guard cgroup ==="
if [ -f "$CFG" ]; then
  cp "$CFG" "$CFG.bak-memguard"
  if command -v python3 >/dev/null 2>&1; then
    python3 - "$CFG" <<'PYEOF'
import json, sys
p = sys.argv[1]
with open(p) as f:
    cfg = json.load(f)
cfg["cgroup-parent"] = "/saipan-guard"
with open(p, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print("  cgroup-parent set in", p)
PYEOF
  else
    echo "  !! python3 is missing; add \"cgroup-parent\": \"/saipan-guard\" to $CFG by hand"
    echo "     and restart docker."
    exit 1
  fi
else
  printf '{\n  "cgroup-parent": "/saipan-guard"\n}\n' > "$CFG"
  echo "  created $CFG"
fi

echo
echo "=== 3. create the guard and restart Docker ==="
rmdir "$GUARD" 2>/dev/null || true
/usr/local/sbin/saipan-memguard.sh
systemctl restart docker
sleep 8

echo
echo "=== 4. what is actually in force ==="
echo "  use_hierarchy : $(cat $GUARD/memory.use_hierarchy 2>/dev/null)"
echo "  memory cap    : $(awk -v b="$(cat $GUARD/memory.limit_in_bytes 2>/dev/null || echo 0)" 'BEGIN{printf "%d MB", b/1048576}')"
echo "  memsw cap     : $(awk -v b="$(cat $GUARD/memory.memsw.limit_in_bytes 2>/dev/null || echo 0)" 'BEGIN{printf "%d MB", b/1048576}')"
echo "  containers    : $(docker ps --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
for c in $(docker ps -q 2>/dev/null); do
  p=$(docker inspect -f '{{.State.Pid}}' "$c" 2>/dev/null)
  echo "    $(docker inspect -f '{{.Name}}' $c) cgroup: $(grep memory /proc/$p/cgroup 2>/dev/null | cut -d: -f3)"
done

echo
if [ "$(cat $GUARD/memory.use_hierarchy 2>/dev/null)" = "1" ]; then
  echo "OK - hierarchical, so the cap binds on every container under it."
else
  echo "PROBLEM - use_hierarchy is not 1, so the cap does NOT bind. Check the log:"
  echo "  tail -5 /var/log/saipan-memguard.log"
  exit 1
fi
echo "=== MEMGUARD_INSTALLED ==="
