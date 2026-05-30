#!/usr/bin/env bash
# Push secrets INTO 1Password (reverse of sync-env.sh).
#
# Paste keys as KEY=value lines into a gitignored scratch file `secrets.inbox.env`
# at the repo root, then run this. Each known key is upserted into the vault under
# a sensible item/field; the scratch file is left for you to delete afterwards.
# Never commit secrets.inbox.env (it's gitignored).
#
#   cp secrets.inbox.env.example secrets.inbox.env   # fill it in
#   OP_VAULT=Boekhoudings-Dev ./scripts/push-secrets.sh
#   rm secrets.inbox.env                              # once confirmed
set -euo pipefail
cd "$(dirname "$0")/.."
VAULT="${OP_VAULT:-Boekhoudings-Dev}"
INBOX="${1:-secrets.inbox.env}"

command -v op >/dev/null 2>&1 || { echo "✗ 1Password CLI 'op' not found — see Docs/ENV_SETUP.md" >&2; exit 1; }
[ -f "$INBOX" ] || { echo "✗ No '$INBOX' found. Copy secrets.inbox.env.example, fill it in, and re-run." >&2; exit 1; }
op vault get "$VAULT" >/dev/null 2>&1 || { op vault create "$VAULT" >/dev/null; echo "ℹ Created vault '$VAULT'."; }

# KEY -> "item field" mapping (the op:// reference becomes op://VAULT/item/field).
map() {
  case "$1" in
    ANTHROPIC_API_KEY)                 echo "anthropic api_key" ;;
    GOOGLE_DOCUMENT_AI_PROCESSOR_ID)   echo "google document_ai_processor_id" ;;
    GOOGLE_DOCUMENT_AI_SA_JSON)        echo "google document_ai_sa_json" ;;
    GOOGLE_OAUTH_CLIENT_ID)            echo "google oauth_client_id" ;;
    GOOGLE_OAUTH_CLIENT_SECRET)        echo "google oauth_client_secret" ;;
    TSA_URL)                           echo "tsa url" ;;
    TSA_USERNAME)                      echo "tsa username" ;;
    TSA_PASSWORD)                      echo "tsa password" ;;
    VAULT_ADDR)                        echo "vault addr" ;;
    VAULT_TOKEN)                       echo "vault token" ;;
    *)                                 echo "misc $(echo "$1" | tr 'A-Z' 'a-z')" ;;
  esac
}

upsert() { # item field value
  if op item get "$1" --vault "$VAULT" >/dev/null 2>&1; then
    op item edit "$1" --vault "$VAULT" "$2[password]=$3" >/dev/null
  else
    op item create --vault "$VAULT" --category "API Credential" --title "$1" "$2[password]=$3" >/dev/null
  fi
}

n=0
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ""|\#*) continue ;; esac
  key="${line%%=*}"; val="${line#*=}"
  [ -z "$key" ] || [ "$key" = "$line" ] && continue
  read -r item field <<<"$(map "$key")"
  upsert "$item" "$field" "$val"
  echo "  ✓ $key → op://$VAULT/$item/$field"
  n=$((n+1))
done < "$INBOX"

echo "✓ Pushed $n secret(s) to vault '$VAULT'. Delete $INBOX when you're done, then tell me to wire them."
