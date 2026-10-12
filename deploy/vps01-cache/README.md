# README stats card renderer and cache (vps01)

The profile README's stats and top-langs cards used to be rendered by a Vercel
deployment, which is slow whenever its CDN has evicted a rarely visited card.
This directory moves the whole job onto vps01: this repo's own `express.js`
renders the cards on loopback, a small script keeps a copy of each card on
disk, and Caddy serves those copies instantly. A visitor (or GitHub's image
proxy) never waits on a render, and nothing depends on Vercel.

## How it works

- `stats-cache-renderer.service` runs the repo's `express.js` as the
  unprivileged `statscache` user, bound to `127.0.0.1:9000` only (the unit's
  `ExecStart` sets `host=127.0.0.1` and `port=9000` through `env`, which wins
  over its env file, so the file cannot widen it).
  The code is a copy of the checkout you install from, in `/opt/stats-cache/app`
  (root-owned, read-only to the service) with production dependencies from
  `package-lock.json`; `/opt/stats-cache/app/VERSION` records the commit.
- `stats-cache-refresh` (bash + curl) requests each card listed in `cards.conf`
  from the renderer and writes `/var/lib/stats-cache/www/<name>.svg`.
- Caddy serves that directory, with no auth, at `/stats.svg` and
  `/top-langs.svg` on a separate public hostname. Every other path and every
  method except GET/HEAD gets a 404 (a query string on those two paths is
  ignored), and the visitor never chooses what the renderer is asked for. The
  renderer itself is never exposed.
- A copy is replaced only when the renderer answered 200 **and** the body is a
  real card. The renderer returns error cards with status 200, so a body
  containing `Something went wrong!` or `data-testid="message"` (or lacking
  `data-testid="card-title"`) is rejected. Timeouts, non-200s, and bad bodies
  all leave the last good copy untouched.
- Refresh triggers (all run the same script, which does nothing unless the
  copy is older than `FRESH_SECONDS`, default 1 h):
  - `stats-cache-refresh.timer`: every 30 min, so the cache never goes cold;
  - `stats-cache-refresh.path`: fires when Caddy appends to the site's access
    log, i.e. on a visit. The visitor is served the existing copy at once; the
    refresh runs afterwards in the background.
- Rate limiting: stock Caddy has no per-client limiter. Instead the load on the
  renderer (and so on the GitHub API) is bounded: one refresher at a time
  (flock), and at most one attempt per card every `MIN_RETRY_SECONDS` (default
  120 s) even after failures, whatever the traffic. The files are tiny and
  static; if per-IP limiting is wanted later, put it in front (Cloudflare,
  nftables).
- The access log drops client IPs and headers.

## Requirements

- Debian 12 with systemd and stock Caddy already serving 80/443.
- Node.js **18 or newer** (`engines` in `package.json`) with npm. If the host
  has no such node, `install.sh` adds the NodeSource apt repository and installs
  Node 22 LTS (`nodejs` from NodeSource includes npm). An existing Node 18+ with
  npm is left alone.
- A GitHub personal access token, see below.

## GitHub token

The renderer reads `PAT_1` from `/etc/stats-cache/renderer.env`, a root-owned
`0600` file that `install.sh` creates empty if missing. systemd reads it as
root and passes it to the service; it is never in the repo, the unit files, or
logs. Create a **classic** token at <https://github.com/settings/tokens/new>,
for a dedicated purpose, with:

- `read:user`: lets the stats query read the profile, including the
  private-contribution counts that `count_private=true` adds;
- `repo`: lets it see private repositories, so `count_private=true` and
  `include_all_commits=true` (which searches commits by the user through the
  REST search API) include private work. This is the scope the upstream project
  documents for private stats ("`repo` and `user`"); it is broader than the
  read-only use here, so keep the token on this host only.

Fine-grained tokens are not a drop-in replacement for these two options. Without
the token, or with a revoked one, the renderer produces error cards, the
refresher rejects them, and the last good copies keep being served.

```sh
echo 'PAT_1=ghp_...' | sudo tee -a /etc/stats-cache/renderer.env >/dev/null
sudo systemctl restart stats-cache-renderer
```

To rotate, edit the file and restart the renderer.

## Files

| File                                               | Installed to                                  |
| -------------------------------------------------- | --------------------------------------------- |
| repo `api/ src/ themes/ express.js package*.json`  | `/opt/stats-cache/app/` (+ `npm ci --omit=dev`) |
| `bin/stats-cache-refresh`                          | `/usr/local/bin/`                             |
| `cards.conf` (the allowlist)                       | `/etc/stats-cache/`                           |
| `stats-cache.env` (freshness, timeouts)            | `/etc/stats-cache/` (kept if already present) |
| (created empty, mode 0600) `renderer.env`          | `/etc/stats-cache/`                           |
| `systemd/stats-cache-renderer.service`             | `/etc/systemd/system/`                        |
| `systemd/stats-cache-refresh.{service,timer,path}` | `/etc/systemd/system/`                        |
| `Caddyfile.stats-cache` (template)                 | `/etc/stats-cache/Caddyfile.site` (rendered)  |

## Deploy

1. DNS: point a new hostname (for example `stats.example.com`) at
   198.12.123.41. Caddy gets the certificate itself on first use.
2. On vps01, get a checkout **pinned to the release you want** and install from
   it, as root. `STATS_HOSTNAME` is required here: without it no Caddy site
   block is rendered and step 4 has nothing to import.

   ```sh
   git clone https://github.com/trillium/github-readme-stats.git
   cd github-readme-stats && git checkout <tag-or-sha>
   cd deploy/vps01-cache
   sudo STATS_HOSTNAME=stats.example.com ./install.sh
   ```

   Re-running is safe (to upgrade: check out the new tag and run it again). It
   installs Node if needed, copies the code, installs production dependencies,
   creates the user, directories and units, and enables the timer and path
   unit.

3. The first run stops with an `ACTION NEEDED` message because
   `renderer.env` is empty. Add the token as shown above, then:

   ```sh
   sudo systemctl restart stats-cache-renderer
   sudo systemctl start stats-cache-refresh
   ```

   (A re-run of `install.sh` with the token present does both itself.) Check:

   ```sh
   ls -l /var/lib/stats-cache/www
   ss -ltn | grep 9000                          # 127.0.0.1:9000 only
   systemctl list-timers stats-cache-refresh.timer
   journalctl -u stats-cache-renderer -u stats-cache-refresh -n 30
   ```

4. Add the site block to Caddy **without editing the existing edge block**.
   `install.sh` rendered a copy with the hostname filled in; append it to the
   Caddyfile (or `import` it) and reload:

   ```sh
   echo 'import /etc/stats-cache/Caddyfile.site' | sudo tee -a /etc/caddy/Caddyfile
   sudo caddy validate --config /etc/caddy/Caddyfile
   sudo systemctl reload caddy
   ```

5. Check:

   ```sh
   curl -sI https://stats.example.com/stats.svg      # 200, image/svg+xml
   curl -sI https://stats.example.com/top-langs.svg  # 200
   curl -sI https://stats.example.com/anything-else  # 404
   ```

   If Caddy cannot write `/var/log/caddy/stats-cache-access.log`, visits will
   not trigger refreshes (the timer still works); see `journalctl -u caddy`.

6. Point the profile README at the cache by replacing the two Vercel URLs:

   - stats card: `https://stats.example.com/stats.svg`
   - top languages: `https://stats.example.com/top-langs.svg`

   The theme and options are baked into `cards.conf`. To change a card, edit
   it, re-run `install.sh`, and delete `/var/lib/stats-cache/www/<name>.svg`
   (the next timer run or visit then fetches it).

## Rollback

- Revert the README to the Vercel URLs. Nothing else depends on the cache.
- Remove the stats site block from `/etc/caddy/Caddyfile` and reload Caddy. The
  bearer-token edge site is never modified by this setup.
- To go back to an earlier renderer version, check out that tag and re-run
  `install.sh`.
- `sudo ./uninstall.sh` removes the units, renderer, script and config but keeps
  the cached cards, the `statscache` user and `renderer.env` (your token);
  `sudo ./uninstall.sh --purge` also deletes those, and the access log. Node.js
  and the NodeSource apt source are left in place.

## Tests

`npm test -- tests/deploy` runs the refresh script against a local fake
renderer (allowlist, fresh/stale handling, non-200, timeout, error-card and
non-card bodies never overwriting the last good copy, retry spacing) and starts
`express.js` the way the unit does to check it listens on loopback only.
