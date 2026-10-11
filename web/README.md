# arkhe.priet.us — marketing / legal site

Astro + Tailwind site (same stack as the other app sites), served at <https://arkhe.priet.us>:

- `/` — landing (`src/pages/index.astro` + `src/components/`)
- `/privacy` — Privacy Policy (`src/pages/privacy/`) — the App Store *Privacy Policy URL*
- `/support` — Support page (`src/pages/support/`) — the App Store *Support URL*

`/privacy` and `/support` are required by App Store Connect: keep both paths working.
Shared values (App Store URL/ID, contact, source, push relay host) live in `src/data.ts`.
Screenshots come from `../docs/screenshots/` (copied into `src/assets/screenshots/`).

## Develop

```sh
npm install
npm run dev        # http://localhost:4321
npm run build      # → dist/
```

## Deploy

```sh
./deploy.sh
```

Builds and rsyncs `dist/` to `/srv/sites/arkhe-site/public/` on `mail.priet.us`, then hands
ownership back to `www-data`. The build emits `privacy.html` / `support.html`
(`build.format: 'file'`); the vhost's `try_files $uri $uri/ $uri.html` serves them at the
clean URLs.

## Hosting

nginx on `mail.priet.us` (89.47.167.133). Public `:443` is SNI-routed (stream) to an internal
`127.0.0.1:9443` nginx that terminates TLS per domain. TLS via Let's Encrypt
(`certbot --webroot -w /var/www/html`). The vhost is `arkhe.priet.us.conf` in this folder
(`/etc/nginx/sites-enabled/` on the server); reload only if it changes
(`sudo nginx -t && sudo systemctl reload nginx`).
