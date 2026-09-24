#!/system/bin/sh
# Copy the SMS database into the container's spool whenever it changes.
#
# Why the database and not `content query`: a message body can contain newlines,
# commas, quotes and anything else, and `content query` prints rows as
# `Row: N column=value` with the value pasted in raw. Parsing that reliably from
# mksh is a losing game. Copying the SQLite file lets the container read it with
# sqlite3, where a body is just text and no parsing happens at all.
#
# Why the copy happens here and not in the container: the container cannot see
# /data/data. It CAN see its own rootfs, which is a directory on /data, so the
# snapshot is written straight into it - no bind mount and no container restart.
#
# The copy is atomic from the container's point of view: written as .part, then
# renamed, so the container never opens a half-written SQLite file.
set -u

INTERVAL="${1:-60}"
CONT=bagda
SPOOL_HOST=/data/local/Droidspaces/Containers/$CONT/rootfs/var/spool/sms-telegram
DB=/data/data/com.android.providers.telephony/databases/mmssms.db
STAMP=/data/local/sms-telegram.dbstamp
LOG=/data/local/sms-telegram.log

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] [poller] $*" >> "$LOG"; }

rotate_log() {
  sz=$(wc -c < "$LOG" 2>/dev/null || echo 0)
  if [ "$sz" -gt 262144 ]; then
    tail -100 "$LOG" > "$LOG.tmp" 2>/dev/null && mv "$LOG.tmp" "$LOG"
  fi
}

mkdir -p "$SPOOL_HOST" 2>/dev/null
log "poller started (interval ${INTERVAL}s, spool $SPOOL_HOST)"

n=0
while true; do
  n=$((n + 1))

  if [ -r "$DB" ]; then
    now=$(stat -c '%s-%Y' "$DB" 2>/dev/null)
    [ -n "$now" ] || now=$(ls -l "$DB" 2>/dev/null | awk '{print $5"-"$6"-"$7"-"$8}')
    prev=$(cat "$STAMP" 2>/dev/null)

    if [ "$now" != "$prev" ]; then
      if dd if="$DB" of="$SPOOL_HOST/mmssms.db.part" 2>/dev/null; then
        mv -f "$SPOOL_HOST/mmssms.db.part" "$SPOOL_HOST/mmssms.db" 2>/dev/null
        # A stale journal would make sqlite3 try to replay it against the copy.
        rm -f "$SPOOL_HOST/mmssms.db-journal" "$SPOOL_HOST/mmssms.db-wal" "$SPOOL_HOST/mmssms.db-shm" 2>/dev/null
        echo "$now" > "$STAMP" 2>/dev/null
        log "snapshot updated ($now)"
      else
        rm -f "$SPOOL_HOST/mmssms.db.part" 2>/dev/null
        log "snapshot FAILED (dd)"
      fi
    fi
  else
    # Say it once, not every minute.
    [ $((n % 60)) -eq 1 ] && log "cannot read $DB - nothing to forward"
  fi

  # Container not up yet? The spool file simply waits there.
  if [ $((n % 10)) -eq 0 ]; then rotate_log; fi
  sleep "$INTERVAL"
done
