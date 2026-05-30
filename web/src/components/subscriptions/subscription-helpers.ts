// Recurring vendor spend (R2.8). Subscriptions are not a stored entity — they are
// *derived* from two real sources: the OUT side of the ledger (real charges) and
// `recurring_vendor_memory` (the vendors the system has learned are recurring).
// Cadence and next-charge are ESTIMATED from transaction history and sharpen as
// more statements arrive; everything else (amounts, totals, dates) is real.

/** A row the system has learned is a recurring vendor (public.recurring_vendor_memory). */
export interface VendorMemoryRow {
  id: string;
  counterparty_signature: string;
  suggested_type: string | null;
  suggested_tag: string | null;
  confirmations_count: number;
  first_seen_at: string | null;
  last_confirmation_at: string | null;
  counterparty_country: string | null;
  counterparty_vat_number: string | null;
}

/** The slim OUT-transaction shape this screen needs. */
export interface SpendTxn {
  id: string;
  counterparty_name: string | null;
  counterparty_country: string | null;
  amount: number;
  currency: string;
  transaction_date: string;
  system_tag: string | null;
  user_tag: string | null;
}

export interface Cadence {
  label: string;
  months: number;
  /** true when inferred from <2 sightings (assumed monthly) rather than measured. */
  estimated: boolean;
}

export interface Vendor {
  signature: string;
  name: string;
  country: string | null;
  tag: string | null;
  /** Present in recurring_vendor_memory → the system actively tracks it. */
  tracked: boolean;
  confirmations: number;
  occurrences: number;
  /** Most recent charge (positive magnitude). */
  amount: number;
  total: number;
  currency: string;
  firstSeen: string | null;
  lastSeen: string | null;
  cadence: Cadence | null;
  nextCharge: string | null;
  monthlyEquivalent: number;
  charges: { date: string; amount: number }[];
}

/** Mirrors the DB convention `lower(trim(counterparty_name))`. */
export function vendorSignature(name: string | null | undefined): string {
  return (name ?? "").trim().toLowerCase();
}

function median(nums: number[]): number {
  if (nums.length === 0) return 0;
  const s = [...nums].sort((a, b) => a - b);
  const mid = Math.floor(s.length / 2);
  return s.length % 2 ? s[mid] : (s[mid - 1] + s[mid]) / 2;
}

const DAY = 86_400_000;

/** Infer billing cadence from the gaps between consecutive charge dates (ascending). */
export function deriveCadence(datesAsc: string[], tracked: boolean): Cadence | null {
  if (datesAsc.length >= 2) {
    const gaps: number[] = [];
    for (let i = 1; i < datesAsc.length; i++) {
      gaps.push((new Date(datesAsc[i]).getTime() - new Date(datesAsc[i - 1]).getTime()) / DAY);
    }
    const g = median(gaps);
    if (g < 20) return { label: "Weekly", months: 0.25, estimated: false };
    if (g <= 45) return { label: "Monthly", months: 1, estimated: false };
    if (g <= 135) return { label: "Quarterly", months: 3, estimated: false };
    if (g <= 270) return { label: "Semi-annual", months: 6, estimated: false };
    return { label: "Annual", months: 12, estimated: false };
  }
  // Single sighting but the system tracks it → assume monthly until a second charge confirms.
  if (tracked) return { label: "Monthly", months: 1, estimated: true };
  return null;
}

function addMonths(dateStr: string, months: number): string {
  const d = new Date(dateStr);
  const whole = Math.round(months);
  d.setMonth(d.getMonth() + whole);
  return d.toISOString().slice(0, 10);
}

/**
 * Roll OUT transactions + vendor-memory up into per-vendor subscription rows.
 * A vendor qualifies as a subscription when the system tracks it OR it has
 * recurred (≥2 charges) in the ledger — one-off purchases are excluded.
 */
export function rollupVendors(txns: SpendTxn[], memory: VendorMemoryRow[]): Vendor[] {
  const mem = new Map(memory.map((m) => [m.counterparty_signature, m]));
  const groups = new Map<string, SpendTxn[]>();
  for (const t of txns) {
    const sig = vendorSignature(t.counterparty_name);
    if (!sig) continue;
    (groups.get(sig) ?? groups.set(sig, []).get(sig)!).push(t);
  }
  // Make sure tracked vendors with no charges in range still surface.
  for (const sig of mem.keys()) if (!groups.has(sig)) groups.set(sig, []);

  const vendors: Vendor[] = [];
  for (const [sig, rows] of groups) {
    const m = mem.get(sig);
    const tracked = !!m;
    const occurrences = rows.length;
    if (!tracked && occurrences < 2) continue; // one-off, not a subscription

    const sorted = [...rows].sort((a, b) => a.transaction_date.localeCompare(b.transaction_date));
    const mag = (t: SpendTxn) => Math.abs(Number(t.amount));
    const last = sorted[sorted.length - 1];
    const total = sorted.reduce((s, t) => s + mag(t), 0);
    const cadence = deriveCadence(sorted.map((t) => t.transaction_date), tracked);
    const lastSeen = last?.transaction_date ?? m?.last_confirmation_at?.slice(0, 10) ?? null;
    const amount = last ? mag(last) : 0;

    vendors.push({
      signature: sig,
      name: last?.counterparty_name ?? titleCase(sig),
      country: last?.counterparty_country ?? m?.counterparty_country ?? null,
      tag: m?.suggested_tag ?? last?.user_tag ?? last?.system_tag ?? null,
      tracked,
      confirmations: m?.confirmations_count ?? 0,
      occurrences,
      amount,
      total,
      currency: last?.currency ?? "EUR",
      firstSeen: sorted[0]?.transaction_date ?? m?.first_seen_at?.slice(0, 10) ?? null,
      lastSeen,
      cadence,
      nextCharge: cadence && lastSeen ? addMonths(lastSeen, cadence.months) : null,
      monthlyEquivalent: cadence && cadence.months > 0 ? amount / cadence.months : 0,
      charges: sorted.reverse().map((t) => ({ date: t.transaction_date, amount: mag(t) })),
    });
  }
  return vendors.sort((a, b) => b.monthlyEquivalent - a.monthlyEquivalent || b.total - a.total);
}

function titleCase(s: string): string {
  return s.replace(/\b\w/g, (c) => c.toUpperCase());
}

/** Two-letter avatar initials. */
export function vendorInitials(name: string): string {
  const parts = name.trim().split(/\s+/);
  return (parts.length > 1 ? parts[0][0] + parts[1][0] : name.slice(0, 2)).toUpperCase();
}

// Deterministic avatar colour — dark enough for white text to meet AA contrast.
const AVATAR_PALETTE = ["#3a6075", "#5a4f7e", "#2a6b48", "#7e5a3e", "#6a4f72", "#4a5a78", "#7a4a4a", "#3f6a5a"];
export function vendorColor(signature: string): string {
  let h = 0;
  for (let i = 0; i < signature.length; i++) h = (h * 31 + signature.charCodeAt(i)) >>> 0;
  return AVATAR_PALETTE[h % AVATAR_PALETTE.length];
}

export interface SubscriptionStats {
  count: number;
  monthly: number;
  annual: number;
  spendToDate: number;
}
export function subscriptionStats(vendors: Vendor[]): SubscriptionStats {
  const monthly = vendors.reduce((s, v) => s + v.monthlyEquivalent, 0);
  return {
    count: vendors.length,
    monthly,
    annual: monthly * 12,
    spendToDate: vendors.reduce((s, v) => s + v.total, 0),
  };
}
