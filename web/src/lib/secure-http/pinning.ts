/**
 * B05·P01 SPKI pin map + fingerprint helpers (TypeScript).
 *
 * Mirrors api/secure_http/pinning.py — a pin is the SHA-256 of the cert's
 * SubjectPublicKeyInfo (RFC 7469 §2.4), not the cert itself. This survives
 * cert rotation as long as the key is the same.
 *
 * Production deployment must replace the PLACEHOLDER: pins with the actual
 * SPKI fingerprints captured via the cert-pinning sub-doc procedure.
 */

export class PinMismatchError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PinMismatchError";
  }
}

export class PlaintextBlockedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PlaintextBlockedError";
  }
}

export class PlaceholderPinError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "PlaceholderPinError";
  }
}

export interface PinSet {
  readonly host: string;
  readonly fingerprints: ReadonlySet<string>;
}

export function makePinSet(host: string, fingerprints: Iterable<string>): PinSet {
  return {
    host,
    fingerprints: new Set(Array.from(fingerprints, (s) => s.toLowerCase())),
  };
}

export function pinSetMatches(pinSet: PinSet, candidateHex: string): boolean {
  return pinSet.fingerprints.has(candidateHex.toLowerCase());
}

export function pinSetHasPlaceholder(pinSet: PinSet): boolean {
  for (const fp of pinSet.fingerprints) {
    if (fp.startsWith("placeholder:")) return true;
  }
  return false;
}

export type PinMap = ReadonlyMap<string, PinSet>;

/**
 * Pin map: host → PinSet. Mirrors api/secure_http/pinning.py DEFAULT_PIN_MAP.
 * Production deployment MUST replace `placeholder:*` entries.
 */
export const DEFAULT_PIN_MAP: PinMap = new Map<string, PinSet>([
  [
    "api.anthropic.com",
    makePinSet("api.anthropic.com", [
      "placeholder:anthropic-leaf-primary",
      "placeholder:anthropic-leaf-backup",
    ]),
  ],
  [
    "googleapis.com",
    makePinSet("googleapis.com", [
      "placeholder:google-leaf-primary",
      "placeholder:google-leaf-backup",
    ]),
  ],
  [
    "freetsa.org",
    makePinSet("freetsa.org", [
      "placeholder:freetsa-leaf-primary",
      "placeholder:freetsa-leaf-backup",
    ]),
  ],
]);

/**
 * Find the PinSet for the host. Exact match first; then suffix match so
 * pinning ``googleapis.com`` covers ``oauth2.googleapis.com`` etc. Use
 * suffix pins sparingly — they're broader by design.
 */
export function findPinSet(host: string, pins: PinMap): PinSet | undefined {
  const exact = pins.get(host);
  if (exact) return exact;
  for (const [pinnedHost, pinSet] of pins) {
    if (host.endsWith("." + pinnedHost)) return pinSet;
  }
  return undefined;
}

/**
 * Hex-encode an ArrayBuffer/Uint8Array as a lowercase, no-separator string.
 */
export function hexEncode(buf: ArrayBuffer | Uint8Array): string {
  const bytes = buf instanceof Uint8Array ? buf : new Uint8Array(buf);
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

/**
 * Compute the SHA-256 hex of the SubjectPublicKeyInfo bytes (DER-encoded).
 * Use the WebCrypto API which is available in both Node 20+ and browsers.
 *
 * Note: extracting SPKI from a DER-encoded X.509 cert in pure TS is
 * non-trivial. The intended use of this helper is to verify a SPKI buffer
 * the caller already extracted via Node's ``tls.TLSSocket#getPeerCertificate``
 * (which exposes ``cert.pubkey``), or via a CLI tool that emits SPKI DER
 * during pin rotation.
 */
export async function spkiFingerprintFromDer(spkiDer: ArrayBuffer | Uint8Array): Promise<string> {
  // Copy into a fresh, type-stable ArrayBuffer so TS doesn't widen to
  // ArrayBufferLike (which includes SharedArrayBuffer and isn't a BufferSource
  // under strict mode).
  const src = spkiDer instanceof Uint8Array ? spkiDer : new Uint8Array(spkiDer);
  const fresh = new Uint8Array(src.byteLength);
  fresh.set(src);
  const digest = await crypto.subtle.digest("SHA-256", fresh);
  return hexEncode(digest);
}

/**
 * Boot-time assertion: throw if any pin in the map is still a placeholder.
 * Production deployments pass allowInDev=false (the default). Dev/test code
 * passes allowInDev=true to skip the check.
 */
export function assertNoPlaceholder(pins: PinMap, allowInDev = false): void {
  if (allowInDev) return;
  const offenders: string[] = [];
  for (const [host, pinSet] of pins) {
    if (pinSetHasPlaceholder(pinSet)) offenders.push(host);
  }
  if (offenders.length > 0) {
    throw new PlaceholderPinError(
      "secure-http: placeholder pins detected for: " + offenders.sort().join(", "),
    );
  }
}
