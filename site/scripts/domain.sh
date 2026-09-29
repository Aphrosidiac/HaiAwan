#!/usr/bin/env bash
# One-time: attach awan.ffdev.studio to the "haiawan" Pages project and point its CNAME at it.
# Idempotent: re-running reports what already exists.
set -euo pipefail
ENV_FILE="${FF_ENV:-$HOME/Desktop/dev/ffdevstudio/.env}"
set -a; . "$ENV_FILE"; set +a
PROJECT="${FF_PROJECT:-haiawan}"
HOST="awan.ffdev.studio"
API="https://api.cloudflare.com/client/v4"
auth=(-H "Authorization: Bearer $CLOUDFLARE_API_TOKEN" -H "Content-Type: application/json")

echo "→ Pages custom domain"
curl -s "${auth[@]}" -X POST "$API/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$PROJECT/domains" \
  -d "{\"name\":\"$HOST\"}" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" success" if d["success"] else " "+"; ".join(e["message"] for e in d["errors"]))'

echo "→ DNS"
ZONE=$(curl -s "${auth[@]}" "$API/zones?name=ffdev.studio" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"][0]["id"])')
EXISTING=$(curl -s "${auth[@]}" "$API/zones/$ZONE/dns_records?name=$HOST" | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(r[0]["id"]+" "+r[0]["type"]+" "+r[0]["content"] if r else "")')
if [ -n "$EXISTING" ]; then
  echo " exists: $EXISTING"
else
  curl -s "${auth[@]}" -X POST "$API/zones/$ZONE/dns_records" \
    -d "{\"type\":\"CNAME\",\"name\":\"$HOST\",\"content\":\"$PROJECT.pages.dev\",\"proxied\":true,\"comment\":\"Hai Awan website (Pages project $PROJECT)\"}" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(" created CNAME -> "+d["result"]["content"] if d["success"] else " "+"; ".join(e["message"] for e in d["errors"]))'
fi

echo "→ status"
curl -s "${auth[@]}" "$API/accounts/$CLOUDFLARE_ACCOUNT_ID/pages/projects/$PROJECT/domains/$HOST" \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["result"]; print(" "+r["status"], (r.get("validation_data") or {}).get("status",""), (r.get("verification_data") or {}).get("status",""))'
