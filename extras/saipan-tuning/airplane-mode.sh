#!/system/bin/sh
# Airplane mode driven by whether a SIM is actually fitted.
#
#   sh airplane-mode.sh auto|on|off|status
#
# The rule, stated once so there is no room to read it backwards:
#
#   SIM FITTED    ->  airplane mode OFF   (the radio is wanted)
#   NO SIM        ->  airplane mode ON    (Wi-Fi explicitly kept alive)
#
# Why the policy is evaluated rather than hard-coded: a phone that serves from a
# shelf has a cellular modem powered whether or not it is useful, but whether it is
# useful depends on the SIM, and the SIM can change while the phone is deployed.
#
# Why the "no SIM" decision is deliberately reluctant: taking a phone off the air
# is the expensive mistake, leaving a modem powered is the cheap one. So this needs
# the modem to report a positive ABSENT twice in a row before it cuts anything, and
# anything ambiguous is left alone. An earlier version acted on a single reading and
# turned airplane mode on for a handset that has a SIM - see the notes on
# sim_absent() below.
#
# Self-healing by design: this runs ON the device, so it does not depend on the
# SSH/tunnel session that asked for it. After enabling airplane mode it waits for
# Wi-Fi to come back and internet to actually be reachable, and reverts on its own
# if it does not. On a headless phone nobody is holding, that local revert is the
# whole point.
set -u

ACTION="${1:-status}"
STATE=/data/local/tmp/airplane-mode.previous
LOCK=/data/local/tmp/airplane-mode.lock
STREAK=/data/local/tmp/airplane-mode.absent-streak

wifi_iface() { ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}'; }
have_wifi()  { [ -n "$(wifi_iface)" ] && ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; }
airplane()   { settings get global airplane_mode_on 2>/dev/null; }
operator()   { getprop gsm.operator.alpha 2>/dev/null; }

# SIM detection that also works while airplane mode is on. Verified on this
# handset: `gsm.sim.state` still reads LOADED with the radio cut, which is what
# makes the policy safe to evaluate in either direction.
sim_state() {
  v=$(getprop gsm.sim.state 2>/dev/null)
  [ -n "$v" ] || v=UNKNOWN
  printf '%s' "$v"
}

sim_present() {
  case "$(sim_state)" in
    READY|LOADED|IMSI|PIN_REQUIRED|PUK_REQUIRED|NETWORK_LOCKED|SUBSCRIPTION_LOCKED|CORPORATE_LOCKED|PERM_DISABLED) return 0 ;;
    *) return 1 ;;
  esac
}

# UNKNOWN is deliberately NOT treated as "no SIM". At boot, and during any modem
# reset, the modem reports UNKNOWN before it has read the card. Treating that as
# absent turned airplane mode on for a handset that has a SIM - visible in the
# tuning log at 23:02, 23:05, 23:08 and 23:11, where "airplane ON (sim=READY)"
# appeared right after "Can't find service: settings". Only a positive ABSENT
# counts, so the failure mode is "the modem stays powered", which costs a little
# battery, instead of "the phone was taken off the air".
sim_absent() {
  case "$(sim_state)" in
    ABSENT|CARD_IO_ERROR|CARD_NOT_INSERTED) return 0 ;;
    *) return 1 ;;
  esac
}

# Keep Wi-Fi out of the radio set airplane mode cuts. Airplane mode normally turns
# Wi-Fi off too, because "wifi" is in airplane_mode_radios - fatal on a headless
# server: after a REBOOT the framework applies airplane mode before anything can
# re-enable Wi-Fi, and the handset comes up with no network at all.
protect_wifi_radio() {
  orig=$(settings get global airplane_mode_radios 2>/dev/null)
  new=$(printf '%s' "$orig" | sed 's/,wifi//g; s/wifi,//g')
  if [ -n "$new" ] && [ "$new" != "$orig" ]; then
    settings put global airplane_mode_radios "$new"
  fi
}

save_state() {
  printf 'airplane=%s\nwifi=%s\nradios=%s\n' \
    "$(airplane)" "$(settings get global wifi_on 2>/dev/null)" \
    "$(settings get global airplane_mode_radios 2>/dev/null)" > "$STATE"
}

restore_state() {
  [ -r "$STATE" ] || return 0
  . "$STATE" 2>/dev/null || true
  [ -n "${radios:-}" ] && settings put global airplane_mode_radios "$radios"
  settings put global airplane_mode_on "${airplane:-0}"
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state "$([ "${airplane:-0}" = 1 ] && echo true || echo false)" >/dev/null 2>&1
  [ "${wifi:-1}" = 1 ] && svc wifi enable
  echo "  reverted to airplane=${airplane:-0} wifi=${wifi:-1}"
}

do_on() {
  # $1 is the modem reading that triggered this, so the log records the cause. A
  # bare "airplane ON" with no reason reads as if the policy were inverted, which
  # is how this was misread once already.
  why="${1:-$(sim_state)}"
  save_state
  protect_wifi_radio
  settings put global airplane_mode_on 1
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true >/dev/null 2>&1
  sleep 2
  svc wifi enable
  settings put global wifi_on 1
  # All three are needed. On LineageOS 18.1 this last one is what makes Wi-Fi
  # survive a *reboot* with airplane mode on; without it the supplicant stays
  # UNINITIALIZED and neither `svc wifi enable` nor a reboot revives it.
  cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || true
  i=0
  while [ "$i" -lt 30 ]; do
    have_wifi && break
    sleep 2
    i=$((i + 1))
  done
  if have_wifi; then
    case "$why" in
      forced*) echo "  airplane ON - forced by hand, Wi-Fi up at $(wifi_iface)" ;;
      *)       echo "  airplane ON - no SIM fitted (modem reports $why), Wi-Fi up at $(wifi_iface)" ;;
    esac
    return 0
  fi
  echo "  Wi-Fi did NOT come back within 60 s - reverting so the handset stays reachable"
  restore_state
  have_wifi && echo "  recovered after revert" || echo "  STILL unreachable - needs a hand on the device"
  return 1
}

do_off() {
  why="${1:-$(sim_state)}"
  settings put global airplane_mode_on 0
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
  svc wifi enable
  op=$(operator)
  case "$why" in
    forced*) echo "  airplane OFF - forced by hand" ;;
    *)       echo "  airplane OFF - SIM fitted (modem reports $why${op:+, $op})" ;;
  esac
}

# Cheap, idempotent pass for the watchdog: only touches anything when the desired
# state differs from the current one, so it costs two property reads a minute and
# never flaps the radio.
do_auto() {
  if [ -e "$LOCK" ]; then return 0; fi
  : > "$LOCK"

  # The settings service is not up until well into boot; acting before that gets a
  # "Can't find service: settings" and a half-applied state. The watchdog retries
  # every minute, so skipping here costs nothing.
  cur=$(airplane)
  case "$cur" in
    ''|null|*"Can't find service"*)
      echo "  settings service not up yet - leaving airplane mode alone"
      rm -f "$LOCK"; return 0 ;;
  esac

  if sim_present; then
    # SIM fitted: airplane mode must be OFF. Reset the absence streak.
    echo 0 > "$STREAK" 2>/dev/null
    [ "$cur" = "0" ] || do_off
    rm -f "$LOCK"; return 0
  fi

  if ! sim_absent; then
    echo "  sim=$(sim_state) - indeterminate, leaving airplane mode alone"
    rm -f "$LOCK"; return 0
  fi

  # Positive ABSENT and airplane mode already on: that is the intended state, so
  # only make sure the uplink survived.
  if [ "$cur" = "1" ]; then
    if ! have_wifi; then
      svc wifi enable
      settings put global wifi_on 1
      cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || true
      echo "  airplane already ON, Wi-Fi was down - re-enabled"
    fi
    rm -f "$LOCK"; return 0
  fi

  # Positive ABSENT and airplane mode currently off. Require the reading to hold
  # for a second pass before cutting the radio: one ABSENT during a modem reset is
  # not worth taking a phone off the air for, and waiting a minute costs nothing on
  # a server.
  n=$(cat "$STREAK" 2>/dev/null || echo 0)
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  n=$((n + 1))
  echo "$n" > "$STREAK" 2>/dev/null
  if [ "$n" -lt 2 ]; then
    echo "  sim=$(sim_state) - first ABSENT reading, waiting for a second before cutting the radio"
    rm -f "$LOCK"; return 0
  fi

  do_on "$(sim_state)"
  rm -f "$LOCK"
}

case "$ACTION" in
  status)
    echo "  airplane_mode_on          : $(airplane)"
    echo "  airplane_mode_radios      : $(settings get global airplane_mode_radios)"
    echo "  wifi_on                   : $(settings get global wifi_on)"
    echo "  wlan0                     : $(wifi_iface)"
    echo "  SIM state                 : $(sim_state)  operator=$(operator)"
    echo "  absent streak             : $(cat "$STREAK" 2>/dev/null || echo 0)/2"
    if sim_present; then
      echo "  policy verdict            : SIM fitted -> airplane mode OFF"
    elif sim_absent; then
      echo "  policy verdict            : no SIM -> airplane mode ON"
    else
      echo "  policy verdict            : indeterminate -> leave alone"
    fi
    echo "  reachable                 : $(have_wifi && echo yes || echo no)"
    ;;
  auto)   do_auto ;;
  on)     do_on "forced by hand" ;;
  off)    do_off "forced by hand" ;;
  *)      echo "usage: $0 auto|on|off|status"; exit 2 ;;
esac
