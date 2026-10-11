#!/usr/bin/env bash
# Build the Astro site and rsync dist/ to the nginx server.
set -euo pipefail

HOST="teraflops@mail.priet.us"
DEST="/srv/sites/arkhe-site/public/"

cd "$(dirname "$0")"

npm run build

# Upload (with deletion of stale files). The directory is owned by www-data, so write via sudo
# and hand ownership back afterwards (macOS's rsync has no --chown).
rsync -rlptvz --delete --exclude '._*' --rsync-path="sudo rsync" dist/ "$HOST:$DEST"
ssh "$HOST" "sudo chown -R www-data:www-data '$DEST'"

echo "Deployed to https://arkhe.priet.us/"
