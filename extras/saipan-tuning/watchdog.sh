#!/system/bin/sh
# saipan server tuning watchdog -- re-asserts the tuning every 60s.
#
# Android's own power/thermal HALs rewrite cpufreq ceilings and the charge band behind
# our back, and a lock/suspend cycle can leave Wi-Fi disabled. This loop puts things
# back and keeps a compact log so the behaviour is observable rather than hoped for.
#
# One iteration per minute is cheap; the log is rotated at 1 MB.

MODDIR=${0%/*}
LOG=/data/local/saipan-tuning.log
. "$MODDIR/tuning.conf" 2>/dev/null || true
: "${CHARGE_UPPER:=80}"
: "${CHARGE_LOWER:=75}"
: "${AWAKEN_POLICY:=charging}"
: "${CPU_LITTLE_MIN:=500000}"
: "${CPU_LITTLE_MAX:=2000000}"
: "${CPU_BIG_MIN:=725000}"
: "${CPU_BIG_MAX:=2203000}"
: "${CPU_GOVERNOR:=schedutil}"
: "${WIFI_WATCHDOG:=1}"

CB=/sys/module/qpnp_adaptive_charge/parameters
WAKELOCK=/sys/power/wake_lock
WAKEUNLOCK=/sys/power/wake_unlock
LOCKNAME=saipan-awake

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [wd] $*" >> "$LOG"; }

on_external_power() {
  [ "$(cat /sys/class/power_supply/charger/online 2>/dev/null)" = "1" ] && return 0
  [ "$(cat /sys/class/power_supply/usb/online 2>/dev/null)" = "1" ] && return 0
  [ "$(cat /sys/class/power_supply/ac/online 2>/dev/null)" = "1" ] && return 0
  case "$(cat /sys/class/power_supply/battery/status 2>/dev/null)" in
    Charging|Full) return 0 ;;
  esac
  return 1
}

rotate_log() {
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 1048576 ]; then
    tail -200 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
    log "log rotated"
  fi
}

log "watchdog started (policy=$AWAKEN_POLICY charge=${CHARGE_UPPER}/${CHARGE_LOWER} cpu=${CPU_LITTLE_MAX}/${CPU_BIG_MAX})"
n=0
while true; do
  n=$((n + 1))

  # ---- charge band ------------------------------------------------------
  if [ -d "$CB" ] && [ "$CHARGE_UPPER" != "-1" ]; then
    cur_u=$(cat "$CB/upper_limit" 2>/dev/null)
    cur_l=$(cat "$CB/lower_limit" 2>/dev/null)
    if [ "$cur_u" != "$CHARGE_UPPER" ] || [ "$cur_l" != "$CHARGE_LOWER" ]; then
      # upper first: writing upper_limit resets lower_limit to -1 in this driver
      echo "$CHARGE_UPPER" > "$CB/upper_limit" 2>/dev/null
      echo "$CHARGE_LOWER" > "$CB/lower_limit" 2>/dev/null
      log "charge band re-asserted ($cur_u/$cur_l -> $(cat $CB/upper_limit 2>/dev/null)/$(cat $CB/lower_limit 2>/dev/null))"
    fi
  fi

  # ---- cpu ceilings -----------------------------------------------------
  for c in 0 6; do
    case $c in
      0) want_min=$CPU_LITTLE_MIN; want_max=$CPU_LITTLE_MAX ;;
      6) want_min=$CPU_BIG_MIN;    want_max=$CPU_BIG_MAX ;;
    esac
    f=/sys/devices/system/cpu/cpu$c/cpufreq
    [ "$(cat $f/scaling_max_freq 2>/dev/null)" = "$want_max" ] || {
      echo "$want_min" > $f/scaling_min_freq 2>/dev/null
      echo "$want_max" > $f/scaling_max_freq 2>/dev/null
      log "cpu$c max re-asserted -> $(cat $f/scaling_max_freq 2>/dev/null)"
    }
    [ "$(cat $f/scaling_governor 2>/dev/null)" = "$CPU_GOVERNOR" ] || {
      echo "$CPU_GOVERNOR" > $f/scaling_governor 2>/dev/null
      log "cpu$c governor re-asserted"
    }
  done

  # ---- keep-awake -------------------------------------------------------
  cap=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo 100)
  want=no
  case "$AWAKEN_POLICY" in
    always)   want=yes ;;
    charging) on_external_power && want=yes || want=no ;;
    *)        want=no ;;
  esac
  held=$(cat "$WAKELOCK" 2>/dev/null | tr ' ' '\n' | grep -c "^${LOCKNAME}$")
  if [ "$want" = yes ] && [ "$held" = 0 ]; then
    echo "$LOCKNAME" > "$WAKELOCK" 2>/dev/null
    log "wakeup source TAKEN (cap=${cap}% policy=$AWAKEN_POLICY)"
  elif [ "$want" = no ] && [ "$held" != 0 ]; then
    echo "$LOCKNAME" > "$WAKEUNLOCK" 2>/dev/null
    log "wakeup source released (cap=${cap}% policy=$AWAKEN_POLICY)"
  fi

  # ---- android settings -------------------------------------------------
  # service.sh also sets these at boot, but at that point the settings service is
  # frequently not up yet and `settings put` fails silently - the boot log shows
  # "stay_on_while_plugged_in=" with nothing after it. Re-assert them here instead,
  # where the framework is definitely running, so the value does not depend on
  # having caught the boot window.
  if [ "$(settings get global stay_on_while_plugged_in 2>/dev/null)" != "7" ]; then
    settings put global stay_on_while_plugged_in 7 2>/dev/null
    log "android: stay_on_while_plugged_in re-asserted -> $(settings get global stay_on_while_plugged_in 2>/dev/null)"
  fi
  if [ "$(settings get system screen_off_timeout 2>/dev/null)" != "2147483647" ]; then
    settings put system screen_off_timeout 2147483647 2>/dev/null
    log "android: screen_off_timeout re-asserted"
  fi

  # ---- wifi watchdog ----------------------------------------------------
  if [ "$WIFI_WATCHDOG" = "1" ]; then
    wifi_on=$(settings get global wifi_on 2>/dev/null)
    if [ "$wifi_on" != "1" ]; then
      svc wifi enable 2>/dev/null
      log "wifi was off (wifi_on=$wifi_on) -> re-enabled"
    fi
  fi

  # ---- periodic status --------------------------------------------------
  if [ $((n % 10)) -eq 0 ]; then
    temp=$(cat /sys/class/power_supply/battery/temp 2>/dev/null)
    status=$(cat /sys/class/power_supply/battery/status 2>/dev/null)
    power=external; on_external_power || power=battery
    log "status cap=${cap}% temp=$((temp/10))C status=$status power=$power lock=$([ "$held" != 0 ] && echo held || echo free) cpu0=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null) cpu6=$(cat /sys/devices/system/cpu/cpu6/cpufreq/scaling_cur_freq 2>/dev/null)"
  fi

  rotate_log
  sleep 60
done
