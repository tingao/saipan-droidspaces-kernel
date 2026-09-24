#!/system/bin/sh
# Airplane mode driven by whether a SIM is actually fitted.
#
#   sh airplane-mode.sh auto|on|off|status
#
# Why this exists: the cellular modem is powered the whole time, and on a handset
# that serves from a shelf it is pure cost. But whether it is *idle* or *useful*
# depends entirely on the SIM, which can change while the phone is deployed. So the
# policy is decided from the device's own SIM state on every pass rather than
# hard-coded to one answer.
#
#   no SIM  ->  airplane mode ON, Wi-Fi explicitly kept alive
#   SIM     ->  airplane mode OFF
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

wifi_iface() { ip -4 -o addr show dev wlan0 2>/dev/null | awk '{print $4}'; }
have_wifi()  { [ -n "$(wifi_iface)" ] && ping -c1 -W3 1.1.1.1 >/dev/null 2>&1; }
airplane()   { settings get global airplane_mode_on 2>/dev/null; }

# SIM detection that also works while airplane mode is on. Verified on this
# handset: `gsm.sim.state` still reads LOADED with the radio cut, which is what
# makes the policy safe to evaluate in both directions.
#
# NOT_READY is deliberately *not* treated as "no SIM": it only means the modem has
# not finished initialising, and reading it as absent would turn airplane mode on
# during boot and then never turn it off again.
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

# UNKNOWN is deliberately NOT treated as "no SIM". At boot the modem reports
# UNKNOWN before it has read the card, and treating that as absent turned airplane
# mode on for a phone that has a SIM - observed on the first cold boot after this
# was installed. Only a positive ABSENT counts, so the failure mode is "the radio
# stays on", which costs a little power, instead of "the radio is cut on a phone
# that needed it".
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
    echo "  airplane ON (sim=$(sim_state)), Wi-Fi up at $(wifi_iface)"
    return 0
  fi
  echo "  Wi-Fi did NOT come back within 60 s - reverting so the handset stays reachable"
  restore_state
  have_wifi && echo "  recovered after revert" || echo "  STILL unreachable - needs a hand on the device"
  return 1
}

do_off() {
  settings put global airplane_mode_on 0
  am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false >/dev/null 2>&1
  svc wifi enable
  echo "  airplane OFF (SIM: $(sim_state)/$(getprop gsm.operator.alpha 2>/dev/null))"
}

# Cheap, idempotent pass for the watchdog: only touches anything when the desired
# state differs from the current one, so it costs two getprop/settings reads a
# minute and never flaps the radio.
do_auto() {
  if [ -e "$LOCK" ]; then return 0; fi
  : > "$LOCK"
  trap 'rm -f "$LOCK"' EXIT

  # The settings service is not up until well into boot; acting before that gets a
  # "Can't find service: settings" and a half-applied state. The watchdog retries
  # every minute, so skipping here costs nothing.
  cur=$(airplane)
  case "$cur" in
    ''|null|*"Can't find service"*)
      echo "  settings service not up yet - leaving airplane mode alone"
      rm -f "$LOCK"; trap - EXIT; return 0 ;;
  esac

  want=unchanged
  if sim_present; then
    want=0
  elif sim_absent; then
    want=1
  fi

  case "$want" in
    unchanged)
      echo "  sim=$(sim_state) - indeterminate, leaving airplane mode alone"
      ;;
    0)
      [ "$(airplane)" = "0" ] || do_off
      ;;
    1)
      protect_wifi_radio
      if [ "$(airplane)" != "1" ]; then
        do_on
      elif ! have_wifi; then
        # Airplane mode is on as intended but the uplink died - re-assert Wi-Fi.
        svc wifi enable
        settings put global wifi_on 1
        cmd wifi set-wifi-enabled enabled >/dev/null 2>&1 || true
        echo "  airplane already ON, Wi-Fi was down - re-enabled"
      fi
      ;;
  esac
  rm -f "$LOCK"
  trap - EXIT
}

case "$ACTION" in
  status)
    echo "  airplane_mode_on          : $(airplane)"
    echo "  airplane_mode_radios      : $(settings get global airplane_mode_radios)"
    echo "  wifi_on                   : $(settings get global wifi_on)"
    echo "  wlan0                     : $(wifi_iface)"
    echo "  SIM state                 : $(sim_state)  operator=$(getprop gsm.operator.alpha 2>/dev/null)"
    if sim_present; then echo "  policy verdict            : SIM present -> airplane OFF";
    elif sim_absent; then echo "  policy verdict            : no SIM -> airplane ON";
    else echo "  policy verdict            : indeterminate -> leave alone"; fi
    echo "  reachable                 : $(have_wifi && echo yes || echo no)"
    ;;
  auto)   do_auto ;;
  on)     do_on ;;
  off)    do_off ;;
  *)      echo "usage: $0 auto|on|off|status"; exit 2 ;;
esac
