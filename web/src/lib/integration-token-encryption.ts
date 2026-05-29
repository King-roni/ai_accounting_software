/**
 * Node-side AES-256-GCM encryption for OAuth tokens (B02·P08).
 *
 * Layout: `base64(iv [12 bytes] || tag [16 bytes] || ciphertext)`.
 * Master key comes from `INTEGRATION_TOKEN_ENC_KEY` — 32 bytes, hex-encoded
 * (64 hex chars). Migration path to Supabase Vault is documented in
 * Docs/sub/policies/oauth_token_encryption (when that sub-doc lands); for
 * MVP we use server-only env so plaintext tokens never touch the client.
 */
import { createCipheriv, createDecipheriv, randomBytes } from "node:crypto";

const ALG = "aes-256-gcm";
const IV_BYTES = 12;
const TAG_BYTES = 16;

function getKey(): Buffer {
  const raw = process.env.INTEGRATION_TOKEN_ENC_KEY;
  if (!raw) {
    throw new Error(
      "INTEGRATION_TOKEN_ENC_KEY env var is required for OAuth token storage.",
    );
  }
  const key = Buffer.from(raw, "hex");
  if (key.length !== 32) {
    throw new Error(
      `INTEGRATION_TOKEN_ENC_KEY must decode to 32 bytes (64 hex chars); got ${key.length}.`,
    );
  }
  return key;
}

export function encryptToken(plaintext: string): string {
  if (!plaintext) return "";
  const iv = randomBytes(IV_BYTES);
  const cipher = createCipheriv(ALG, getKey(), iv);
  const ciphertext = Buffer.concat([
    cipher.update(plaintext, "utf8"),
    cipher.final(),
  ]);
  const tag = cipher.getAuthTag();
  return Buffer.concat([iv, tag, ciphertext]).toString("base64");
}

export function decryptToken(payload: string): string {
  if (!payload) return "";
  const buf = Buffer.from(payload, "base64");
  if (buf.length < IV_BYTES + TAG_BYTES) {
    throw new Error("encrypted token payload is too short");
  }
  const iv = buf.subarray(0, IV_BYTES);
  const tag = buf.subarray(IV_BYTES, IV_BYTES + TAG_BYTES);
  const ciphertext = buf.subarray(IV_BYTES + TAG_BYTES);
  const decipher = createDecipheriv(ALG, getKey(), iv);
  decipher.setAuthTag(tag);
  const plaintext = Buffer.concat([
    decipher.update(ciphertext),
    decipher.final(),
  ]);
  return plaintext.toString("utf8");
}
