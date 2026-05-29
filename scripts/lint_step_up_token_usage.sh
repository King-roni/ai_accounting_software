#!/usr/bin/env bash
# CI guard: reject migrations that PERFORM consume_step_up_token (broken pattern
# — silently discards (consumed, reason) tuple). Use SELECT … INTO instead and
# check v_step_up.consumed explicitly.
#
# Wire into CI as:
#   - run: ./scripts/lint_step_up_token_usage.sh
# Exit code 0 = clean. Exit code 1 = violation found.

set -euo pipefail

MIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/supabase/migrations"

# Allowlist: known-superseded historical occurrences. These migrations originally
# shipped the broken PERFORM pattern; CREATE OR REPLACE in
# 20260520000001_b04_audit_fixes.sql rewrites all 3 functions to the safe form.
# Rebuild ordering ensures the final state is correct. Forward-only policy forbids
# rewriting the historical files, so we explicitly allow these 3 lines.
ALLOWED=(
  "20260519000023_retention_engine.sql:152"
  "20260519000024_legal_hold.sql:138"
  "20260519000024_legal_hold.sql:204"
)

# Collect all current matches
grep -RnE -i 'PERFORM[[:space:]]+(public\.)?consume_step_up_token' "${MIG_DIR}" > /tmp/step_up_all.txt 2>/dev/null || true

# Filter out allowlisted lines (match by basename:lineno suffix)
> /tmp/step_up_violations.txt
while IFS= read -r line; do
  [[ -z "${line}" ]] && continue
  filename="$(basename "${line%%:*}")"
  rest="${line#*:}"
  lineno="${rest%%:*}"
  key="${filename}:${lineno}"
  is_allowed=0
  for allow in "${ALLOWED[@]}"; do
    if [[ "${key}" == "${allow}" ]]; then
      is_allowed=1
      break
    fi
  done
  if [[ ${is_allowed} -eq 0 ]]; then
    echo "${line}" >> /tmp/step_up_violations.txt
  fi
done < /tmp/step_up_all.txt
rm -f /tmp/step_up_all.txt

if [[ -s /tmp/step_up_violations.txt ]]; then
  echo "ERROR: 'PERFORM consume_step_up_token' pattern detected in NEW migration(s):"
  echo "  This pattern silently discards the (consumed, reason) tuple, so revoked/expired/"
  echo "  wrong-surface tokens are accepted as valid. Use the safe pattern instead:"
  echo ""
  echo "    SELECT * INTO v_step_up FROM public.consume_step_up_token(...);"
  echo "    IF NOT v_step_up.consumed THEN"
  echo "      RAISE EXCEPTION 'STEP_UP_REJECTED: %', v_step_up.reason USING ERRCODE='42501';"
  echo "    END IF;"
  echo ""
  echo "New violations (allowlist excluded):"
  cat /tmp/step_up_violations.txt
  rm -f /tmp/step_up_violations.txt
  exit 1
fi

rm -f /tmp/step_up_violations.txt
mig_count=$(find "${MIG_DIR}" -name '*.sql' | wc -l | tr -d ' ')
echo "OK: 0 new PERFORM consume_step_up_token violations found in ${mig_count} migrations (${#ALLOWED[@]} historical occurrences allowlisted)."
exit 0
