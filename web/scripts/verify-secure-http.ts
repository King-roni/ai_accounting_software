/**
 * Smoke check for the secure-http wrapper.
 *
 *   pnpm dlx tsx web/scripts/verify-secure-http.ts
 *
 * Verifies the no-plaintext guard + pin map sanity without touching real
 * external services. Pin-fingerprint verification with a live host is part
 * of the production cutover checklist (cert-pinning sub-doc); a smoke that
 * hits api.anthropic.com would fail today because the pins are placeholders.
 */
import {
  DEFAULT_PIN_MAP,
  PlaintextBlockedError,
  SecureFetch,
  assertNoPlaceholder,
  findPinSet,
  hexEncode,
  makePinSet,
  pinSetMatches,
  pinSetHasPlaceholder,
} from "../src/lib/secure-http";

let failures = 0;
function check(name: string, pass: boolean, info?: string): void {
  if (pass) {
    console.log(`  ✔ ${name}`);
  } else {
    console.log(`  ✘ ${name}${info ? `  (${info})` : ""}`);
    failures += 1;
  }
}

async function main(): Promise<number> {
  console.log("secure-http smoke check");

  // no-plaintext guard
  const client = new SecureFetch({ pins: new Map() });
  let blocked = false;
  try {
    await client.fetch("http://example.com/");
  } catch (err) {
    blocked = err instanceof PlaintextBlockedError;
  }
  check("plaintext URL is blocked", blocked);

  // pin map structure
  const anth = findPinSet("api.anthropic.com", DEFAULT_PIN_MAP);
  check("anthropic pin set present", anth !== undefined);
  check(
    "anthropic placeholder is detected",
    anth !== undefined && pinSetHasPlaceholder(anth),
  );

  // suffix match
  const sub = findPinSet("oauth2.googleapis.com", DEFAULT_PIN_MAP);
  check("suffix pin covers oauth2.googleapis.com", sub !== undefined);

  // pinSet matches helper
  const synthetic = makePinSet("example.com", ["DEADBEEF"]);
  check(
    "pinSetMatches is case-insensitive",
    pinSetMatches(synthetic, "deadbeef") && pinSetMatches(synthetic, "DeAdBeEf"),
  );

  // hexEncode round-trip
  check("hexEncode emits lowercase hex", hexEncode(new Uint8Array([0xab, 0xcd, 0xef])) === "abcdef");

  // production-mode placeholder assertion
  let prodThrew = false;
  try {
    assertNoPlaceholder(DEFAULT_PIN_MAP, false);
  } catch {
    prodThrew = true;
  }
  check("assertNoPlaceholder fails in prod mode with placeholders", prodThrew);

  // dev-mode skip
  let devThrew = false;
  try {
    assertNoPlaceholder(DEFAULT_PIN_MAP, true);
  } catch {
    devThrew = true;
  }
  check("assertNoPlaceholder allows placeholders in dev mode", !devThrew);

  console.log(failures === 0 ? "all checks pass" : `FAIL: ${failures} check(s) failed`);
  return failures === 0 ? 0 : 1;
}

void main().then((code) => process.exit(code));
