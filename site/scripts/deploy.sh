#!/usr/bin/env bash
#
# Deploy the Hai Awan website to Cloudflare Pages.
#
#   npm run deploy                        # https://awan.ffdev.studio (Pages project "haiawan"), production
#   FF_BRANCH=preview npm run deploy      # preview alias, production untouched
#
# A DIRECT UPLOAD Pages project on the FF Cloudflare account, no git connection: pushing to GitHub
# deploys nothing. wrangler ≥ 4.13x delegates "pages" to Workers unless --force is passed.
# The custom domain awan.ffdev.studio and its CNAME are attached once (scripts/domain.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

PROJECT="${FF_PROJECT:-haiawan}"
BRANCH="${FF_BRANCH:-main}"
ENV_FILE="${FF_ENV:-$HOME/Desktop/dev/ffdevstudio/.env}"

[ -f "$ENV_FILE" ] || { echo "✗ no credentials at $ENV_FILE"; exit 1; }
set -a; . "$ENV_FILE"; set +a
: "${CLOUDFLARE_API_TOKEN:?missing in $ENV_FILE}"
: "${CLOUDFLARE_ACCOUNT_ID:?missing in $ENV_FILE}"

npm run build

npx --yes wrangler@latest pages project list 2>/dev/null | grep -q "│ $PROJECT " \
  || npx --yes wrangler@latest pages project create "$PROJECT" --production-branch main --force

npx --yes wrangler@latest pages deploy dist --project-name "$PROJECT" --branch "$BRANCH" --commit-dirty=true --force
