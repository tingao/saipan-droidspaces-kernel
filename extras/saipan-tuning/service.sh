#!/system/bin/sh
# saipan server tuning -- applied once at boot by the KernelSU module pipeline.
#
# Applies the battery charge band, the keep-awake wakeup source and the CPU clock
# ceilings, then starts a detached 60s watchdog that re-asserts them (Android's own
# power/thermal daemons happily rewrite these files underneath us).
#
# Everything it touches is read back and logged, so the result is verifiable rather
# than assumed.

MODDIR=${0%/*}
LOG=/data/local/saipan-tuning.log
. "$MODDIR/tuning.conf" 2>/dev/null || true

# Defaults if tuning.conf is missing
: "${CHARGE_UPPER:=80}"
: "${CHARGE_LOWER:=75}"
: "${AWAKEN_POLICY:=charging}"
: "${CPU_LITTLE_MIN:=500000}"
: "${CPU_LITTLE_MAX:=2000000}"
: "${CPU_BIG_MIN:=725000}"
: "${CPU_BIG_MAX:=2203000}"
: "${CPU_GOVERNOR:=schedutil}"
: "${WIFI_WATCHDOG:=1}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=== saipan-tuning service.sh start ==="

# ---------------------------------------------------------------- charge band
CB=/sys/module/qpnp_adaptive_charge/parameters
if [ -d "$CB" ]; then
  if [ "$CHARGE_UPPER" = "-1" ]; then
    echo -1 > "$CB/upper_limit" 2>/dev/null
    echo -1 > "$CB/lower_limit" 2>/dev/null
    log "charge band: disabled (stock behaviour)"
  else
    # ORDER MATTERS: writing upper_limit resets lower_limit to -1 in this driver, so
    # upper must be written first and lower second. Verified on-device:
    #   echo 75 > lower; echo 80 > upper   -> reads back 80/-1   (lower lost)
    #   echo 80 > upper; echo 75 > lower   -> reads back 80/75   (correct)
    echo "$CHARGE_UPPER" > "$CB/upper_limit" 2>/dev/null
    echo "$CHARGE_LOWER" > "$CB/lower_limit" 2>/dev/null
    log "charge band: upper=$(cat $CB/upper_limit 2>/dev/null) lower=$(cat $CB/lower_limit 2>/dev/null) (wanted $CHARGE_UPPER/$CHARGE_LOWER) blocking=$(cat $CB/blocking 2>/dev/null)"
  fi
else
  log "charge band: $CB not present - qpnp_adaptive_charge not loaded?"
fi

# ---------------------------------------------------------------- keep-awake
WAKELOCK=/sys/power/wake_lock
WAKEUNLOCK=/sys/power/wake_unlock
LOCKNAME=saipan-awake
if [ -w "$WAKELOCK" ]; then
  log "keep-awake: policy=$AWAKEN_POLICY, wakeup-source interface present"
else
  log "keep-awake: $WAKELOCK NOT writable - cannot hold a wakeup source"
fi

# ---------------------------------------------------------------- cpu clock
apply_cpu() {
  # little cluster
  for c in 0 1 2 3 4 5; do
    echo "$CPU_GOVERNOR"  > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor 2>/dev/null
    echo "$CPU_LITTLE_MIN" > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq 2>/dev/null
    echo "$CPU_LITTLE_MAX" > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq 2>/dev/null
  done
  # big cluster
  for c in 6 7; do
    echo "$CPU_GOVERNOR"  > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_governor 2>/dev/null
    echo "$CPU_BIG_MIN"   > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_min_freq 2>/dev/null
    echo "$CPU_BIG_MAX"   > /sys/devices/system/cpu/cpu$c/cpufreq/scaling_max_freq 2>/dev/null
  done
}
apply_cpu
log "cpu: little=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_max_freq 2>/dev/null)/$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null) big=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_max_freq 2>/dev/null)/$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_governor 2>/dev/null)"

# Android-side extras that stop the handset idling itself to sleep
settings put global stay_on_while_plugged_in 7 2>/dev/null
settings put system screen_off_timeout 2147483647 2>/dev/null
log "android: stay_on_while_plugged_in=$(settings get global stay_on_while_plugged_in 2>/dev/null)"

# ---------------------------------------------------------------- airplane mode
# No SIM -> airplane mode on, so the idle modem stops costing power. SIM -> off.
# The decision comes from the handset's own SIM state; see airplane-mode.sh.
case "${AIRPLANE_POLICY:-auto}" in
  always) AP=on ;;
  never)  AP=off ;;
  *)      AP=auto ;;
esac
if [ -x "$MODDIR/airplane-mode.sh" ]; then
  "$MODDIR/airplane-mode.sh" "$AP" >> "$LOG" 2>&1
fi
# ---------------------------------------------------------------- watchdog
if [ -x "$MODDIR/watchdog.sh" ]; then
  # kill any previous instance, then detach a fresh one.
  # -9 is deliberate: a plain SIGTERM has been observed not to land here, which
  # left two watchdogs running after a manual restart. The loop is idempotent so
  # duplicates are harmless, but they double the log noise.
  pkill -9 -f "$MODDIR/watchdog.sh" 2>/dev/null
  sleep 1
  setsid nohup "$MODDIR/watchdog.sh" >/dev/null 2>&1 &
  log "watchdog: started (pid $!)"
else
  log "watchdog: $MODDIR/watchdog.sh missing or not executable"
fi

log "=== saipan-tuning service.sh done ==="
