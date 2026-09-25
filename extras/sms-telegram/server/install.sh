#!/bin/sh
# Install the container side of the SMS -> Telegram bridge.
#
# Run inside the container as root. The host KernelSU module (extras/sms-telegram/)
# copies the SMS database into /var/spool/sms-telegram; this reads it and posts.
set -e

SPOOL=/var/spool/sms-telegram
STATE=/var/lib/sms-telegram
ARCHIVE=/var/lib/sms-telegram/archive
CONF=/etc/telegram-sms/config.env

echo "=== dependencies ==="
for pkg in sqlite3 curl; do
  if ! command -v "$pkg" >/dev/null 2>&1; then
    echo "  installing $pkg"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$pkg"
  fi
  printf '  %-8s %s\n' "$pkg" "$(command -v $pkg)"
done

echo
echo "=== directories ==="
install -d -m 0755 "$SPOOL"
install -d -m 0755 "$STATE"
install -d -m 0755 "$ARCHIVE"
install -d -m 0700 /etc/telegram-sms
ls -ld "$SPOOL" "$STATE" "$ARCHIVE" /etc/telegram-sms

echo
echo "=== credentials ==="
if [ -f "$CONF" ]; then
  echo "  $CONF already exists, leaving it alone"
  echo -n "  BOT_TOKEN set: "; grep -q '^BOT_TOKEN=.\+' "$CONF" && echo yes || echo NO
  echo -n "  CHAT_ID set  : "; grep -q '^CHAT_ID=.\+' "$CONF" && echo yes || echo NO
else
  echo "  !! $CONF is missing - create it from config.env.example before this can send"
  echo "     (telegram-env install does this; see extras/README.md)"
fi

echo
echo "=== install the sender and its timer ==="
install -m 0755 /root/sms-telegram-send.sh /usr/local/sbin/sms-telegram-send.sh
install -m 0644 /root/sms-telegram-send.service /etc/systemd/system/sms-telegram-send.service
install -m 0644 /root/sms-telegram-send.timer /etc/systemd/system/sms-telegram-send.timer
systemctl daemon-reload
systemctl enable --now sms-telegram-send.timer

echo
echo "=== state ==="
echo -n "  timer    : "; systemctl is-active sms-telegram-send.timer
echo -n "  service  : "; systemctl is-active sms-telegram-send.service
systemctl list-timers sms-telegram-send.timer --no-pager | head -3

echo
echo "=== dry run (no snapshot yet, so this should be a clean no-op) ==="
/usr/local/sbin/sms-telegram-send.sh && echo "  exit 0, nothing to do" || echo "  exit $?"
echo "=== SMS_TELEGRAM_SERVER_INSTALLED ==="
