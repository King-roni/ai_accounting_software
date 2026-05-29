# Session Handoff — 2026-05-28

**Last session ended:** 2026-05-28 (continuation of the 2026-05-26 → Stage-3 transition)
**Stage state:** Stage 3 (sub-doc backlog walk) — IN FLIGHT
**Big change vs prior handoff:** 15 Plane cycles now provisioned and populated — the future-session pickup point is now a cycle, not a BOOK-id.

Read this file end-to-end before doing anything. Then read the project-meta drawer, then `retrieve_cycle` on Cycle B02 (the in-flight one).

---

## 1. What this session did

| Metric | Value |
|---|---|
| Tickets closed | **48** (BOOK-164..211 contiguous) |
| Verify-only closes | 32 |
| Write-required closes (new sub-docs authored) | 16 |
| KG triples filed | ~126 |
| Material Stage-6 drift items surfaced | ~20 |
| Major drift items RESOLVED | 1 (role_enum count drift — canonical = 6-role OWNER/ADMIN/BOOKKEEPER/ACCOUNTANT/REVIEWER/READ_ONLY per BOOK-179 + BOOK-206) |
| Plane cycles created | **15** (Stage-3 · B02..B16) |
| Tickets bulk-added to cycles | 880 (of 881 total; BOOK-1 left unassigned as it's the constitution) |

### 16 sub-docs authored this session

| BOOK | Path |
|---|---|
| 172 | `Docs/sub/policies/fuzzy_match_algorithm_policy.md` |
| 173 | `Docs/sub/integrations/passkey_relying_party_integration.md` |
| 175 | `Docs/sub/policies/mfa_backup_codes_policy.md` |
| 177 | `Docs/sub/policies/mfa_required_role_rechallenge_policy.md` |
| 178 | `Docs/sub/policies/currency_comparison_reference_policy.md` |
| 180 | `Docs/sub/policies/strong_probable_threshold_policy.md` |
| 181 | `Docs/sub/schemas/principal_context_schema.md` |
| 188 | `Docs/sub/reference/split_payment_combinatorial_bounds.md` |
| 191 | `Docs/sub/policies/application_query_helper_policy.md` |
| 192 | `Docs/sub/schemas/split_payment_review_issue_payload_schema.md` |
| 198 | `Docs/sub/reference/dedup_pattern_ownership_map.md` (anchor doc for Stage-6 dedup reconciliation) |
| 199 | `Docs/sub/schemas/step_up_surface_registry_schema.md` |
| 202 | `Docs/sub/ui/rejection_memory_privileged_override_ui_spec.md` |
| 204 | `Docs/sub/reference/invitation_email_template.md` |
| 208 | `Docs/sub/reference/google_cloud_project_setup.md` |
| 209 | `Docs/sub/ui/rejection_permanence_user_education_ui_spec.md` |

---

## 2. Plane cycles — the new pickup structure

15 cycles created on 2026-05-28. Each named `Stage-3 · B## · <Block Name>`. UUIDs persisted to KG triples + listed below.

| # | Cycle | Block | Cycle UUID | Total | Done | Backlog |
|---|---|---|---|---|---|---|
| 1 | **B02 · Tenancy & Access** | 02 | `381c73b1-4d67-42bb-8d01-5ac691218f76` | 54 | 39 | **15** (in-flight) |
| 2 | B03 · Workflow Engine | 03 | `430809b2-3204-4401-8bf9-833c7e2de000` | 54 | 11 | 43 |
| 3 | B04 · Data Architecture | 04 | `1de935db-12b4-4eb9-aa0b-4731cdf56725` | 65 | 11 | 54 |
| 4 | B05 · Security & Audit | 05 | `14cf9a0f-24d0-4c60-9883-c3e363c3d6c6` | 57 | 10 | 47 |
| 5 | B06 · AI Layer | 06 | `c1dc65f4-8cd8-479c-90a0-e7234af73147` | 58 | 11 | 47 |
| 6 | B07 · Bank Statement Pipeline | 07 | `8c9854e0-48d8-4b15-a75a-99abae48b994` | 54 | 10 | 44 |
| 7 | B08 · Classification & Tagging | 08 | `4138ad1c-e8a6-4b79-bb7c-9be6b3f59fdb` | 48 | 10 | 38 |
| 8 | B09 · Document Intake & Extraction | 09 | `34fe7710-0ff4-4b06-8023-76d7061d0857` | 49 | 10 | 39 |
| 9 | **B10 · Matching Engine** | 10 | `2b0d88ce-3bf2-4e9c-b9fe-91d91fe08985` | 45 | 33 | **12** (in-flight) |
| 10 | B11 · Ledger & Cyprus VAT Engine | 11 | `a6fb501c-8ff3-4754-991a-e9839d636f0a` | 53 | 10 | 43 |
| 11 | B12 · OUT Workflow | 12 | `ac437187-e9df-4725-8a2b-10b66b6ee189` | 53 | 10 | 43 |
| 12 | B13 · IN Workflow + Invoice Generator | 13 | `91c1c6ba-2a2a-4ca3-83e2-0dd0406e26a0` | 64 | 12 | 52 |
| 13 | B14 · Review Queue & Human Review | 14 | `174814ff-75bf-4d92-aafa-0405d84c31a9` | 64 | 10 | 54 |
| 14 | B15 · Finalization & Secure Archive | 15 | `f07310c0-7e1e-4142-93b9-5eaed044a8fd` | 62 | 10 | 52 |
| 15 | B16 · Dashboard & Reporting | 16 | `d06a5244-c620-4a18-ab6c-bdea26766ee9` | 100 | 13 | 87 |
| 16 | (Cycle-16 Stage-6 Reconciliation) | — | NOT YET CREATED — will be built from the KG drift queue | — | — | — |

The "Done" counts in non-in-flight cycles reflect the Stage-2 phase tickets (`[B##·P##]` named, no `·SD` suffix) closed during Stage-2 work. Stage-3 SD work for those cycles hasn't started.

### Execution order

`B02 → B10 → B03 → B04 → B05 → B06 → B07 → B08 → B09 → B11 → B12 → B13 → B14 → B15 → B16 → cycle 16 reconciliation`

This matches the Stage-1 build-order dependency graph: tenancy/auth first, then matching (where most of the Stage-3 anchor docs were authored this session), then workflow engine + data foundations, then domain blocks, then top-of-stack consumers, then reconciliation.

---

## 3. Cadence — adaptive batching (agreed mid-session)

The previous handoff suggested 1 ticket per "go" turn. After 48 tickets it was clear this would take 12+ weeks. We agreed to an adaptive cadence that preserves quality while batching:

| Ticket type | Per-turn cadence | What changes vs old cadence |
|---|---|---|
| **Easy verify-only** (clear canonical doc + hook matches) | **5-10 per turn**, batched | One-line "canonical doc + 1-sentence drift note" per ticket; batch state transitions + KG triples |
| **Verify-only with drift** (e.g., BOOK-170, 183, 193) | **3-5 per turn**, terser comments | Drift items in list format, not essays |
| **Routine write-required** (derivative pattern, e.g., BOOK-202, 204, 209) | **Write directly**, ~120 lines / 8-10 sections; **NO propose-wait** | The user can review the closed ticket; propose-wait was the right cost for the first few but redundant once the pattern is established |
| **Novel write-required** (new mechanism, e.g., BOOK-198, 208) | Keep propose-wait but **tighter scope**, ~180 lines / 10 sections max | These are the anchor docs that consolidate Stage-6 — worth the discussion |

### What stays unchanged

- **Cross-references discipline** — load-bearing. Every new sub-doc keeps its Cross-references section (5-15 entries). The user said: "if we build A and after 2 weeks B is also done, but then A doesn't work because you didn't listen to the cross reference, everything will break."
- **Quality over speed** — the user said: "I would rather have longer building time than shorter with bad quality."

### Cross-reference discipline rules (binding)

1. Every new sub-doc ends with a Cross-references section listing 5-15 actual dependencies (not arbitrary).
2. Whenever a new audit event / column / RPC / migration is introduced in a doc, flag it in the DoD comment as "Cross-block coordination flagged for B##·P## implementation" + file a KG triple.
3. **Anchor docs** (e.g., BOOK-198 `dedup_pattern_ownership_map.md`, BOOK-208 GCP setup) get FULL scope. **Routine derivative docs** get tighter scope but KEEP complete cross-refs.
4. Drift items captured per-ticket via KG triples + DoD comments — they feed Cycle-16 reconciliation.
5. Per-cycle wrap-up: at the end of each cycle, produce a 1-page summary of cross-block coordination items that cycle's tickets generated, so the consuming block's cycle picks them up immediately.

---

## 4. Stage-6 drift queue summary

~20 distinct drift items in the KG, organised by category. These feed Cycle-16 reconciliation (to be created from the drift queue).

### A. B10 scoring docs drift (the most material — 5-way conflict)

5 canonical-claiming docs disagree on the scoring model:

- `match_signal_weights.md` (reference): 6 signals, amount 0.30 / date 0.20 / counterparty 0.20 / doc-type 0.10 / recurring 0.15 / reference 0.05
- `match_scoring_weights_policy.md` (policy): 5 signals, amount 0.35 / date 0.25 / description_similarity 0.20 / vendor_memory 0.15 / document_reference 0.05
- `tool_matching_score_pair.md` (tool): 5 signals, amount 0.35 / date 0.20 / reference 0.20 / vendor 0.15 / currency 0.10
- `match_scoring_configs` schema (singular): 4 signals, amount_delta 0.40 / date_proximity 0.30 / counterparty_match 0.20 / reference_string_match 0.10
- `matching_scoring_configs` schema (plural): 3 signals, description 0.40 / amount 0.40 / date 0.20

PLUS: 3 different composite-score thresholds (0.80 / 0.85), different match_level enum names (EXACT/STRONG_PROBABLE/WEAK_POSSIBLE vs STRONG_MATCH/PROBABLE_MATCH/WEAK_MATCH), cross-period window symmetric ±90d vs asymmetric ±30/−60d. Stage-6 must verify which model the live engine implements (BOOK-86..95 migrations shipped).

### B. canPerform pre-audit-C1 shape drift (BOOK-183)

`tool_can_perform_helper.md` (181 lines) documents the pre-audit-C1 signature (`user_id, business_id, surface, operation`) returning `{allowed: bool, reason}`. Project-meta drawer documents the post-audit-C1 reality: signature is `(actor_user_id, surface, action, resource jsonb, business_id, organization_id)` returning `ALLOW / DENY / REQUIRE_STEP_UP`. Referenced from every write tool — needs Stage-6 rewrite.

### C. RLS-deny audit pattern infeasibility (BOOK-193)

`rls_deny_audit_pattern_policy.md` documents an AFTER-trigger-based mechanism for capturing RLS denials. Postgres triggers don't fire on RLS denials (SELECT silently filters; INSERT/UPDATE/DELETE raise + abort before AFTER triggers). Three realistic alternatives identified: application-layer COUNT follow-up (per BOOK-191 §10), SECURITY DEFINER write-wrapper catch, log scraping.

### D. RLS template archive-lock GUC mismatch (BOOK-187)

`rls_policy_template.md` archive-table policy uses `app.archive_lock_active='true'`. Actual B15 shipped GUCs are `app.original_lock_active='1'` (manifest v=1) + `app.adjustment_lock_active='1'` (v≥2). The split is required for B15·P07 functionality.

### E. Short-lived-token hashing strategy drift (BOOK-203)

- `invitation_tokens.id` is the credential, stored plain (no hash).
- `password_reset_tokens.token_hash` is SHA-256 hashed.
- `mfa_backup_codes` are bcrypt-hashed.

All three are "same class" per `data_layer_conventions_policy` but use 3 different storage patterns. Pick one consistent pattern.

### F. Invitation expiry doc-doc disagreement (BOOK-203 / 205)

`invitation_token_schema.md` (BOOK-203) commits to **7-day** expiry via GENERATED column. `team_members_ui_spec.md` (BOOK-205) commits to **24-hour** expiry. Major doc-doc disagreement.

### G. Step-up tier-name drift (self-created in BOOK-177)

My `mfa_required_role_rechallenge_policy.md` §6 references fictional `STANDARD_PRIVILEGED` / `HIGH_PRIVILEGED` tier names. The canonical model per BOOK-195 is surface-driven (FINALIZATION / BUSINESS_SETTINGS_EDIT / etc.), NOT tier-driven. Self-correcting fix.

### H. ECB rate column-name + precision drift (BOOK-176)

`ecb_fx_rate_cache_reference.md` uses `currency_code char(3)` + `rate_eur numeric(18,8)`. `ecb_rate_schema.md` uses `currency_pair` (e.g., `USD/EUR`) + `rate numeric(10,6)`. Same data, different column shapes.

### I. MFA event-name normalisation (BOOK-175)

- `mfa_device_schema.md` uses `MFA_BACKUP_CODE_USED`.
- `mfa_enrollment_policy.md` uses `MFA_RECOVERY_CODE_USED`.

BOOK-175 commits to `MFA_BACKUP_CODE_USED` as canonical; remove the alias from `mfa_enrollment_policy.md`.

### J. permission_matrix action-table column-set inconsistency (BOOK-179)

Action-level tables use a 4-column view (org:owner / org:admin / org:accountant / org:viewer); consolidated matrix uses 6 columns (Owner / Admin / Bookkeeper / Accountant / Reviewer / Read-only). Bookkeeper rows referenced inline but not shown as columns in the action tables.

### K. Match records FX columns may need migration (BOOK-178)

`currency_comparison_reference_policy.md` §4 commits to 5 reproducibility columns on `match_records`: `fx_rate_transaction_side`, `fx_rate_document_side`, `ecb_rate_date_used`, `original_currency_transaction`, `original_currency_document`. Stage-6 must verify the live `match_records` table has these (BOOK-86..95 migrations shipped; may not include all 5).

### L. Helper-function set size drift (BOOK-189)

`rls_helper_functions.md` has the canonical 4-helper set (`current_org / current_user_id / current_user_businesses / current_user_role`). My BOOK-181 `principal_context_schema.md` §12 lists 7 helpers (adds `current_business_id`, `is_owner_or_admin_for_user`, `auth.business_ids_for_session`, `auth.canPerform`). Stage-6 either extends the canonical helper set or downgrades BOOK-181 §12 references to "proposed."

### M. Signal-name vocabulary drift (BOOK-210)

`match_reason_prompt.md` system-prompt uses 7 fine-grained signal names (amount_exact, amount_close, counterparty_name_exact, counterparty_name_fuzzy, reference_number_match, date_within_window, date_outside_window). Doesn't match the 4-6 signal taxonomies in the BOOK-170 / BOOK-190 scoring docs.

### N. Documentation organisation gaps (Stage-6 polish)

- BOOK-186 edit-and-confirm flow split across UI spec + rejection-memory schema; could be extracted to a dedicated doc.
- BOOK-187 RLS template lacks updated archive-lock GUC model.
- BOOK-201 step-up UI lacks backup-code factor in the factor switcher.
- BOOK-205 team_members_ui_spec missing bulk operations + search sections.
- BOOK-208 references a "Restricted scope justification document" that needs drafting before Google verification.

### O. Resolved this session ✅

- **role_enum count drift** — BOOK-179 + BOOK-206 both confirm 6-role canonical (OWNER/ADMIN/BOOKKEEPER/ACCOUNTANT/REVIEWER/READ_ONLY). BOOK-203 + BOOK-205 use outdated 4-role versions; need Stage-6 doc update only.

---

## 5. Cross-block coordination items (for downstream cycle pickup)

When the consumer block's cycle starts, it must pick these up:

| Item | Created by | Consumer block |
|---|---|---|
| `MATCHING_REJECTION_OVERRIDE` step-up surface registry entry (with INSERT SQL) | BOOK-202 | B02·P06 migration |
| `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` (HIGH) audit event | BOOK-202 | B05·P02 taxonomy |
| `MATCHING_REJECTION_UNDONE_VIA_GRACE_PERIOD` (LOW) audit event | BOOK-209 | B05·P02 taxonomy |
| `MATCHING_REJECTION_FIRST_TIME_EDUCATED` (LOW) audit event | BOOK-209 | B05·P02 taxonomy |
| `user_settings.has_rejected_match boolean DEFAULT false` column | BOOK-209 | B02·P07 / B10·P06 migration |
| `--color-action-permanent-warning` design token | BOOK-209 | Design system |
| `matching.undo_recent_rejection(rejection_id)` SECURITY DEFINER RPC | BOOK-209 | B10·P06 implementation |
| `STEP_UP_SURFACE_REGISTERED/MODIFIED/RETIRED` audit events | BOOK-199 | B05·P02 taxonomy |
| `business_settings.step_up_opt_in_surfaces jsonb` column | BOOK-199 | B02·P06 migration |
| `MATCHING_SPLIT_PAYMENT_TIMEOUT/FALLBACK_GREEDY/BOUNDS_UPDATED` audit events | BOOK-188 | B05·P02 taxonomy |
| `MATCHING_SPLIT_PAYMENT_PAYLOAD_INVALID` audit event | BOOK-192 | B05·P02 taxonomy |
| `MATCHING_AMOUNT_EUR_MISSING` audit event | BOOK-178 | B05·P02 taxonomy |
| `FX_NORMALISATION_ADJUSTED` audit event | BOOK-178 | B05·P02 taxonomy |
| 5 reproducibility FX columns on `match_records` | BOOK-178 | B10·P02 schema verification |
| `backup_codes_used_indexes smallint[]` column on `mfa_devices` | BOOK-175 | B02·P03 migration |
| `recovery_state` column on `business_entities` | BOOK-206 | B02·P07 migration |
| `TENANCY_MEMBER_SOFT_LIMIT_WARNED` audit event | BOOK-206 | B05·P02 taxonomy |
| `BUSINESS_STEP_UP_OPT_IN_CHANGED` audit event | BOOK-199 | B05·P02 taxonomy |
| `OAUTH_CLIENT_SECRET_ROTATED` audit event | BOOK-208 | B05·P02 taxonomy |
| `AUTH_INVITATION_RESENT` audit event + `invitation_tokens.last_sent_at` column | BOOK-204 | B02·P07 migration |
| `transaction.run_in_tx(operations jsonb)` SECURITY DEFINER function | BOOK-191 | B03·P02 implementation |
| `rls_deny_observe_enabled` feature flag | BOOK-191 | Feature-flag infrastructure |
| `app.principal_context_json` GUC | BOOK-181 | B02·P04 / B02·P05 helper-function update |
| Restricted scope justification document for Google verification | BOOK-208 | Pre-launch deliverable |

---

## 6. Operating rules (don't deviate)

Same as previous handoff, plus the cycle-aware updates above. Highlights:

- **Verify next item via Plane** — never say "likely" about the next phase.
- **NEVER save files to project root.** Use `Docs/sub/<category>/`, `Docs/handoff/`, `Docs/phases/`, `supabase/migrations/`.
- **MemPalace:** `kg_add` and `kg_query` freely; `add_drawer` + `diary_write` have a known multi-session "Internal tool error" bug — use kg_add for per-ticket facts.
- **KG object field 128-char cap** — split long facts across multiple triples.
- **Concurrency** — all operations parallel/batched in a single message where possible.

---

## 7. Next-session start checklist

1. **Load context** in parallel:
   ```
   mempalace_status
   mempalace_get_drawer(drawer_id="drawer_cyprus_bookkeeping_project-meta_3425d21389e8094e778df48c")
   Read("Docs/handoff/2026-05-28_session_handoff_cycles_provisioned.md")  // THIS FILE
   mcp__plane__retrieve_cycle(project_id="28b250c0-d991-4dcb-a48c-51af27aa17dd", cycle_id="381c73b1-4d67-42bb-8d01-5ac691218f76")  // Cycle B02 — finish first
   ```

2. **Greet briefly** with: "Resuming Stage-3 walk. Cycle B02 has 15 backlog tickets. Cadence: adaptive batching. Cross-references: load-bearing. Quality: KING."

3. **Pick next ticket via Plane** — lowest sequence_id in Cycle B02 still in Backlog state.

4. **Process per cadence** — verify-only batches of 5-10, write-required individually with appropriate scope.

5. **Per-cycle wrap-up** when B02 done — file a 1-page summary of cross-block coordination items in `Docs/handoff/<date>_cycle_B02_complete.md` + KG triples, before starting B10.

---

## 8. Pinned MemPalace queries that might be useful

```
mempalace_kg_query(subject_prefix="BOOK-", limit=50)       # ticket-closure facts
mempalace_kg_query(subject_prefix="stage3_cycle")          # cycle UUIDs + roadmap
mempalace_kg_query(subject_prefix="match_scoring_docs")    # B10 5-way drift items
mempalace_kg_query(subject_prefix="b10p06_implementation")  # cross-block migration coordination
mempalace_kg_query(subject_prefix="b02p07_migration")      # B02·P07 deps
```

---

## 9. End-of-session log

- **48 tickets closed** BOOK-164..211 (32 verify-only + 16 write-required)
- **16 new sub-docs authored** under `Docs/sub/` (see §1)
- **15 Plane cycles created** + 880 tickets bulk-added
- **~126 KG triples filed** including ~20 Stage-6 drift items
- **1 major drift resolved**: role_enum count (6-role canonical confirmed)
- **No build/test runs** required (Stage 3 is doc verification, not code)
- **Roadmap & cycle UUIDs persisted** to KG + this handoff

Welcome to the new session. The plane is on autopilot — just say "Cycle B02" once you've loaded context.
