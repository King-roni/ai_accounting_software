# Cycle B02 (Tenancy & Access) — complete

**Date:** 2026-05-28
**Cycle UUID:** `381c73b1-4d67-42bb-8d01-5ac691218f76`
**Final state:** 54/54 total · 54 done · **0 backlog** · 0 cancelled
**Sessions consumed:** 2 (2026-05-26..27 prior session + 2026-05-28 closeout)

This is the **per-cycle wrap-up** required by the handoff cadence rule. Its purpose is to give the consumer cycles (B03, B05, B14, B02 implementation phases) a single-page punch list of cross-block coordination items they MUST pick up when they start. Per the user's binding cross-reference rule: *"if we build A and after 2 weeks B is also done, but then A doesn't work because you didn't listen to the cross reference, everything will break."*

---

## 1. Tickets closed across the cycle

- **Prior session (2026-05-26..27):** BOOK-164..211 (48 tickets across B02·P02-P08 + B10·P01-P07)
- **This session (2026-05-28):** BOOK-212, 214, 216, 219, 221, 222, 224, 226, 227, 230, 232, 235, 237, 239, 241 — 15 tickets covering B02·P08 (Drive folder + OAuth refresh + scope assertion), B02·P09 (role-change propagation full cluster), B02·P10 (tenant-isolation test suite + alert routing), B02·P11 (settings UX + email change + sessions + audit feed)

---

## 2. Canonical sub-docs authored this cycle

| Session | Doc | Anchor / routine | Lines |
|---|---|---|---|
| Prior | `fuzzy_match_algorithm_policy.md` | routine | ~270 |
| Prior | `passkey_relying_party_integration.md` | routine | ~240 |
| Prior | `mfa_backup_codes_policy.md` | routine | ~300 |
| Prior | `mfa_required_role_rechallenge_policy.md` | routine | ~250 |
| Prior | `currency_comparison_reference_policy.md` | routine | ~250 |
| Prior | `strong_probable_threshold_policy.md` | routine | ~230 |
| Prior | `principal_context_schema.md` | **anchor** | ~310 |
| Prior | `split_payment_combinatorial_bounds.md` | routine | ~250 |
| Prior | `application_query_helper_policy.md` | routine | ~330 |
| Prior | `split_payment_review_issue_payload_schema.md` | routine | ~370 |
| Prior | `dedup_pattern_ownership_map.md` | **anchor** | ~300 |
| Prior | `step_up_surface_registry_schema.md` | routine | ~320 |
| Prior | `rejection_memory_privileged_override_ui_spec.md` | routine | ~350 |
| Prior | `invitation_email_template.md` | routine | ~280 |
| Prior | `google_cloud_project_setup.md` | **anchor** | ~270 |
| Prior | `rejection_permanence_user_education_ui_spec.md` | routine | ~340 |
| **This session** | `oauth_scope_assertion_policy.md` | routine | ~160 |
| **This session** | `role_change_propagation_policy.md` | **anchor** | ~210 |
| **This session** | `role_change_mid_flight_banner_ui_spec.md` | routine | ~190 |
| **This session** | `tenant_isolation_test_suite_policy.md` | **anchor** | ~280 |
| **This session** | `account_email_change_flow_policy.md` | routine | ~280 |
| **This session** | `session_device_fingerprint_capture_policy.md` | routine | ~270 |
| **This session** | `personal_audit_feed_policy.md` | routine | ~290 |

23 new canonical docs total. 5 anchor docs (BOOK-181 principal context, BOOK-198 dedup ownership, BOOK-208 GCP setup, BOOK-221 role-change propagation, BOOK-226/227/230 tenant-isolation test suite).

---

## 3. Cross-block coordination items — punch list by consumer

These are the items downstream cycles MUST pick up. Each is filed as a KG triple under a `b##p##_*` subject prefix.

### 3.1 B02·P02 (auth + email — implementation phase)

| Item | Source |
|---|---|
| Add `revoked_reason` enum value `EMAIL_CHANGED` to `user_sessions.revoked_reason` | BOOK-237 §4 |
| Confirm `user_sessions` has `ip_country_code text`, `ip_address inet`, `client_form_factor text` columns | BOOK-239 §3 |

### 3.2 B02·P04 (role model + canPerform)

| Item | Source |
|---|---|
| Update `rls_helper_functions.md` to read from `app.principal_context_json` GUC rather than re-parse JWT claims piecemeal | BOOK-181 §15 (prior) |
| Helper set extension: `current_business_id`, `is_owner_or_admin_for_user`, `auth.business_ids_for_session`, `auth.canPerform` (currently 4-helper canonical; 7-helper needed per BOOK-181 §12) | BOOK-181 (prior) |

### 3.3 B02·P06 (step-up hooks)

| Item | Source |
|---|---|
| Populate `users.mfa_recent_at` on every successful MFA challenge | Project-meta drawer / Stage-2 follow-up |
| Step-up surface registry MVP seed (5 rows) | BOOK-199 (prior) |
| `business_settings.step_up_opt_in_surfaces jsonb` column migration | BOOK-199 (prior) |

### 3.4 B02·P07 (member + invitation migrations)

| Item | Source |
|---|---|
| `recovery_state` column on `business_entities` | BOOK-206 (prior) |
| `invitation_tokens.last_sent_at` column for resend tracking | BOOK-204 (prior) |
| `user_settings.has_rejected_match boolean DEFAULT false` column | BOOK-209 (prior) |

### 3.5 B02·P08 (OAuth integration foundation — implementation)

| Item | Source |
|---|---|
| `auth.effective_oauth_scopes(token_id uuid) → text[]` SECURITY DEFINER | BOOK-216 §8 |
| `platform_canonical_scopes() → text[]` IMMUTABLE | BOOK-216 §8 |
| Restricted scope justification document for Google verification | BOOK-208 (prior) |
| OAuth client secret rotation procedure | BOOK-208 (prior) |

### 3.6 B02·P11 (account settings — migrations)

| Item | Source |
|---|---|
| `email_change_requests` table + `email_change_status_enum` + PARTIAL UNIQUE INDEX (one PENDING per user) + 2 helper indexes | BOOK-237 §7 |
| 4 SECURITY DEFINER RPCs: `auth.email_change_request`, `auth.email_change_confirm`, `auth.email_change_cancel`, `auth.support_force_email_change` | BOOK-237 §2-§5 |
| `auth.revoke_other_sessions(user_id, except_session_id)` helper | BOOK-237 §4 |
| `gc_email_change_requests` hourly GC job | BOOK-237 §5 |
| `auth.list_my_sessions()` SECURITY DEFINER + `auth.mask_ip(inet)` IMMUTABLE | BOOK-239 §1 + §4.1 |
| `gc_session_ip_redaction` daily job (NULL raw IP after 90d post-revoke) | BOOK-239 §5 |

### 3.7 B02·P10 (tenant-isolation tests — implementation)

| Item | Source |
|---|---|
| `tests` schema (non-production) with `tests.seed_tenant_isolation_fixture()` + `tests.reset_tenant_isolation_fixture()` SECURITY DEFINER | BOOK-226 §2.5 |
| `tests.register_fixture_reset(name, regprocedure)` for downstream-block reset-hook registration | BOOK-226 §2.6 |
| `tests/lint_fixture_extension.sh` CI lint forbidding direct INSERTs into `business_entities` outside canonical seed | BOOK-226 §2.6 |
| GitHub Actions `.github/workflows/test.yml` job `tenant-isolation` + branch protection rule on main | BOOK-230 §5 |

### 3.8 B03·P02 (workflow runner)

| Item | Source |
|---|---|
| `workflow.execute_step` must `SET LOCAL app.principal_context_json` from `workflow_runs.principal_context_snapshot_json` BEFORE any tool-bound code runs, in the SAME transaction (GUC LOCAL is tx-scoped) | BOOK-221 §3 |
| `transaction.run_in_tx(operations jsonb)` SECURITY DEFINER function | BOOK-191 (prior) |

### 3.9 B05·P02 (audit taxonomy) — large batch

Confirm or add these event kinds (severities in parentheses):

| Event | Severity | Source |
|---|---|---|
| `AUTH_OAUTH_GRANT_INFLATED` | MEDIUM | BOOK-216 §7 |
| `AUTH_OAUTH_SCOPE_INSUFFICIENT` | MEDIUM | BOOK-216 §7 |
| `EMAIL_CHANGE_REQUESTED` | MEDIUM | BOOK-237 §6 |
| `EMAIL_CHANGE_PASSWORD_REJECTED` | MEDIUM | BOOK-237 §6 |
| `EMAIL_CHANGE_REQUEST_SUPERSEDED` | LOW | BOOK-237 §6 |
| `EMAIL_CHANGE_CONFIRM_INVALID` | MEDIUM | BOOK-237 §6 |
| `EMAIL_CHANGE_CONFIRM_EXPIRED` | LOW | BOOK-237 §6 |
| `EMAIL_CHANGE_CONFIRM_USER_MISMATCH` | **HIGH** | BOOK-237 §6 (feeds security alerting) |
| `EMAIL_CHANGED` | HIGH | BOOK-237 §6 |
| `EMAIL_CHANGE_CANCELLED` | LOW | BOOK-237 §6 |
| `MATCHING_REJECTION_OVERRIDDEN_PRIVILEGED` | HIGH | BOOK-202 (prior) |
| `MATCHING_REJECTION_UNDONE_VIA_GRACE_PERIOD` | LOW | BOOK-209 (prior) |
| `MATCHING_REJECTION_FIRST_TIME_EDUCATED` | LOW | BOOK-209 (prior) |
| `MATCHING_SPLIT_PAYMENT_TIMEOUT/FALLBACK_GREEDY/BOUNDS_UPDATED` | LOW each | BOOK-188 (prior) |
| `MATCHING_SPLIT_PAYMENT_PAYLOAD_INVALID` | MEDIUM | BOOK-192 (prior) |
| `MATCHING_AMOUNT_EUR_MISSING` | MEDIUM | BOOK-178 (prior) |
| `FX_NORMALISATION_ADJUSTED` | LOW | BOOK-178 (prior) |
| `STEP_UP_SURFACE_REGISTERED/MODIFIED/RETIRED` | LOW each | BOOK-199 (prior) |
| `BUSINESS_STEP_UP_OPT_IN_CHANGED` | LOW | BOOK-199 (prior) |
| `AUTH_INVITATION_RESENT` | LOW | BOOK-204 (prior) |
| `OAUTH_CLIENT_SECRET_ROTATED` | HIGH | BOOK-208 (prior) |
| `TENANCY_MEMBER_SOFT_LIMIT_WARNED` | LOW | BOOK-206 (prior) |
| `SYSTEM_FIXTURE_SEEDED` (test-only) | LOW | BOOK-226 (test fixture) |

Verify these payload field shapes carry the necessary fields:

| Event | Payload coordination |
|---|---|
| `TENANCY_ROLE_CHANGED` | `previous_role` + `new_role` |
| `TENANCY_MEMBER_REMOVED` | `removed_user_id` + `previous_role` + `removed_by` + `removed_at` |
| `ACCESS_DENIED` | `cross_tenant: boolean` flag (consumed by BOOK-226 tests + production cross-tenant alerting) |
| `EMAIL_CHANGED` | `via_support: bool` + optional `support_ticket_id` |
| `AUTH_SESSION_CREATED` | `ip_country_code` ONLY (raw IP forbidden per PII rule) |

### 3.10 B05·P03 (audit read API)

| Item | Source |
|---|---|
| `audit.read_personal_feed(p_from, p_to, p_event_kinds, p_limit, p_offset)` | BOOK-241 §5 |
| `audit.personal_feed_whitelist()` IMMUTABLE | BOOK-241 §5 |
| `audit.compute_actor_display(event, viewer)` | BOOK-241 §5 |
| `audit.compute_business_context(event, viewer)` | BOOK-241 §5 |
| `audit.compute_payload_redacted(event, viewer)` | BOOK-241 §4 + §5 |
| `audit.event_kind_to_surface(event_kind)` | BOOK-241 §5 |
| `lint_pii_in_logs.sh` lint enforcing no raw IPs in application logs | BOOK-239 §5 |

### 3.11 B05·P09 (security alerting)

| Item | Source |
|---|---|
| Register `CROSS_TENANT_ACCESS_ATTEMPT` alert rule with 3 / 1h threshold | BOOK-226 §6 |

### 3.12 B14 (review queue)

| Item | Source |
|---|---|
| Add review-issue type `OAUTH_SCOPE_INSUFFICIENT` | BOOK-216 §5 |
| New filter chip "role changed with active work" on team-members UI (extension to BOOK-205 spec) | BOOK-222 §5 |

### 3.13 B10 (matching engine — schema verification)

| Item | Source |
|---|---|
| 5 reproducibility FX columns on `match_records`: `fx_rate_transaction_side`, `fx_rate_document_side`, `ecb_rate_date_used`, `original_currency_transaction`, `original_currency_document` | BOOK-178 (prior) |
| `matching.undo_recent_rejection(rejection_id)` SECURITY DEFINER RPC | BOOK-209 (prior) |

### 3.14 Design system + components

| Item | Source |
|---|---|
| `--color-action-permanent-warning` design token | BOOK-209 (prior) |
| `--color-bg-info-subtle`, `--color-bg-warning-subtle`, `--color-status-info`, `--color-status-warning` (verify exist in token map) | BOOK-222 §3 |

---

## 4. Stage-6 drift queue additions from this cycle

These are the doc-level inconsistencies the cycle surfaced. They feed the Cycle-16 reconciliation (to be created from KG drift triples when Stage 3 nears completion):

| Drift | Affected doc(s) | Action |
|---|---|---|
| `settings_page_ui_spec.md` uses 4-role enum (OWNER/ADMIN/ACCOUNTANT); canonical is 6-role per BOOK-179+206 | settings_page_ui_spec | Rewrite role-gating table; add BOOKKEEPER/REVIEWER/READ_ONLY dropdown options |
| `settings_page_ui_spec.md` says mobile read-only supported; phase doc says desktop-only-in-MVP | settings_page_ui_spec | Remove §Mobile section; replace with desktop-only banner spec |
| `settings_page_ui_spec.md` treats MFA as on/off; phase doc + BOOK-175 require per-factor management | settings_page_ui_spec | Rewrite §MFA to per-factor mgmt with below-required-count refusal |
| `gmail_oauth_integration.md` §Refresh implies fail-fast-to-review by design but doesn't state the rationale; "error backoff, circuit breaker" deliberately absent | gmail_oauth_integration | Add §Backoff-and-circuit-breaker-rationale stating the design intent explicitly |
| Pre-existing drifts from prior session — see project-meta drawer Stage-6 drift queue (B10 5-way scoring, canPerform pre-audit-C1 signature, RLS-deny trigger infeasibility, RLS template archive-lock GUC, short-lived-token hashing inconsistency, invitation expiry 7d-vs-24h doc-doc disagreement, step-up tier-name self-correction, ECB rate column-name, MFA event-name normalisation, permission_matrix action-table column-set, match_records FX columns, helper-function set size, signal-name vocabulary) | Multiple | Continue collecting; Cycle-16 reconciliation |

Stage-6 doc-write candidates (newly surfaced this cycle):

- `account_recovery_runbook.md` — consumed by BOOK-237 §5 Case C for governmental-ID support recovery; verify exists or write
- `audit_event_kind_display_strings.md` — consumed by BOOK-241 §7; per-event-kind display label + i18n key reference
- `maxmind_geoip_integration.md` — consumed by BOOK-239 §3.1; verify exists or write

---

## 5. The cycle's 5 anchor docs

These are the LOAD-BEARING references downstream cycles must read and respect. They are not regular sub-docs; they are the consolidating sources of truth for cross-cutting concerns:

1. **`principal_context_schema.md`** (BOOK-181) — server-resolved authority bundle. All RLS / canPerform / audit context derives from here.
2. **`dedup_pattern_ownership_map.md`** (BOOK-198) — 10 named patterns × 8 blocks × 6 mechanism classes; consolidating Stage-6 dedup reference.
3. **`google_cloud_project_setup.md`** (BOOK-208) — 3 GCP projects per env; 4-6 week verification critical path.
4. **`role_change_propagation_policy.md`** (BOOK-221) — the dispatch model + workflow-runner SET LOCAL contract. Consumed by every block's RLS-policied surface implicitly via the GUC abstraction.
5. **`tenant_isolation_test_suite_policy.md`** (BOOK-226/227/230) — the canonical multi-tenant fixture + 5 adversarial scenarios + CI integration. B12/B13/B15 extensions must follow the §2.6 contract.

When in doubt about a tenancy / auth / security question downstream, search the 5 docs above before writing new policy.

---

## 6. Next: Cycle B10 pickup

Per the Stage-3 execution order (`B02 → B10 → B03 → ...` in project-meta drawer):

**Cycle B10 (Matching Engine):** 12 backlog tickets remaining.
- Cycle UUID: `2b0d88ce-3bf2-4e9c-b9fe-91d91fe08985`
- Existing context: 33/45 already done (33 = prior-session Stage-3 closures + Stage-2 B10·P01-P10 phase tickets)
- Notable Stage-6 drift: B10 has the **5-way scoring docs drift** (see Stage-6 queue in project-meta drawer). Some B10 backlog tickets may surface schema-vs-doc divergence that consumers need to resolve in Stage 6.

Pickup checklist for next session:
1. Load this handoff + project-meta drawer + handoff doc (2026-05-28).
2. `retrieve_cycle` on Cycle B10 UUID.
3. List Cycle B10 backlog tickets (filter by state `06b2fd3b-5d0c-486a-9a37-fe086b725315`).
4. Pick lowest sequence_id; proceed per cadence.

---

## 7. Cadence reminder

Adaptive batching unchanged from the 2026-05-28 handoff:

- **Easy verify-only:** 5-10 per turn, batched, one-line DoD.
- **Verify-only with drift:** 3-5 per turn, terser comments.
- **Routine write-required:** write directly, ~120 lines / 8-10 sections, NO propose-wait.
- **Novel write-required (anchor):** keep propose-wait, ~180 lines / 10 sections max.

Cross-references are LOAD-BEARING. Quality is KING. Speed is secondary.

---

## 8. KG triples filed for this wrap-up

- `cycle_b02` → `completed_at` → `2026-05-28 (54/54)`
- `cycle_b02` → `wrap_up_doc` → `Docs/handoff/2026-05-28_cycle_B02_complete.md`
- `cycle_b02` → `anchor_docs` → 5 (BOOK-181, 198, 208, 221, 226)
- `cycle_b02` → `cross_block_items_count` → 60+ across §3.1-§3.14

End of cycle. Move to Cycle B10.
