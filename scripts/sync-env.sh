#!/usr/bin/env bash
# Resolve the op:// references in the committed templates into the gitignored,
# runnable env files. Re-run any time you rotate a secret in 1Password.
#
#   ./scripts/sync-env.sh
#
# Requires the 1Password CLI signed in (see docs/ENV_SETUP.md).
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v op >/dev/null 2>&1; then
  echo "✗ 1Password CLI 'op' not found. Install it and sign in — see Docs/ENV_SETUP.md" >&2
  exit 1
fi

op inject -f -i web/.env.local.example -o web/.env.local
op inject -f -i api/.env.example       -o api/.env
echo "✓ Regenerated web/.env.local and api/.env from 1Password (vault refs in the templates)."
