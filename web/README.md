# arkhe.priet.us — marketing / legal site

Static pages served at <https://arkhe.priet.us>:

- `/` — landing (`public/index.html`)
- `/privacy` — Privacy Policy (`public/privacy.html`) — used as the App Store *Privacy Policy URL*
- `/support` — Support page (`public/support.html`) — used as the App Store *Support URL*

Contact address on the pages: `support@priet.us`.

## Hosting

Served by nginx on `mail.priet.us` (89.47.167.133). Public `:443` is SNI-routed
(stream) to an internal `127.0.0.1:9443` nginx that terminates TLS per domain;
unknown SNI falls through to the app vhosts by default, so no stream-map change
is needed. TLS via Let's Encrypt (`certbot --webroot -w /var/www/html`).

- Docroot: `/srv/sites/arkhe-site/public/` (owner `www-data`)
- vhost: `/etc/nginx/sites-enabled/arkhe.priet.us.conf` (see `arkhe.priet.us.conf`)
- `try_files $uri $uri/ $uri.html` → clean URLs (`/privacy` serves `privacy.html`)

## Deploy / update

```sh
# From this directory. Sync the pages (strip macOS AppleDouble files):
rsync -av --delete --exclude '._*' public/ teraflops@mail.priet.us:/tmp/arkhe-public/
ssh teraflops@mail.priet.us '
  sudo rsync -a --delete /tmp/arkhe-public/ /srv/sites/arkhe-site/public/ &&
  sudo chown -R www-data:www-data /srv/sites/arkhe-site &&
  rm -rf /tmp/arkhe-public'
```

The certificate renews automatically; nginx only needs a reload if the vhost
changes (`sudo nginx -t && sudo systemctl reload nginx`).
