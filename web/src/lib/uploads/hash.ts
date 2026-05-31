/** Client-side SHA-256 hex of a file's bytes (matches the 64-char lowercase hex
 *  the DB upload RPCs require). Uses the Web Crypto API (browser only). */
export async function sha256Hex(file: File): Promise<string> {
  const buffer = await file.arrayBuffer();
  const digest = await crypto.subtle.digest("SHA-256", buffer);
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}
