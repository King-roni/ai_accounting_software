/**
 * Invitation token helpers (B02·P07).
 *
 * Tokens are 32 random bytes encoded as hex (64 chars). The plain token is
 * placed in the invitation URL and emailed; at rest, only the SHA-256 hash
 * (of the hex string's UTF-8 bytes, matching `digest(text::bytea, 'sha256')`
 * in Postgres) is stored in `organization_invitations.token_hash`.
 */
import { createHash, randomBytes } from "node:crypto";

export function generateInvitationToken(): { plain: string; hash: string } {
  const plain = randomBytes(32).toString("hex");
  const hash = createHash("sha256").update(plain, "utf8").digest("hex");
  return { plain, hash };
}

export function hashInvitationToken(plain: string): string {
  return createHash("sha256").update(plain, "utf8").digest("hex");
}
