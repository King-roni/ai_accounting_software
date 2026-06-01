#!/usr/bin/env node
/**
 * Bundle-size performance budget (R7.7).
 *
 * Run after `next build`. Asserts the shipped client JS stays under budget so a
 * dependency or import regression is caught before it reaches users. Budgets are
 * set with headroom above the current footprint (total ~1.3 MB, largest chunk
 * ~236 KB at time of writing) — tighten them as the app is optimised.
 *
 * Usage: `pnpm perf:budget` (after a build) or `pnpm perf:check` (build + budget).
 */
import { existsSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const CHUNKS_DIR = ".next/static/chunks";

// Budgets in bytes.
const BUDGETS = {
  totalClientJs: 2.0 * 1024 * 1024, // total client JS shipped
  largestChunk: 400 * 1024, // any single chunk
};

function jsFilesRecursive(dir) {
  const out = [];
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) out.push(...jsFilesRecursive(full));
    else if (entry.name.endsWith(".js")) out.push(full);
  }
  return out;
}

function fmt(bytes) {
  return `${(bytes / 1024).toFixed(0)} KB`;
}

if (!existsSync(CHUNKS_DIR)) {
  console.error(`✗ ${CHUNKS_DIR} not found — run \`next build\` first.`);
  process.exit(2);
}

const files = jsFilesRecursive(CHUNKS_DIR).map((f) => ({ f, size: statSync(f).size }));
const total = files.reduce((s, x) => s + x.size, 0);
const largest = files.reduce((m, x) => (x.size > m.size ? x : m), { f: "", size: 0 });

const checks = [
  { name: "Total client JS", value: total, budget: BUDGETS.totalClientJs },
  { name: `Largest chunk (${largest.f.split("/").pop()})`, value: largest.size, budget: BUDGETS.largestChunk },
];

let failed = false;
console.log("Bundle budget:");
for (const c of checks) {
  const ok = c.value <= c.budget;
  failed ||= !ok;
  console.log(`  ${ok ? "✓" : "✗"} ${c.name}: ${fmt(c.value)} / ${fmt(c.budget)}`);
}

if (failed) {
  console.error("\n✗ Bundle budget exceeded. Investigate the regression or raise the budget deliberately.");
  process.exit(1);
}
console.log(`\n✓ Bundle within budget (${files.length} chunks).`);
