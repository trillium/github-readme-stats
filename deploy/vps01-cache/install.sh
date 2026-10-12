#!/usr/bin/env bash
# Install (or update) the stats card renderer and cache on a Debian host. Idempotent; run as root.
#
#   sudo STATS_HOSTNAME=stats.example.com ./install.sh
#
# Run it from a checkout of this repository pinned to the commit or tag you want
# to deploy (git checkout <sha>); that checkout's code is copied to /opt/stats-cache/app.
# Does not touch /etc/caddy or restart Caddy; see README.md for that step.
set -euo pipefail

SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$SRC/../.." && pwd)
USER_NAME=statscache
STATE=/var/lib/stats-cache
CONF=/etc/stats-cache
APP=/opt/stats-cache/app
NODE_MIN=18   # package.json engines
NODE_MAJOR=22 # LTS installed from NodeSource when the host has no usable /usr/bin/node + npm
NODE=/usr/bin/node # the renderer unit's ExecStart runs this exact path

[ "$(id -u)" = 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$REPO/express.js" ] && [ -f "$REPO/package-lock.json" ] ||
  { echo "run from deploy/vps01-cache inside a checkout of the repository" >&2; exit 1; }
if [ -n "${STATS_HOSTNAME:-}" ]; then
  [[ $STATS_HOSTNAME =~ ^[A-Za-z0-9.-]+$ ]] || { echo "bad STATS_HOSTNAME" >&2; exit 1; }
fi

node_ok() {
  [ -x "$NODE" ] && command -v npm >/dev/null &&
    [ "$("$NODE" -p 'process.versions.node.split(".")[0]')" -ge "$NODE_MIN" ]
}

apt_updated=0
apt_install() {
  [ "$apt_updated" = 1 ] || { apt-get update; apt_updated=1; }
  apt-get install -y "$@"
}

for tool in curl flock; do
  command -v "$tool" >/dev/null || { apt_install curl util-linux; break; }
done

if ! node_ok; then
  echo "no $NODE >= $NODE_MIN with npm; installing Node $NODE_MAJOR from NodeSource"
  apt_install ca-certificates curl gnupg
  install -d -m 755 /etc/apt/keyrings
  curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
    gpg --dearmor --yes -o /etc/apt/keyrings/nodesource.gpg
  echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" \
    >/etc/apt/sources.list.d/nodesource.list
  apt_updated=0
  apt_install nodejs
fi
node_ok || { echo "$NODE >= $NODE_MIN with npm still missing after install" >&2; exit 1; }
echo "node $("$NODE" -v), npm $(npm -v)"

id "$USER_NAME" >/dev/null 2>&1 ||
  useradd --system --home-dir "$STATE" --shell /usr/sbin/nologin "$USER_NAME"

# Caddy (its own user) reads www/, so the top directory must be traversable.
install -d -m 755 -o "$USER_NAME" -g "$USER_NAME" "$STATE" "$STATE/www"
install -d -m 750 -o "$USER_NAME" -g "$USER_NAME" "$STATE/state"
install -d -m 755 "$CONF"
[ -d /var/log/caddy ] || install -d -m 755 -o caddy -g caddy /var/log/caddy

# Renderer: the repo's own express.js, root-owned and read-only to the service user.
install -d -m 755 "$APP"
rm -rf "$APP/api" "$APP/src" "$APP/themes"
(cd "$REPO" && tar cf - api src themes express.js package.json package-lock.json) | tar xf - -C "$APP"
(cd "$APP" && npm ci --omit=dev --ignore-scripts --no-audit --no-fund)
{
  git -c safe.directory="$REPO" -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown
  git -c safe.directory="$REPO" -C "$REPO" status --porcelain 2>/dev/null | grep -q . && echo "(working tree had local changes)"
} >"$APP/VERSION" || true
echo "renderer code: $(head -1 "$APP/VERSION")"

install -m 755 "$SRC/bin/stats-cache-refresh" /usr/local/bin/stats-cache-refresh
install -m 644 "$SRC/cards.conf" "$CONF/cards.conf"
# Keep local edits to the settings; the shipped defaults are always in .dist.
install -m 644 "$SRC/stats-cache.env" "$CONF/stats-cache.env.dist"
[ -e "$CONF/stats-cache.env" ] || install -m 644 "$SRC/stats-cache.env" "$CONF/stats-cache.env"
# The GitHub token lives only here: root-owned, 0600, never in the repo or logs.
[ -e "$CONF/renderer.env" ] || install -m 600 -o root -g root /dev/null "$CONF/renderer.env"
chown root:root "$CONF/renderer.env"
chmod 600 "$CONF/renderer.env"
if [ -n "${STATS_HOSTNAME:-}" ]; then
  sed "s|{\$STATS_HOSTNAME}|$STATS_HOSTNAME|" "$SRC/Caddyfile.stats-cache" >"$CONF/Caddyfile.site"
  chmod 644 "$CONF/Caddyfile.site"
fi

for unit in stats-cache-renderer.service stats-cache-refresh.service stats-cache-refresh.timer stats-cache-refresh.path; do
  install -m 644 "$SRC/systemd/$unit" "/etc/systemd/system/$unit"
done
systemctl daemon-reload
systemctl enable stats-cache-renderer.service
systemctl enable --now stats-cache-refresh.timer stats-cache-refresh.path

if ! grep -q '^PAT_1=.' "$CONF/renderer.env"; then
  cat >&2 <<MSG

ACTION NEEDED: $CONF/renderer.env has no PAT_1, so the renderer is not running
and no cards can be produced yet. Put a GitHub token in it (see README.md for the
scopes), then start the renderer and fetch the first copies:

  echo 'PAT_1=<token>' | sudo tee -a $CONF/renderer.env >/dev/null
  sudo systemctl restart stats-cache-renderer
  sudo systemctl start stats-cache-refresh

MSG
  exit 0
fi

systemctl restart stats-cache-renderer.service
# Wait for the renderer to listen, then fetch the first copies so the site has something to serve.
for _ in $(seq 1 20); do
  (exec 3<>/dev/tcp/127.0.0.1/9000) 2>/dev/null && break
  sleep 1
done
systemctl start stats-cache-refresh.service || echo "first refresh failed; see: journalctl -u stats-cache-refresh" >&2
ls -l "$STATE/www"
