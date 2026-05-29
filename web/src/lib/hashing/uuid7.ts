/**
 * UUID v7 (RFC 9562) — time-sortable IDs (B04·P01).
 *
 * Layout: | 48-bit unix-ms | 4-bit version=7 | 12-bit rand_a |
 *         | 2-bit variant=10 | 62-bit rand_b |
 *
 * Parity with the Python helper in `api/src/cyprus_bookkeeping_api/hashing/
 * uuid7.py` and the Postgres `gen_uuid_v7()` SECURITY DEFINER function.
 */
import { randomBytes } from "node:crypto";

export function newUuid(): string {
  const ms = BigInt(Date.now()) & ((1n << 48n) - 1n);
  const rand = randomBytes(10);

  const b = new Uint8Array(16);
  b[0] = Number((ms >> 40n) & 0xffn);
  b[1] = Number((ms >> 32n) & 0xffn);
  b[2] = Number((ms >> 24n) & 0xffn);
  b[3] = Number((ms >> 16n) & 0xffn);
  b[4] = Number((ms >> 8n) & 0xffn);
  b[5] = Number(ms & 0xffn);
  // byte 6 = version (high nibble = 7) | rand_a high nibble
  b[6] = 0x70 | (rand[0] & 0x0f);
  // byte 7 = rand_a low byte
  b[7] = rand[1];
  // byte 8 = variant (high 2 bits = 10) | rand_b top bits
  b[8] = 0x80 | (rand[2] & 0x3f);
  // bytes 9..15 = rand_b
  b[9] = rand[3];
  b[10] = rand[4];
  b[11] = rand[5];
  b[12] = rand[6];
  b[13] = rand[7];
  b[14] = rand[8];
  b[15] = rand[9];

  const hex = Buffer.from(b).toString("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

export function parseUuid7Timestamp(uuid: string): number {
  const hex = uuid.replace(/-/g, "");
  if (hex.length !== 32) throw new Error("not a 16-byte UUID");
  const version = parseInt(hex[12], 16);
  if (version !== 7) throw new Error(`not a UUID v7 (version=${version})`);
  return parseInt(hex.slice(0, 12), 16);
}
