#!/usr/bin/env bash
# Remove the stats card cache. Run as root. Leaves /etc/caddy alone.
#
#   sudo ./uninstall.sh          # remove units, scripts and config; keep cached cards and user
#   sudo ./uninstall.sh --purge  # also delete /var/lib/stats-cache and the statscache user
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

systemctl disable --now stats-cache-refresh.timer stats-cache-refresh.path 2>/dev/null || true
systemctl stop stats-cache-refresh.service 2>/dev/null || true
rm -f /etc/systemd/system/stats-cache-refresh.{service,timer,path}
systemctl daemon-reload
rm -f /usr/local/bin/stats-cache-refresh
rm -rf /etc/stats-cache

if [ "${1:-}" = --purge ]; then
  rm -rf /var/lib/stats-cache
  rm -f /var/log/caddy/stats-cache-access.log*
  userdel statscache 2>/dev/null || true
fi
echo "removed; also delete the stats site block from the Caddyfile and reload Caddy"
