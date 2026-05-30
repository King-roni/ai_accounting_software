#!/usr/bin/env bash
# One-time: seed a 1Password vault from your CURRENT local secrets so you can
# switch to op-managed env. Reads existing web/.env.local + api/.env in place;
# it never prints secret values. Safe to re-run (updates the fields).
#
#   OP_VAULT=Boekhoudings-Dev ./scripts/bootstrap-1password.sh
#
# After this, run ./scripts/sync-env.sh and you're on 1Password.
set -euo pipefail
cd "$(dirname "$0")/.."
VAULT="${OP_VAULT:-Boekhoudings-Dev}"

if ! command -v op >/dev/null 2>&1; then
  echo "✗ Install + sign in to the 1Password CLI first — see Docs/ENV_SETUP.md" >&2
  exit 1
fi

# Read a KEY=value from a dotenv file (first match), value may contain '='.
val() { grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- || true; }

SRK="$(val SUPABASE_SERVICE_ROLE_KEY web/.env.local)"
[ -z "$SRK" ] && SRK="$(val SUPABASE_SERVICE_ROLE_KEY api/.env)"
if [ -z "$SRK" ]; then
  echo "✗ Couldn't find SUPABASE_SERVICE_ROLE_KEY in web/.env.local or api/.env." >&2
  exit 1
fi

ENC="$(val INTEGRATION_TOKEN_ENC_KEY web/.env.local)"
if [ -z "$ENC" ]; then
  ENC="$(openssl rand -hex 32)"
  echo "ℹ Generated a fresh INTEGRATION_TOKEN_ENC_KEY (32 bytes hex) — it was unset locally."
fi

op vault get "$VAULT" >/dev/null 2>&1 || { op vault create "$VAULT" >/dev/null; echo "ℹ Created vault '$VAULT'."; }

upsert() { # item field value
  if op item get "$1" --vault "$VAULT" >/dev/null 2>&1; then
    op item edit "$1" --vault "$VAULT" "$2[password]=$3" >/dev/null
  else
    op item create --vault "$VAULT" --category "API Credential" --title "$1" "$2[password]=$3" >/dev/null
  fi
}

upsert supabase service_role_key "$SRK"
upsert web      integration_token_enc_key "$ENC"

echo "✓ Vault '$VAULT' seeded (items: supabase, web). Next: ./scripts/sync-env.sh"
