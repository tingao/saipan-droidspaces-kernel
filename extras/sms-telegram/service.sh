#!/system/bin/sh
# saipan SMS -> Telegram: host side.
#
# Copies the SMS database into the container's spool whenever it changes, and
# nothing else. The container owns the sending: it has curl with real certificate
# validation, and it has sqlite3, so it can read a body without parsing it.
#
# Why the split at all: the phone's own HTTP client is busybox wget, which
# literally prints "TLS certificate validation not implemented". Posting a bot
# token and the contents of somebody's text messages over an unvalidated TLS
# connection is not something to ship.
#
# Install: /data/adb/modules/sms-telegram/ (KernelSU module), reboot.
# Log:     /data/local/sms-telegram.log

MODDIR=${0%/*}
LOG=/data/local/sms-telegram.log
INTERVAL=${SMS_POLL_INTERVAL:-60}

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=== sms-telegram service.sh start ==="

# KernelSU runs service.sh as root in the ksu domain; the SMS database is
# radio_data_file, which that domain can read on this device (verified). At this
# point in boot it is often not readable *yet*, which is not a fault - the poller
# retries every minute and logs when it actually starts working. Only a warning
# that persists is a problem, so this says so rather than crying wolf.
SMSDB=/data/data/com.android.providers.telephony/databases/mmssms.db
if [ -r "$SMSDB" ]; then
  log "SMS database readable at boot"
else
  log "note: $SMSDB not readable yet this early in boot - the poller will retry every ${INTERVAL}s"
fi

pkill -9 -f "$MODDIR/poller.sh" 2>/dev/null
sleep 1
setsid nohup sh "$MODDIR/poller.sh" "$INTERVAL" >/dev/null 2>&1 &
log "poller: started (pid $!, interval ${INTERVAL}s)"
log "=== sms-telegram service.sh done ==="
