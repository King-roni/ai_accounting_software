/**
 * MFA recovery codes — generation + redemption.
 *
 * Codes are 10 chars in the format `XXXXX-XXXXX` (alphanumeric upper),
 * bcrypt-hashed at rest per mfa_enrollment_policy.md. 8 codes per batch.
 * Plaintext is shown to the user exactly once at generation; we never
 * persist it.
 */
import { randomBytes } from "node:crypto";
import bcrypt from "bcryptjs";

const ALPHABET = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // ambiguous-glyph-free
const CODE_LEN = 10;
const BATCH_SIZE = 8;
const BCRYPT_COST = 12;

function generateOneCode(): string {
  const chars: string[] = [];
  const bytes = randomBytes(CODE_LEN);
  for (let i = 0; i < CODE_LEN; i++) {
    chars.push(ALPHABET[bytes[i]! % ALPHABET.length]!);
  }
  return `${chars.slice(0, 5).join("")}-${chars.slice(5).join("")}`;
}

export interface GeneratedRecoveryBatch {
  batchId: string;
  plaintext: string[];
  hashed: { code_hash: string; batch_id: string }[];
}

/**
 * Generate one batch of 8 recovery codes. Returns both the plaintext
 * (to display once) and the bcrypt hashes (to persist).
 */
export async function generateRecoveryCodeBatch(): Promise<GeneratedRecoveryBatch> {
  const batchId = crypto.randomUUID();
  const plaintext: string[] = [];
  const hashed: { code_hash: string; batch_id: string }[] = [];
  for (let i = 0; i < BATCH_SIZE; i++) {
    const code = generateOneCode();
    plaintext.push(code);
    const hash = await bcrypt.hash(code, BCRYPT_COST);
    hashed.push({ code_hash: hash, batch_id: batchId });
  }
  return { batchId, plaintext, hashed };
}

/**
 * Check a submitted code against a list of unconsumed code hashes.
 * Returns the matching hash row id, or null.
 */
export async function matchRecoveryCode(
  submitted: string,
  candidates: { id: string; code_hash: string }[],
): Promise<string | null> {
  const normalized = submitted.trim().toUpperCase();
  for (const row of candidates) {
    if (await bcrypt.compare(normalized, row.code_hash)) {
      return row.id;
    }
  }
  return null;
}
