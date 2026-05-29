/**
 * SHA-256 primitives (B04·P01). Cross-platform parity with
 * `api/src/cyprus_bookkeeping_api/hashing/core.py`.
 */
import { createHash } from "node:crypto";

import { canonicalJson } from "./canonical-json";

export function hashBytes(data: Buffer | Uint8Array | string): string {
  const h = createHash("sha256");
  if (typeof data === "string") {
    h.update(data, "utf8");
  } else {
    h.update(data);
  }
  return h.digest("hex");
}

export function hashFile(source: Buffer | Uint8Array): string {
  // Streaming variant is left to call sites that have a NodeJS.ReadableStream;
  // for the simple buffer case the same hash() works.
  return hashBytes(source);
}

export function hashRecord(value: unknown): string {
  return hashBytes(canonicalJson(value));
}

export function hashChainAppend(prevHash: string, eventPayload: unknown): string {
  const h = createHash("sha256");
  h.update(prevHash, "utf8");
  h.update(canonicalJson(eventPayload), "utf8");
  return h.digest("hex");
}

export const GENESIS_HASH = "0".repeat(64);
