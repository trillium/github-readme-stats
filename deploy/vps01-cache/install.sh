#!/usr/bin/env bash
# Install (or update) the stats card cache on a Debian host. Idempotent; run as root.
#
#   sudo ./install.sh                                  # install units, scripts, first copy
#   sudo STATS_HOSTNAME=stats.example.com ./install.sh # also render the Caddy site block
#
# Does not touch /etc/caddy or restart Caddy; see README.md for that step.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
USER_NAME=statscache
STATE=/var/lib/stats-cache
CONF=/etc/stats-cache

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

for tool in curl flock; do
  if ! command -v "$tool" >/dev/null; then
    apt-get update
    apt-get install -y curl util-linux
    break
  fi
done

id "$USER_NAME" >/dev/null 2>&1 ||
  useradd --system --home-dir "$STATE" --shell /usr/sbin/nologin "$USER_NAME"

# Caddy (its own user) reads www/, so the top directory must be traversable.
install -d -m 755 -o "$USER_NAME" -g "$USER_NAME" "$STATE" "$STATE/www"
install -d -m 750 -o "$USER_NAME" -g "$USER_NAME" "$STATE/state"
install -d -m 755 "$CONF"
[ -d /var/log/caddy ] || install -d -m 755 -o caddy -g caddy /var/log/caddy

install -m 755 "$SRC/bin/stats-cache-refresh" /usr/local/bin/stats-cache-refresh
install -m 644 "$SRC/cards.conf" "$CONF/cards.conf"
# Keep local edits to the settings; the shipped defaults are always in .dist.
install -m 644 "$SRC/stats-cache.env" "$CONF/stats-cache.env.dist"
[ -e "$CONF/stats-cache.env" ] || install -m 644 "$SRC/stats-cache.env" "$CONF/stats-cache.env"
if [ -n "${STATS_HOSTNAME:-}" ]; then
  [[ $STATS_HOSTNAME =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bad STATS_HOSTNAME" >&2; exit 1; }
  sed "s|{\$STATS_HOSTNAME}|$STATS_HOSTNAME|" "$SRC/Caddyfile.stats-cache" >"$CONF/Caddyfile.site"
  chmod 644 "$CONF/Caddyfile.site"
fi

for unit in stats-cache-refresh.service stats-cache-refresh.timer stats-cache-refresh.path; do
  install -m 644 "$SRC/systemd/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable --now stats-cache-refresh.timer stats-cache-refresh.path

# First copy, so the site has something to serve right away.
systemctl start stats-cache-refresh.service || echo "first refresh failed; see: journalctl -u stats-cache-refresh" >&2
ls -l "$STATE/www"
