/**
 * SecureFetch — TypeScript counterpart of api/secure_http/client.py.
 *
 * Wraps the global ``fetch`` to enforce the same outbound HTTP policy:
 *
 *   * https:// scheme only
 *   * For pinned hosts, the SPKI fingerprint of the leaf cert must be in
 *     the configured set
 *
 * Pin verification on Node uses a separate TLS handshake via ``node:tls`` to
 * read the peer's public key DER, then compares the SHA-256 to the
 * configured PinSet. The verified verdict is cached per (host, port) for
 * a short TTL so the per-request cost is one extra socket every ~minute.
 *
 * In a browser, pin verification is not possible (the platform doesn't
 * expose the peer cert). The wrapper still enforces the https-only guard
 * and emits a console warning when a pinned host is dialed from the
 * browser — the source of truth for browser-origin pins is platform-level
 * CT monitoring + HSTS preloading, which the platform enforces.
 */

import {
  DEFAULT_PIN_MAP,
  PinMismatchError,
  PlaintextBlockedError,
  findPinSet,
  hexEncode,
  pinSetMatches,
} from "./pinning";
import type { PinMap } from "./pinning";

const DEFAULT_PIN_CACHE_TTL_MS = 60_000;
const DEFAULT_HANDSHAKE_TIMEOUT_MS = 10_000;

interface CacheEntry {
  verifiedAt: number;
  fingerprint: string;
}

export interface SecureFetchOptions {
  pins?: PinMap;
  cacheTtlMs?: number;
  handshakeTimeoutMs?: number;
}

export class SecureFetch {
  private readonly pins: PinMap;
  private readonly cacheTtlMs: number;
  private readonly handshakeTimeoutMs: number;
  private readonly pinCache = new Map<string, CacheEntry>();

  constructor(opts: SecureFetchOptions = {}) {
    this.pins = opts.pins ?? DEFAULT_PIN_MAP;
    this.cacheTtlMs = opts.cacheTtlMs ?? DEFAULT_PIN_CACHE_TTL_MS;
    this.handshakeTimeoutMs = opts.handshakeTimeoutMs ?? DEFAULT_HANDSHAKE_TIMEOUT_MS;
  }

  async fetch(input: string | URL, init?: RequestInit): Promise<Response> {
    const url = input instanceof URL ? input : new URL(input);
    this.guardScheme(url);
    await this.verifyPinnedHost(url);
    return globalThis.fetch(url, init);
  }

  private guardScheme(url: URL): void {
    if (url.protocol !== "https:") {
      throw new PlaintextBlockedError(
        `plaintext outbound blocked: ${url.toString()} (scheme=${url.protocol}); only https is permitted`,
      );
    }
  }

  private async verifyPinnedHost(url: URL): Promise<void> {
    const host = url.hostname;
    const pinSet = findPinSet(host, this.pins);
    if (!pinSet) return;

    const port = url.port ? Number(url.port) : 443;
    const cacheKey = `${host}:${port}`;
    const now = Date.now();
    const cached = this.pinCache.get(cacheKey);
    if (cached && now - cached.verifiedAt < this.cacheTtlMs) {
      if (pinSetMatches(pinSet, cached.fingerprint)) return;
      this.pinCache.delete(cacheKey);
    }

    const liveFp = await this.fetchLiveSpkiHex(host, port);
    if (!pinSetMatches(pinSet, liveFp)) {
      throw new PinMismatchError(
        `SPKI pin mismatch for ${host}: live fingerprint ${liveFp} ` +
          `not in configured set (${pinSet.fingerprints.size} pins). ` +
          `Either the cert was rotated and the pin set needs updating, ` +
          `or the connection is being intercepted.`,
      );
    }
    this.pinCache.set(cacheKey, { verifiedAt: now, fingerprint: liveFp });
  }

  /**
   * Open a separate TLS handshake (Node-only) and read the peer's
   * public-key DER from the cert. Returns lowercase hex SHA-256.
   *
   * In the browser this throws — callers should restrict pinned outbound
   * calls to server-side code paths.
   */
  private async fetchLiveSpkiHex(host: string, port: number): Promise<string> {
    // dynamic import so the module doesn't pull node:tls into browser bundles
    // (Next.js will tree-shake the server-only path).
    let tls: typeof import("node:tls");
    try {
      tls = await import("node:tls");
    } catch {
      throw new Error(
        `SPKI pin verification unavailable: node:tls not loadable in this runtime. ` +
          `Pinned outbound calls must run server-side.`,
      );
    }

    return await new Promise<string>((resolve, reject) => {
      const socket = tls.connect(
        {
          host,
          port,
          servername: host,
          minVersion: "TLSv1.3",
          // Default chain verification still applies. Pinning is an
          // additional check, not a replacement.
        },
        async () => {
          try {
            const peer = socket.getPeerCertificate(true);
            // node exposes the SPKI DER as `pubkey` (Buffer).
            const pubkeyDer: Buffer | undefined = (peer as { pubkey?: Buffer }).pubkey;
            socket.end();
            if (!pubkeyDer || pubkeyDer.length === 0) {
              reject(new Error(`no peer pubkey returned for ${host}:${port}`));
              return;
            }
            // Copy into a fresh Uint8Array so the SharedArrayBuffer-vs-ArrayBuffer
            // distinction in strict TS doesn't surface here.
            const fresh = new Uint8Array(pubkeyDer.byteLength);
            fresh.set(pubkeyDer);
            const digest = await crypto.subtle.digest("SHA-256", fresh);
            resolve(hexEncode(digest));
          } catch (err) {
            reject(err);
          }
        },
      );
      socket.setTimeout(this.handshakeTimeoutMs, () => {
        socket.destroy(new Error(`tls handshake timeout for ${host}:${port}`));
      });
      socket.on("error", (err) => reject(err));
    });
  }
}

// Default singleton, mirroring api side. Callers can construct a custom one
// for tests with a stub pin map.
export const defaultSecureFetch = new SecureFetch();
