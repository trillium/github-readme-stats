# README stats card cache (vps01)

The profile README's stats and top-langs cards are rendered by the Vercel
deployment, which is slow whenever its CDN has evicted a rarely visited card.
This directory holds a small layer for vps01 that keeps a copy of each card on
disk and serves it instantly, so a visitor (or GitHub's image proxy) never waits
on Vercel.

## How it works

- `stats-cache-refresh` (bash + curl) fetches each card listed in `cards.conf`
  and writes `/var/lib/stats-cache/www/<name>.svg`.
- Caddy serves that directory, with no auth, at `/stats.svg` and
  `/top-langs.svg` on a separate public hostname. Every other path and every
  method except GET/HEAD gets a 404 (a query string on those two paths is
  ignored), and the visitor never chooses what the upstream is asked for. It is
  not a proxy.
- A copy is replaced only when the upstream answered 200 **and** the body is a
  real card. The upstream returns error cards with status 200, so a body
  containing `Something went wrong!` or `data-testid="message"` (or lacking
  `data-testid="card-title"`) is rejected. Timeouts, non-200s, and bad bodies
  all leave the last good copy untouched.
- Refresh triggers (all run the same script, which does nothing unless the
  copy is older than `FRESH_SECONDS`, default 1 h):
  - `stats-cache-refresh.timer`: every 30 min, so the cache never goes cold;
  - `stats-cache-refresh.path`: fires when Caddy appends to the site's access
    log, i.e. on a visit. The visitor is served the existing copy at once; the
    refresh runs afterwards in the background.
- Rate limiting: stock Caddy has no per-client limiter. Instead the upstream
  load is bounded: one refresher at a time (flock), and at most one upstream
  attempt per card every `MIN_RETRY_SECONDS` (default 120 s) even after
  failures, whatever the traffic. The files are tiny and static; if per-IP
  limiting is wanted later, put it in front (Cloudflare, nftables).
- Everything runs as the unprivileged `statscache` user with a hardened unit.
  The access log drops client IPs and headers.

## Files

| File                                     | Installed to                                    |
| ---------------------------------------- | ----------------------------------------------- |
| `bin/stats-cache-refresh`                | `/usr/local/bin/`                               |
| `cards.conf` (the allowlist)             | `/etc/stats-cache/`                             |
| `stats-cache.env` (freshness, timeouts)  | `/etc/stats-cache/` (kept if already present)   |
| `systemd/stats-cache-refresh.{service,timer,path}` | `/etc/systemd/system/`                |
| `Caddyfile.stats-cache` (template)       | `/etc/stats-cache/Caddyfile.site` (rendered)    |

## Deploy

1. DNS: point a new hostname (for example `stats.example.com`) at
   198.12.123.41. Caddy gets the certificate itself on first use.
2. On vps01, from this directory, as root. `STATS_HOSTNAME` is required here:
   without it no Caddy site block is rendered and step 3 has nothing to import.

   ```sh
   sudo STATS_HOSTNAME=stats.example.com ./install.sh
   ```

   Re-running is safe. It creates the user, directories, units and timers, then
   fetches the first copies. Check them:

   ```sh
   ls -l /var/lib/stats-cache/www
   systemctl list-timers stats-cache-refresh.timer
   journalctl -u stats-cache-refresh -n 20
   ```

3. Add the site block to Caddy **without editing the existing edge block**.
   `install.sh` rendered a copy with the hostname filled in; append it to the
   Caddyfile (or `import` it) and reload:

   ```sh
   echo 'import /etc/stats-cache/Caddyfile.site' | sudo tee -a /etc/caddy/Caddyfile
   sudo caddy validate --config /etc/caddy/Caddyfile
   sudo systemctl reload caddy
   ```

4. Check:

   ```sh
   curl -sI https://stats.example.com/stats.svg      # 200, image/svg+xml
   curl -sI https://stats.example.com/top-langs.svg  # 200
   curl -sI https://stats.example.com/anything-else  # 404
   ```

   If Caddy cannot write `/var/log/caddy/stats-cache-access.log`, visits will
   not trigger refreshes (the timer still works); see `journalctl -u caddy`.

5. Point the profile README at the cache by replacing the two Vercel URLs:

   - stats card: `https://stats.example.com/stats.svg`
   - top languages: `https://stats.example.com/top-langs.svg`

   The theme and options are baked into `cards.conf`. To change a card, edit
   it, re-run `install.sh`, and delete `/var/lib/stats-cache/www/<name>.svg`
   (the next timer run or visit then fetches it).

## Rollback

- Revert the README to the Vercel URLs. Nothing else depends on the cache.
- Remove the stats site block from `/etc/caddy/Caddyfile` and reload Caddy. The
  bearer-token edge site is never modified by this setup.
- `sudo ./uninstall.sh` removes the units, script and config but keeps cached
  cards; `sudo ./uninstall.sh --purge` also deletes `/var/lib/stats-cache`, the
  log and the `statscache` user.

## Tests

`npm test -- tests/deploy` runs the refresh script against a local fake
upstream: allowlist, fresh/stale handling, non-200, timeout, error-card and
non-card bodies never overwriting the last good copy, and retry spacing.
