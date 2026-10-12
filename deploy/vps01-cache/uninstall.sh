#!/usr/bin/env bash
# Remove the stats card renderer and cache. Run as root. Leaves /etc/caddy and Node.js alone.
#
#   sudo ./uninstall.sh          # remove units, renderer, scripts and config; keep cached cards,
#                                # the statscache user and the token file renderer.env
#   sudo ./uninstall.sh --purge  # also delete the cards, the token file and the statscache user
set -euo pipefail

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }

systemctl disable --now stats-cache-refresh.timer stats-cache-refresh.path 2>/dev/null || true
systemctl stop stats-cache-refresh.service 2>/dev/null || true
systemctl disable --now stats-cache-renderer.service 2>/dev/null || true
rm -f /etc/systemd/system/stats-cache-{refresh.service,refresh.timer,refresh.path,renderer.service}
systemctl daemon-reload
rm -f /usr/local/bin/stats-cache-refresh
rm -rf /opt/stats-cache
find /etc/stats-cache -mindepth 1 ! -name renderer.env -delete 2>/dev/null || true

if [ "${1:-}" = --purge ]; then
  rm -rf /etc/stats-cache /var/lib/stats-cache
  rm -f /var/log/caddy/stats-cache-access.log*
  userdel statscache 2>/dev/null || true
fi
echo "removed; also delete the stats site block from the Caddyfile and reload Caddy"
