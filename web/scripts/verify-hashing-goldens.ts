/**
 * Cross-platform parity verification (B04·P01).
 *
 * Imports the TypeScript hashing module and asserts it produces the same
 * golden values pinned in `api/tests/test_hashing_primitives.py`. If this
 * script fails, the TS module has drifted from the Python contract;
 * downstream blocks that compare hashes across platforms will break.
 *
 * Run: `npx tsx scripts/verify-hashing-goldens.ts` (from web/).
 */
import {
  GENESIS_HASH,
  canonicalJson,
  defaultDedupKey,
  hashBytes,
  hashChainAppend,
  hashFile,
  hashRecord,
  newUuid,
  sourceRowHash,
  transactionFingerprint,
} from "../src/lib/hashing";

let failures = 0;

function check(label: string, actual: unknown, expected: unknown) {
  const ok =
    typeof actual === typeof expected &&
    JSON.stringify(actual) === JSON.stringify(expected);
  if (ok) {
    console.log(`  ✓ ${label}`);
  } else {
    failures += 1;
    console.log(`  ✗ ${label}`);
    console.log(`      expected: ${JSON.stringify(expected)}`);
    console.log(`      actual:   ${JSON.stringify(actual)}`);
  }
}

console.log("\ncanonical_json");
check("sorts keys", canonicalJson({ b: 1, a: 2 }), '{"a":2,"b":1}');
check(
  "recursive sort",
  canonicalJson({ b: { y: 1, x: 2 }, a: [3, 2, 1] }),
  '{"a":[3,2,1],"b":{"x":2,"y":1}}',
);
check("array order preserved", canonicalJson([3, 1, 2]), "[3,1,2]");
check("unicode unescaped", canonicalJson({ name: "Søren" }), '{"name":"Søren"}');

console.log("\nhash_bytes");
check(
  "empty",
  hashBytes(Buffer.from("")),
  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
);
check(
  "abc",
  hashBytes(Buffer.from("abc")),
  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
);

console.log("\nhash_file (parity with hash_bytes on a buffer)");
check("buffer", hashFile(Buffer.from("abc")), hashBytes(Buffer.from("abc")));

console.log("\nhash_record");
check(
  "simple {a:1,b:2}",
  hashRecord({ a: 1, b: 2 }),
  "43258cff783fe7036d8a43033f830adfc60ec037382473548ac742b888292777",
);
check(
  "key order insensitive",
  hashRecord({ b: 2, a: 1 }),
  hashRecord({ a: 1, b: 2 }),
);

console.log("\nhash_chain_append");
// Cross-platform golden: Python + SQL both produce this hex for the same input.
const GENESIS_EVENT_CHAIN_HEAD =
  "40c3929457af2429a2a701cd95aa3c28781f141f190bd4440f62334f30c512b5";
check(
  "genesis event matches Python golden",
  hashChainAppend(GENESIS_HASH, { event: "GENESIS", sequence: 0 }),
  GENESIS_EVENT_CHAIN_HEAD,
);
check(
  "genesis event matches local computation",
  hashChainAppend(GENESIS_HASH, { event: "GENESIS", sequence: 0 }),
  hashBytes(GENESIS_HASH + '{"event":"GENESIS","sequence":0}'),
);

console.log("\ntransaction_fingerprint");
const fp1 = transactionFingerprint({
  date: "2026-05-19",
  amount: "100.00",
  currency: "EUR",
  description: "  ACME  Corp Payment ",
});
const fp2 = transactionFingerprint({
  date: "2026-05-19",
  amount: "100.00",
  currency: "EUR",
  description: "acme corp payment",
});
check("description normalization", fp1, fp2);

const fp3 = transactionFingerprint({
  date: "2026-05-19",
  amount: "100.00",
  currency: "eur",
  description: "Lunch",
});
const fp4 = transactionFingerprint({
  date: "2026-05-19",
  amount: "100.00",
  currency: "EUR",
  description: "Lunch",
});
check("currency case-insensitive", fp3, fp4);

console.log("\nsource_row_hash");
const raw = '{"date":"2026-05-19","amount":"100.00"}';
check("string", sourceRowHash(raw), hashBytes(Buffer.from(raw, "utf8")));

console.log("\ndefault_dedup_key");
check(
  "NUL separator prevents confusion",
  defaultDedupKey("foo", {}) === defaultDedupKey("foo{}", {}),
  false,
);
check(
  "payload key order insensitive",
  defaultDedupKey("my_tool", { a: 1, b: 2 }),
  defaultDedupKey("my_tool", { b: 2, a: 1 }),
);

console.log("\nuuid v7");
const u = newUuid();
const re =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
check("shape", re.test(u), true);

// UUID v7 is "time-sortable" at millisecond granularity. The simple
// implementation in `uuid7.ts` does not include a monotonic intra-ms
// counter, so sub-millisecond generations can shuffle. Match Python's
// test pattern: spin at least 1 ms between samples so each gets a
// distinct timestamp prefix.
function busyWaitMs(ms: number): void {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    /* spin */
  }
}
const samples: string[] = [];
for (let i = 0; i < 30; i++) {
  samples.push(newUuid());
  busyWaitMs(2);
}
const sorted = [...samples].sort();
check("sorts in insertion order (ms-spaced)", samples.join("|") === sorted.join("|"), true);

if (failures > 0) {
  console.log(`\n${failures} parity failure(s).\n`);
  process.exit(1);
}
console.log("\nAll cross-platform parity checks passed.\n");
