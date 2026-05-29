# Legal Hold Maximum Window Policy

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Stage:** 4 sub-doc (Layer 2)

The maximum-window parameter that bounds Object Lock retention extension on legal-hold filing: the default value, the per-business override mechanism, the jurisdictional rationale, and the interaction with open-ended (`hold_ends_at IS NULL`) holds. Per the Phase 11 phase doc: "default value, override mechanism, jurisdictional considerations."

This parameter is the input to `object_lock_retention_extension_policy.md` §2's extension calculation. It does NOT cap the legal hold itself — a hold can remain ACTIVE indefinitely via `hold_ends_at IS NULL`. It only caps the Object Lock retention extension applied at the Storage platform layer.

---

## 1. Default value: 10 years

```sql
CREATE TABLE archive.legal_hold_window_config (
  region                  text PRIMARY KEY,                  -- 'EU' for MVP
  max_legal_hold_window   interval NOT NULL DEFAULT '10 years',
  rationale               text NOT NULL,
  updated_at              timestamptz NOT NULL DEFAULT now(),
  updated_by              uuid NOT NULL REFERENCES users(id)
);

INSERT INTO archive.legal_hold_window_config (region, max_legal_hold_window, rationale, updated_by)
VALUES (
  'EU',
  INTERVAL '10 years',
  'Cyprus Income Tax Law (Cap. 297) 7-year retention + 3-year buffer for appeal windows',
  '<bootstrap_user_id>'
);
```

Rationale for 10 years:

- Cyprus VAT (6 years), Cyprus Income Tax (7 years), and Cyprus Civil Procedure (default 6-10 years for litigation hold) all fall within or under 10 years.
- The 3-year buffer above the 7-year tax floor accommodates the longest plausible appeal/review window.
- Beyond 10 years, indefinite Object Lock retention's operational cost exceeds reasonable defense-in-depth value — the engine-layer hook check (per `retention_legal_hold_hook_contract.md`) is the primary mechanism.

---

## 2. Per-business override mechanism

A per-business override is allowed for businesses with exceptional regulatory exposure (e.g., financial-services entities under longer prudential-records rules):

```sql
CREATE TABLE archive.legal_hold_window_business_override (
  business_id            uuid PRIMARY KEY REFERENCES business_entities(id),
  max_legal_hold_window  interval NOT NULL,
  rationale              text NOT NULL,
  approved_by_user_id    uuid NOT NULL REFERENCES users(id),
  approved_at            timestamptz NOT NULL DEFAULT now(),

  CONSTRAINT override_window_within_bounds
    CHECK (max_legal_hold_window >= INTERVAL '10 years'
           AND max_legal_hold_window <= INTERVAL '30 years')
);
```

Constraints:

- **Lower bound: 10 years** — overrides cannot REDUCE the window below the regional default (preserves the legal floor).
- **Upper bound: 30 years** — sanity bound preventing typo errors.

Override RPC (platform-admin only):

```ts
archive.set_business_legal_hold_window({
  business_id: uuid,
  max_legal_hold_window: interval,
  rationale: text,
  step_up_token_id: uuid,
}) → { approved_at: timestamptz }
```

Authorization: platform-admin only (cross-block coordination flagged for B05·P07 admin escalation, equivalent in pattern to `admin_retention_override_runbook.md`). Step-up required. Co-approval per a sibling `admin_legal_hold_window_runbook.md` (Stage-6 doc-write candidate).

Emits `LEGAL_HOLD_WINDOW_OVERRIDE_SET` (HIGH — NEW event; added this cycle).

---

## 3. Resolution priority for the extension calc

```sql
SELECT COALESCE(
  (SELECT max_legal_hold_window FROM archive.legal_hold_window_business_override
   WHERE business_id = $1),
  (SELECT max_legal_hold_window FROM archive.legal_hold_window_config
   WHERE region = (SELECT region_from_business($1))),
  INTERVAL '10 years'                                          -- fallback (should never apply once seeded)
);
```

Resolution order: business-specific override → regional config → fallback default.

---

## 4. Jurisdictional considerations

| Jurisdiction | Typical retention floor | Maximum window | Notes |
|---|---|---|---|
| Cyprus (MVP) | 7 years (Income Tax Law Cap. 297) | 10 years | Default — covers tax + civil litigation |
| EU (other Member States) | Varies (6-10 years typical) | 10-15 years | Per-business override case-by-case |
| US (Stage-2) | Varies by state (4-10 years) | 10 years | Same default as EU |
| UK (Stage-2) | 6 years for VAT, varies for litigation | 12 years | Per-business override likely |

MVP supports EU only per Stage 1 EU-residency. The `region` column is forward-looking.

---

## 5. Open-ended hold interaction

When `legal_holds.hold_ends_at IS NULL` (open-ended hold), Object Lock retention extension uses `hold_started_at + max_legal_hold_window` per `object_lock_retention_extension_policy.md` §2. After that window passes:

- Object Lock retention is REACHABLE for delete by the retention engine — but
- The hold itself remains ACTIVE (no `hold_ends_at` set) — so
- The retention engine's hook returns `on_hold = true` and deletion is skipped at the engine layer.

The two-layer model:

- **Engine-layer hook (primary):** consults `legal_holds`; active hold = skip.
- **Platform-layer Object Lock (defense-in-depth):** prevents delete at Storage even if the engine had a bug.

An open-ended legal hold filed in 2026 will keep records preserved beyond 2036 (the Object Lock floor passes) but still blocked at the engine layer. Object Lock retention does NOT get extended a second time automatically — operators must either lift the hold OR file a "renewal" via a new `legal_holds` row to extend Object Lock further.

`OBJECT_LOCK_EXTENSION_DUE_FOR_RENEWAL` (NEW LOW event) fires from the daily 04:00 UTC scan when an active open-ended hold's Object Lock extension is within 1 year of expiry, alerting operators to renew if appropriate.

---

## 6. Audit events

| Event | Severity | When |
|---|---|---|
| `LEGAL_HOLD_WINDOW_OVERRIDE_SET` | HIGH | Per-business override created or updated |
| `OBJECT_LOCK_EXTENSION_DUE_FOR_RENEWAL` | LOW | Daily scan: open-ended hold has Object Lock extension within 1 year of expiry |

2 NEW events; added to `audit_event_taxonomy.md` this cycle.

---

## 7. Mobile rejection

Override RPC + daily scan are backend-only; no mobile surface.

---

## 8. Cross-references

- `object_lock_retention_extension_policy.md` (B04·P11 seq 424) — consumer of `max_legal_hold_window`
- `legal_hold_lifecycle_policy.md` — open-ended hold semantics (`hold_ends_at IS NULL`)
- `legal_hold_admin_extension_policy.md` (B04·P11 seq 436) — Owner-only at user level; this policy's override is platform-admin-only (distinct surfaces)
- `admin_retention_override_runbook.md` — sibling platform-admin escalation pattern
- `admin_legal_hold_window_runbook.md` (Stage-6 doc-write candidate) — procedure for §2 override
- `audit_event_taxonomy.md` — RETENTION + LEGAL_HOLD domains
- `data_retention_policy.md` — Cyprus 7-year operational + 6-year audit baselines
- Block 04 Phase 07 — Object Lock integration
- Block 04 Phase 11 — owning phase
- Cyprus Income Tax Law Cap. 297 — 7-year retention floor
- Cyprus VAT Law N.95(I)/2000 — 6-year retention floor
