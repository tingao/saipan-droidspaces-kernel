#!/system/bin/sh
echo "=== charge band ==="
CB=/sys/module/qpnp_adaptive_charge/parameters
echo "  upper = $(cat $CB/upper_limit 2>&1)"
echo "  lower = $(cat $CB/lower_limit 2>&1)"
echo "  blocking = $(cat $CB/blocking 2>&1)"
echo
echo "=== battery ==="
B=/sys/class/power_supply/battery
echo "  capacity = $(cat $B/capacity 2>&1)%"
echo "  status   = $(cat $B/status 2>&1)"
echo "  temp     = $(cat $B/temp 2>&1)"
echo "  health   = $(cat $B/health 2>&1)"
echo "  cycles   = $(cat $B/cycle_count 2>&1)"
echo
echo "=== cpu ==="
for c in 0 6; do
  echo "  cpu$c: gov=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor 2>&1) min=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq 2>&1) max=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq 2>&1) cur=$(cat /sys/devices/system/cpu/cpu$c/cpufreq/scaling_cur_freq 2>&1)"
done
echo
echo "=== keep-awake ==="
echo "  wake_lock   = [$(cat /sys/power/wake_lock 2>&1)]"
echo "  wake_unlock = [$(cat /sys/power/wake_unlock 2>&1)]"
echo
echo "=== watchdog alive? ==="
pgrep -f 'saipan-tuning/watchdog.sh' | head -3
echo
echo "=== android settings ==="
echo "  stay_on_while_plugged_in = $(settings get global stay_on_while_plugged_in 2>&1)"
echo "  screen_off_timeout       = $(settings get system screen_off_timeout 2>&1)"
echo "  wifi_on                  = $(settings get global wifi_on 2>&1)"
echo
echo "=== wifi / network ==="
ip -o addr show wlan0 2>&1 | head -3
echo "  route: $(ip route get 8.8.8.8 2>&1 | head -1)"
echo
echo "=== storage / container ==="
df -h /data 2>/dev/null | tail -1
/data/local/Droidspaces/bin/droidspaces show 2>&1 | tail -6
echo
echo "=== selinux ==="
getenforce
