/**
 * Domain-specific hash derivations (B04·P01).
 *
 * Parity with `api/src/cyprus_bookkeeping_api/hashing/domain.py`. Each
 * wrapper pins the canonical input shape so callers can't accidentally
 * compute a slightly different representation and miss the match.
 */
import { canonicalJson } from "./canonical-json";
import { hashBytes, hashRecord } from "./hash";

export function sourceRowHash(rawRow: string | Buffer | Uint8Array | Record<string, unknown>): string {
  if (typeof rawRow === "string") return hashBytes(rawRow);
  if (Buffer.isBuffer(rawRow) || rawRow instanceof Uint8Array) {
    return hashBytes(rawRow);
  }
  return hashRecord(rawRow);
}

export interface TransactionFingerprintInput {
  date: string;
  amount: string;
  currency: string;
  description: string;
}

export function transactionFingerprint(normalized: TransactionFingerprintInput): string {
  const required = ["date", "amount", "currency", "description"] as const;
  for (const k of required) {
    if (!(k in normalized)) {
      throw new Error(`transactionFingerprint: missing field ${k}`);
    }
  }
  const description = String(normalized.description).replace(/\s+/g, " ").trim().toLowerCase();
  const canonical = {
    date: String(normalized.date),
    amount: String(normalized.amount),
    currency: String(normalized.currency).toUpperCase(),
    description,
  };
  return hashRecord(canonical);
}

export function archiveBundleHash(bundleManifest: Record<string, unknown>): string {
  return hashRecord(bundleManifest);
}

export function defaultDedupKey(toolName: string, inputPayload: unknown): string {
  const payloadCanonical = Buffer.from(canonicalJson(inputPayload), "utf8");
  const nameBytes = Buffer.from(toolName, "utf8");
  const nul = Buffer.from([0]);
  return hashBytes(Buffer.concat([nameBytes, nul, payloadCanonical]));
}
