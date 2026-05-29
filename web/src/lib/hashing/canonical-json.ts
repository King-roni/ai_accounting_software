/**
 * Canonical JSON serialization (B04·P01).
 *
 * Produces byte-identical output to the Python reference implementation
 * `json.dumps(obj, sort_keys=True, separators=(",", ":"), ensure_ascii=False,
 * allow_nan=False)`. The Python golden values pinned in
 * `api/tests/test_hashing_primitives.py` are the cross-platform contract;
 * the `web/scripts/verify-hashing-goldens.ts` script asserts this module
 * reproduces them.
 *
 *   - Object keys sorted lexicographically, recursive.
 *   - Compact separators (no whitespace).
 *   - Arrays preserve order (positional).
 *   - Non-ASCII characters emitted verbatim (UTF-8). Strings are quoted via
 *     JSON.stringify which handles JSON escaping per RFC 8259.
 *   - NaN / Infinity rejected.
 */

export function canonicalJson(value: unknown): string {
  if (value === null) return "null";
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") {
    if (!Number.isFinite(value)) {
      throw new Error("canonicalJson: non-finite number");
    }
    return JSON.stringify(value);
  }
  if (typeof value === "string") return JSON.stringify(value);
  if (Array.isArray(value)) {
    return "[" + value.map((v) => canonicalJson(v)).join(",") + "]";
  }
  if (typeof value === "object") {
    const obj = value as Record<string, unknown>;
    const keys = Object.keys(obj).sort();
    return (
      "{" +
      keys
        .map((k) => JSON.stringify(k) + ":" + canonicalJson(obj[k]))
        .join(",") +
      "}"
    );
  }
  throw new Error(`canonicalJson: unsupported type ${typeof value}`);
}
