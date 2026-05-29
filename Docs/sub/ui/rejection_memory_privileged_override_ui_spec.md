# rejection_memory_privileged_override_ui_spec

**Category:** UI · **Owning block:** 10 — Matching Engine · **Co-owner:** 02 — Tenancy & Access (step-up) · **Stage:** 4 sub-doc (Layer 2)

UI for the **Owner-only privileged override** that reactivates a previously-rejected `(transaction, document)` match pair. Per `rejection_memory_schema.md` (BOOK-166) §"Privileged override": sets `match_rejection_memory.is_active = false`, requires step-up, emits `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` (HIGH). This sub-doc commits to the settings-page layout, the step-up flow, and the audit-visibility surfaces.

---

## 1. Why Owner-only

Per BOOK-166 §"Privileged override": "Admin is intentionally excluded from this action (Stage 1 decision per Block 10 Phase 06): the 'rejection-is-permanent' guarantee requires the highest accountable role (Owner) to override."

This mirrors the BOOK-179 `permission_matrix` asymmetry where `period:unlock` is also Owner-only for the same accountability reason. Concentrating override authority in the single accountable principal preserves the user-visible promise that rejections are permanent.

---

## 2. Settings page layout

Nested under **Business Settings → Matching → Rejection Memory**. Three-region layout:

### 2.1 Header

```
┌──────────────────────────────────────────────────────────────┐
│  Rejection Memory                                            │
│                                                              │
│  This page shows all `(transaction, document)` pairs that    │
│  users have rejected as matches. Rejections are remembered   │
│  permanently — they're never re-suggested. As Owner, you can │
│  reactivate a rejected pair to allow it to be re-suggested.  │
│                                                              │
│  [47 active rejections]  [3 overridden]                      │
└──────────────────────────────────────────────────────────────┘
```

Count badges link to filtered table views.

If a non-Owner reaches this page (e.g., via direct URL), the page redirects to Settings home with toast "Rejection Memory is Owner-only."

### 2.2 Filter bar

Left-to-right: `[Search counterparty...]` `[Date range ▾]` `[Status: Active ▾]` `[Amount range...]` `[Clear filters]`

- Search: server-side substring match on `counterparties.normalised_name` (per BOOK-172 fuzzy normalisation pipeline).
- Date range: filters by `rejected_at`.
- Status filter: `Active` (default — `is_active=true`) / `Overridden` (`is_active=false`) / `All`.
- Amount range: filters by transaction `amount_eur_minor` per BOOK-178 always-EUR.

### 2.3 Table

| Column | Source field | Display |
|---|---|---|
| Rejected at | `rejected_at` | Relative time + ISO tooltip |
| Transaction | `transaction_id` joined to `transactions` | `amount_display` + `value_date` + `counterparty_label` (40-char trunc) |
| Document | `document_id` joined to `documents` / `invoices` | `invoice_number` (or doc type) + `date` + `counterparty_label` (40-char trunc) |
| Rejected by | `rejected_by_user_id` joined to `users` | 24×24 avatar + display name |
| Reason | `rejection_reason` | 80-char trunc + expand-on-click; "—" if NULL |
| Status | `is_active` | Badge: green "Active" / grey "Overridden" |
| Action | (derived) | Button "Reactivate" if Active; Link "View History" if Overridden |

Default sort: `(is_active DESC, rejected_at DESC)` — Active rejections first, most recent at the top.

Pagination: cursor-based per BOOK-191 §11 (default 50, max 1000). Cursor tuple `(rejected_at DESC, rejection_id DESC)`.

---

## 3. Reactivate action flow

The critical UX path. Six steps:

### Step 1 — User clicks "Reactivate"

Inline action button on an Active-status row. Disabled (greyed out) while the action is in-flight.

### Step 2 — Confirmation modal opens

```
┌────────────────────────────────────────────────────────────┐
│  Reactivate rejected pair?                                 │
│                                                            │
│  This will allow this transaction to be re-suggested as    │
│  matching this document. The original rejection by         │
│  [Jane Doe] on [12 May 2026] will be preserved in audit    │
│  history.                                                  │
│                                                            │
│  ┌──────────────────────┐   ┌──────────────────────┐       │
│  │ TRANSACTION          │   │ DOCUMENT             │       │
│  │ €1,450.00            │   │ INV-2026-0042        │       │
│  │ 10 May 2026          │   │ 8 May 2026           │       │
│  │ Acme Ltd             │   │ Acme Ltd             │       │
│  │ "PAYMENT-INV-0042"   │   │ €1,450.00            │       │
│  └──────────────────────┘   └──────────────────────┘       │
│                                                            │
│  Why are you reactivating this rejection?                  │
│  ┌────────────────────────────────────────────────────┐    │
│  │                                                    │    │
│  │ (required; min 20 chars, max 500)                  │    │
│  │                                                    │    │
│  └────────────────────────────────────────────────────┘    │
│                                                            │
│  [Cancel]                      [Reactivate]                │
└────────────────────────────────────────────────────────────┘
```

Modal width: 640px (wider than step-up's 480 — needs room for side-by-side cards). The Reactivate button is **primary danger style** (red) to signal the consequence; disabled until the reason text-area passes the 20-char min check.

### Step 3 — Step-up modal fires

On Reactivate click → the step-up modal per BOOK-201 `step_up_ui_spec.md` opens.

The surface name is `MATCHING_REJECTION_OVERRIDE` — a new entry that must be added to `step_up_surface_registry` (BOOK-199):

```sql
INSERT INTO step_up_surface_registry VALUES (
  'MATCHING_REJECTION_OVERRIDE',
  'ACCESS_CONTROL_MUTATION',
  300,                                            -- 5-min window per BOOK-195 default
  true,                                           -- mandatory
  false,
  ARRAY['TOTP','PASSKEY','BACKUP_CODE']::mfa_factor_kind_enum[],
  'STEP_UP_REQUIRED',
  'Reactivating a rejected match allows a previously-suppressed pair to re-enter scoring. Owner-only with step-up to enforce the rejection-is-permanent guarantee.',
  '2026-05-27',                                   -- decisions-log ref for this addition
  now(), now(), NULL
);
```

Step-up modal per-surface copy (per BOOK-199 §10 per-surface adaptation):

- Headline: "Verify before overriding a rejection"
- Body: "Reactivating a rejected match is an Owner-only action. Verify your identity to confirm."

Step-up failure: standard rate-limit per BOOK-201 §"Failure UX detail" (3 failures in 60s → 60-second cooldown).

### Step 4 — Backend RPC called with step-up token

```ts
const result = await tenantRpc(client, 'matching.privileged_reject_override', {
  rejection_id: row.id,
  override_reason: reasonTextarea.value,
  step_up_token: stepUpResult.token,
});
```

Uses BOOK-191 `tenantRpc` shape returning `Result<RowOverridden | ApiError>`.

### Step 5 — Backend SECURITY DEFINER RPC executes

Validates:

1. Caller's role on the business is `Owner` (via `current_user_role(business_id) = 'Owner'`).
2. The step-up token is valid for the `MATCHING_REJECTION_OVERRIDE` surface + the requesting user + the business + not consumed + not expired.
3. The `rejection_id` exists and `is_active = true`.
4. The `override_reason` is non-empty and ≤ 500 chars (the table-level CHECK enforces ≤ 500; UI enforces ≥ 20 for non-empty rationale).

On all-validate-pass:

```sql
UPDATE match_rejection_memory
   SET is_active = false
 WHERE id = $rejection_id;

INSERT INTO step_up_tokens_consumed (...) -- per BOOK-195 single-use consumption

PERFORM audit.emit_audit(
  p_event_name => 'MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED',
  p_severity   => 'HIGH',
  p_business_id => $business_id,
  p_after_state => jsonb_build_object(
    'rejection_id', $rejection_id,
    'overridden_by_user_id', current_user_id(),
    'override_reason', $override_reason,
    'original_rejected_by_user_id', $rejection.rejected_by_user_id,
    'original_rejected_at', $rejection.rejected_at,
    'original_rejection_reason', $rejection.rejection_reason
  )
);
```

Returns the updated row.

### Step 6 — UI updates

- Success toast: "Rejection reactivated. The pair will be re-suggested on the next workflow run."
- Row updates inline: status badge transitions from green "Active" to grey "Overridden"; "Reactivate" button becomes "View History" link.
- Confirmation modal closes; step-up modal already dismissed.

### Failure paths

- Validation fail (e.g., non-Owner reached the RPC): `PERMISSION_DENIED` per BOOK-191 → toast "You don't have permission to override rejections" + close modals.
- Step-up token rejected (expired / consumed / wrong surface): `STEP_UP_REQUIRED` → re-prompt step-up.
- Rejection already inactive (race condition with another Owner overriding the same row): `CONFLICT` per BOOK-191 → toast "This rejection was already overridden by another user" + refresh the row to show Overridden status.

---

## 4. Audit visibility

Three surfaces where the override becomes visible:

### 4.1 In the Rejection Memory table

Overridden rows show:

- Grey "Overridden" status badge instead of green "Active".
- Tooltip on hover: "Overridden by [Owner name] on [date]".
- Reason column shows the **original** rejection_reason (preserved per BOOK-166 immutability rule); the override reason is accessible via "View History".

### 4.2 In the audit log explorer (Block 16)

`MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` (HIGH) events appear in the security-events feed of the audit log explorer. Filterable by business + actor + event name + date range. Payload visible per the standard audit-event detail view.

### 4.3 Per-pair audit history modal

Clicking "View History" on an Overridden row opens a chronological event-list modal:

```
┌────────────────────────────────────────────────────────────┐
│  Rejection history                                         │
│  (transaction €1,450.00 · document INV-2026-0042)          │
│                                                            │
│  12 May 2026, 14:23                                        │
│  ▣ MATCHING_REJECTION_RECORDED                             │
│  Rejected by Jane Doe                                      │
│  Reason: "Different period"                                │
│                                                            │
│  12–27 May 2026 (15 days)                                  │
│  ▢ MATCHING_REJECTION_SUPPRESSED ×3                        │
│  Pair excluded from 3 scoring runs.                        │
│                                                            │
│  27 May 2026, 10:42                                        │
│  ▣ MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED                │
│  Overridden by Owner User (you)                            │
│  Reason: "Both invoices were from same client by mistake.  │
│           This one is a legitimate match."                 │
│  Step-up factor: TOTP                                      │
│                                                            │
│  [Close]                                                   │
└────────────────────────────────────────────────────────────┘
```

The aggregated suppression count is a UX summary (the raw audit chain has one event per suppression — aggregated for readability).

---

## 5. Cannot-re-override-after-override

Once a row is overridden (`is_active = false`), the "Reactivate" action is no longer available — the button is replaced by the "View History" link.

If the pair is rejected AGAIN through the standard review-queue path after override, the BOOK-166 §"Upsert-on-re-rejection" semantics fire: `ON CONFLICT DO UPDATE` sets `is_active = true` on the same `(business_id, transaction_id, document_id)` triplet (preserving the original `rejection_id`). At that point the row transitions back to Active status and the Reactivate action becomes available again.

The history modal in §4.3 shows the full lifecycle including any re-rejection-after-override cycles.

---

## 6. Cross-business safety

The Rejection Memory page is **per-business-scoped** via `X-Cypbk-Business-Id` header per BOOK-191. Owner of multiple businesses sees each business's rejections only in that business's context.

The override RPC validates the `rejection_id` belongs to the active `business_id` (RLS-enforced via `rejection_memory_isolation` policy from BOOK-166 §"RLS"). Cross-business override attempts return zero rows from the RLS-scoped SELECT inside the RPC and fail with `NOT_FOUND` per BOOK-191 error shape.

---

## 7. Empty + loading + error states

| State | Display |
|---|---|
| Loading | 5-row skeleton table with header + filter bar visible |
| Empty (no rejections) | Friendly empty-state illustration + copy "No rejections yet. Rejections appear here when users reject proposed matches in the review queue." |
| Empty (filtered set is empty) | "No rejections match your filters" + "Clear filters" button |
| API error (read) | Error banner at top with retry button; details in browser console only |
| API error (override RPC) | Toast with the specific failure reason (per §3 failure paths) |
| Permission denied (non-Owner) | Redirect to Settings home with toast "Rejection Memory is Owner-only" |

---

## 8. Accessibility (WCAG 2.1 AA)

- Table rows have `aria-label="Rejection: [transaction summary] / [document summary] / [status]"`.
- Status badges have `aria-label` matching their visible text.
- Sort + filter dropdowns are announced by screen readers; filter changes announce result count.
- Confirmation modal traps focus per BOOK-201 §"Accessibility"; reason text-area has `aria-required="true"`; Confirm button has `aria-disabled` while text-area is below 20 chars.
- Step-up modal embedded per BOOK-201's existing accessibility contract.
- History modal is also focus-trapped; Esc closes; Tab cycles through close button only.
- Keyboard shortcuts: `r` on a focused Active row triggers Reactivate (with confirmation modal); `h` triggers History (on Overridden rows). Documented in the page's keyboard-shortcuts help dialog.

---

## 9. Mobile

Owner Settings is **desktop-only** per `mobile_write_rejection_endpoints.md`. Reaching this page on mobile shows the standard mobile-rejection page: "Open this page on a desktop browser to manage rejection memory."

Read-only view of the table is also NOT permitted on mobile per the same policy — the page treats the entire route as a write surface because the primary purpose is the override action. The mobile-rejection content explains why.

---

## 10. Performance

The table query uses index `idx_rejection_memory_business_status` (per BOOK-166 §"Indexes" — `(business_id, is_active)` partial WHERE is_active=true for the Active filter; a separate full index for Overridden filter via `(business_id, rejected_at DESC)`).

Filter changes re-query (no client-side filtering — the row set may be large). Debounced at 300ms per BOOK-184 review-card pattern.

Per BOOK-166 §"Performance" expectations: index lookups sub-millisecond; full page-load including all rows + JOIN to `transactions` + `documents` + `users` for display joins, P95 < 500ms at typical row counts (< 10,000 active rejections per business).

---

## 11. Component bindings

| Component | Source |
|---|---|
| Page shell | `SettingsPageShell` + `Breadcrumbs` |
| Filter bar | `SearchInput` + `DateRangePicker` + `StatusFilterDropdown` + `AmountRangeInput` + `ClearFiltersButton` |
| Table | `DataTable` + `BadgeStatus` + `Avatar` + `Truncate` + `RelativeTime` |
| Confirmation modal | `ConfirmDangerousActionModal` (specific variant from `component_library_ui_spec`) |
| Step-up modal | (embedded per BOOK-201 — no separate component on this page) |
| History modal | `Modal` (generic) with `EventTimeline` content |

All per `design_system_tokens` color/spacing/typography.

Storybook stories: empty state, populated with Active rows, populated with Overridden rows, confirmation modal open, step-up modal embedded, history modal open, mobile-rejection page (illustrative; never actually renders on mobile per §9).

---

## 12. Cross-references

- `rejection_memory_schema.md` (BOOK-166) — host schema + privileged override SQL mechanism + audit event source
- `step_up_ui_spec.md` (BOOK-201) — step-up modal embed at §3 step 3
- `step_up_surface_registry_schema.md` (BOOK-199) — needs new `MATCHING_REJECTION_OVERRIDE` registry row added per §3
- `step_up_validity_window_policy.md` (BOOK-195) — 5-min window default for the new surface
- `permission_matrix.md` (BOOK-179) — Owner-only access enforcement; mirrors period:unlock asymmetry
- `application_query_helper_policy.md` (BOOK-191) — `tenantRpc` pattern for the override RPC + `ApiError` shape for failure paths
- `currency_comparison_reference_policy.md` (BOOK-178) — `amount_eur_minor` display source
- `fuzzy_match_algorithm_policy.md` (BOOK-172) — counterparty name normalisation for search filter
- `audit_event_taxonomy.md` — `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` (HIGH) + `MATCHING_REJECTION_RECORDED` (LOW) + `MATCHING_REJECTION_SUPPRESSED`
- `mobile_write_rejection_endpoints.md` — desktop-only enforcement (§9)
- `audit_log_explorer_ui_spec.md` — Block 16 audit explorer where override events surface (§4.2)
- `component_library_ui_spec.md` — base components (§11)
- `design_system_tokens` — color / spacing / typography
- Block 10 Phase 06 — owning phase (rejection memory + privileged override)
- Block 02 Phase 06 — step-up consumer
- Block 16 — audit log explorer consumer
- Stage 1 decision — Admin intentionally excluded from this action; Owner-only accountability concentration
