/**
 * Block 04 Phase 01 — hashing & ID utilities (TypeScript mirror).
 *
 * Parity contract with the Python reference (`api/src/.../hashing/`) and
 * the Postgres SQL helpers (migration 20260519000013). Golden values are
 * pinned in `api/tests/test_hashing_primitives.py` and verified by
 * `web/scripts/verify-hashing-goldens.ts`.
 */
export { canonicalJson } from "./canonical-json";
export {
  GENESIS_HASH,
  hashBytes,
  hashChainAppend,
  hashFile,
  hashRecord,
} from "./hash";
export {
  archiveBundleHash,
  defaultDedupKey,
  sourceRowHash,
  transactionFingerprint,
} from "./domain";
export { newUuid, parseUuid7Timestamp } from "./uuid7";
