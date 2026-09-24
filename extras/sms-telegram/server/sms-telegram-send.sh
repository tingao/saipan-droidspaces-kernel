#!/bin/sh
# Drain the SMS snapshot the host leaves in /var/spool/sms-telegram and forward
# anything new to Telegram.
#
# Run from a systemd timer rather than a shell loop: if it dies, systemd notices,
# and a timer cannot double-run the way a detached loop can.
#
# A body is read with sqlite3 straight into a shell variable, so newlines, commas,
# quotes and anything else survive untouched - there is no parsing step to get
# wrong. Delivery goes through curl with real certificate validation.
set -u

. /etc/telegram-sms/config.env 2>/dev/null || true

SPOOL=/var/spool/sms-telegram
SNAP=$SPOOL/mmssms.db
STATE=/var/lib/sms-telegram/last_id

say() { echo "$(date -Is) $*"; }

[ -f "$SNAP" ] || exit 0

command -v sqlite3 >/dev/null 2>&1 || { say "sqlite3 is missing"; exit 1; }
if [ -z "${BOT_TOKEN:-}" ]; then say "no BOT_TOKEN in /etc/telegram-sms/config.env"; exit 1; fi

mkdir -p "$(dirname "$STATE")"

last=$(cat "$STATE" 2>/dev/null || echo 0)
case "$last" in ''|*[!0-9]*) last=0 ;; esac

max=$(sqlite3 "$SNAP" "SELECT COALESCE(MAX(_id),0) FROM sms WHERE type=1;" 2>/dev/null)
case "$max" in ''|*[!0-9]*) say "cannot read the snapshot, leaving it for the next pass"; exit 1 ;; esac

# First run after a fresh install: adopt the current high-water mark rather than
# dumping somebody's entire message history into a Telegram group.
#
# The test is the file's existence, not `last = 0`. On a handset with an empty
# inbox max is 0, so testing the value would make every single pass look like a
# first run and the state file would never settle.
if [ ! -f "$STATE" ]; then
  echo "$max" > "$STATE"
  say "first run: starting from _id=$max, history not replayed"
  rm -f "$SNAP"
  exit 0
fi

# The database can go *backwards*: a factory reset, or a handset restored from
# backup, restarts _id at 1. If the mark is still above the snapshot's maximum,
# every new message would compare as "already seen" and be skipped forever.
if [ "$max" -lt "$last" ]; then
  say "snapshot max _id ($max) is below the recorded mark ($last): the message store was reset, restarting from $max"
  echo "$max" > "$STATE"
  rm -f "$SNAP"
  exit 0
fi

if [ "$max" -eq "$last" ]; then
  rm -f "$SNAP"
  exit 0
fi

if [ -z "${CHAT_ID:-}" ]; then
  say "no CHAT_ID configured yet - keeping the snapshot for when there is one"
  exit 0
fi

sent=0
ids=$(sqlite3 "$SNAP" "SELECT _id FROM sms WHERE type=1 AND _id > $last ORDER BY _id;" 2>/dev/null)

for id in $ids; do
  case "$id" in ''|*[!0-9]*) continue ;; esac

  addr=$(sqlite3 "$SNAP" "SELECT address FROM sms WHERE _id=$id;" 2>/dev/null)
  when=$(sqlite3 "$SNAP" "SELECT date FROM sms WHERE _id=$id;" 2>/dev/null)
  body=$(sqlite3 "$SNAP" "SELECT body FROM sms WHERE _id=$id;" 2>/dev/null)

  case "$when" in ''|*[!0-9]*) when=0 ;; esac
  human=$(date -d "@$((when / 1000))" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "$when")

  text=$(printf 'SMS received\nFrom: %s\nTime: %s\n\n%s' "${addr:-unknown}" "$human" "$body")

  resp=$(curl -sS --max-time 25 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
           --data-urlencode "chat_id=${CHAT_ID}" \
           --data-urlencode "text=${text}" 2>&1)

  if printf '%s' "$resp" | grep -q '"ok":true'; then
    say "forwarded _id=$id from ${addr:-unknown}"
    echo "$id" > "$STATE"
    sent=$((sent + 1))
  else
    # Do not advance the mark: the next pass retries this message, and the ones
    # after it, rather than silently losing them.
    say "FAILED _id=$id: $resp"
    rm -f "$SNAP"
    exit 1
  fi
done

rm -f "$SNAP"
[ "$sent" -gt 0 ] && say "done, $sent forwarded"
exit 0
