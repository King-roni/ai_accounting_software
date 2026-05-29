# Supabase RLS Policy Map

**Category:** Reference · **Owning block:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 2)

Comprehensive table-to-RLS-policy mapping for every table in the schema. This document is the
authoritative enumeration; the source-of-truth SQL lives in the migration files. When a new table
is added or a policy changes, this document must be updated in the same PR.

Column legend:
- TI — tenant_isolation (business_id = rls_get_business_id())
- OI — owner_isolation (user_id = rls_get_user_id())
- RG — role_gate (role IN allowed set)
- AO — audit_append_only (INSERT only, no UPDATE/DELETE)

Y = policy present, N = policy absent, — = not applicable for this table.

---

## Block 02 — Tenancy & Access

### users

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `users_owner_isolation_authenticated` | OI | authenticated | SELECT, UPDATE |
| `users_role_gate_admin` | RG | admin, owner | SELECT |

TI: N (users is not business-scoped; one user may belong to multiple businesses)
OI: Y · RG: Y · AO: N

### business_entities

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `business_entities_tenant_isolation` | TI | authenticated | SELECT |
| `business_entities_role_gate_owner` | RG | owner | UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### business_memberships

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `business_memberships_tenant_isolation` | TI | authenticated | SELECT |
| `business_memberships_role_gate_owner_admin` | RG | owner, admin | INSERT, UPDATE, DELETE |

TI: Y · OI: N · RG: Y · AO: N

### sessions

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `sessions_owner_isolation_authenticated` | OI | authenticated | SELECT, UPDATE |
| `sessions_role_gate_admin` | RG | admin, owner | SELECT |

TI: N · OI: Y · RG: Y · AO: N

### invitation_tokens

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `invitation_tokens_tenant_isolation` | TI | authenticated | SELECT |
| `invitation_tokens_role_gate_owner_admin` | RG | owner, admin | INSERT, UPDATE |

Note: invitation_tokens use gen_random_uuid() per data_layer_conventions_policy.md.

TI: Y · OI: N · RG: Y · AO: N

### role_assignments

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `role_assignments_tenant_isolation` | TI | authenticated | SELECT |
| `role_assignments_role_gate_owner` | RG | owner | INSERT, UPDATE, DELETE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 03 — Workflow Engine

### workflow_runs

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `workflow_runs_tenant_isolation` | TI | authenticated | SELECT |
| `workflow_runs_role_gate_owner_admin_bookkeeper` | RG | owner, admin, bookkeeper | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### workflow_phase_states

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `workflow_phase_states_tenant_isolation` | TI | authenticated | SELECT |
| `workflow_phase_states_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### tool_invocations

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `tool_invocations_tenant_isolation` | TI | authenticated | SELECT |
| `tool_invocations_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 04 — Data Architecture

### data_retention_records

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `data_retention_records_tenant_isolation` | TI | authenticated | SELECT |
| `data_retention_records_role_gate_owner_admin` | RG | owner, admin | SELECT |
| `data_retention_records_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 05 — Security & Audit

### audit_log

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `audit_log_append_only_all` | AO | all roles | INSERT only |

No UPDATE or DELETE policy exists for any role including service_role and postgres. The
append-only constraint is enforced at both the RLS layer and the tool layer (security.emit_audit
never issues UPDATE or DELETE).

Per-role SELECT overlays are defined in `audit_log_policies.md` Section 2.

TI: Y (business_id present, scoped per chain level) · OI: N · RG: N · AO: Y

### hash_chain

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `hash_chain_tenant_isolation` | TI | authenticated | SELECT |
| `hash_chain_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 06 — AI Layer

### ai_cache

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `ai_cache_tenant_isolation` | TI | authenticated | SELECT |
| `ai_cache_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### ai_gateway_calls

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `ai_gateway_calls_tenant_isolation` | TI | authenticated | SELECT |
| `ai_gateway_calls_role_gate_engine` | RG | service_role | INSERT |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 07 — Bank Statement Pipeline

### bank_statement_rows

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `bank_statement_rows_tenant_isolation` | TI | authenticated | SELECT |
| `bank_statement_rows_role_gate_bookkeeper` | RG | owner, admin, bookkeeper, accountant | SELECT |
| `bank_statement_rows_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### dedup_fingerprints

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `dedup_fingerprints_tenant_isolation` | TI | authenticated | SELECT |
| `dedup_fingerprints_role_gate_engine` | RG | service_role | INSERT |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 08 — Transaction Classification

### classification_results

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `classification_results_tenant_isolation` | TI | authenticated | SELECT |
| `classification_results_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### vendor_memory

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `vendor_memory_tenant_isolation` | TI | authenticated | SELECT |
| `vendor_memory_role_gate_owner_admin_bookkeeper` | RG | owner, admin, bookkeeper | UPDATE |
| `vendor_memory_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 09 — Document Intake

### documents

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `documents_tenant_isolation` | TI | authenticated | SELECT |
| `documents_role_gate_bookkeeper_accountant` | RG | owner, admin, bookkeeper, accountant | SELECT |
| `documents_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### document_events

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `document_events_tenant_isolation` | TI | authenticated | SELECT |
| `document_events_append_only` | AO | service_role | INSERT |

TI: Y · OI: N · RG: N · AO: Y

---

## Block 10 — Matching Engine

### match_records

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `match_records_tenant_isolation` | TI | authenticated | SELECT |
| `match_records_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### match_signals

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `match_signals_tenant_isolation` | TI | authenticated | SELECT |
| `match_signals_role_gate_engine` | RG | service_role | INSERT |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 11 — Ledger & Cyprus VAT

### ledger_entries

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `ledger_entries_tenant_isolation` | TI | authenticated | SELECT |
| `ledger_entries_role_gate_bookkeeper_accountant` | RG | owner, admin, bookkeeper, accountant | SELECT |
| `ledger_entries_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### vat_entries

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `vat_entries_tenant_isolation` | TI | authenticated | SELECT |
| `vat_entries_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### vies_records

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `vies_records_tenant_isolation` | TI | authenticated | SELECT |
| `vies_records_role_gate_owner_admin_accountant` | RG | owner, admin, accountant | SELECT |
| `vies_records_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 12 — OUT Workflow

### out_run_configs

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `out_run_configs_tenant_isolation` | TI | authenticated | SELECT |
| `out_run_configs_role_gate_owner_admin` | RG | owner, admin | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 13 — IN Workflow + Invoice Generator

### invoices

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `invoices_tenant_isolation` | TI | authenticated | SELECT |
| `invoices_role_gate_owner_admin_bookkeeper` | RG | owner, admin, bookkeeper | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### invoice_lines

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `invoice_lines_tenant_isolation` | TI | authenticated | SELECT |
| `invoice_lines_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### credit_notes

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `credit_notes_tenant_isolation` | TI | authenticated | SELECT |
| `credit_notes_role_gate_owner_admin_bookkeeper` | RG | owner, admin, bookkeeper | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### in_run_configs

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `in_run_configs_tenant_isolation` | TI | authenticated | SELECT |
| `in_run_configs_role_gate_owner_admin` | RG | owner, admin | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 14 — Review Queue

### review_issues

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `review_issues_tenant_isolation` | TI | authenticated | SELECT |
| `review_issues_role_gate_bookkeeper_accountant_reviewer` | RG | owner, admin, bookkeeper, accountant, reviewer | SELECT, UPDATE |
| `review_issues_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### issue_history

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `issue_history_tenant_isolation` | TI | authenticated | SELECT |
| `issue_history_append_only` | AO | service_role | INSERT |

TI: Y · OI: N · RG: N · AO: Y

---

## Block 15 — Finalization & Secure Archive

### archive_bundles

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `archive_bundles_tenant_isolation` | TI | authenticated | SELECT |
| `archive_bundles_role_gate_owner_admin_accountant` | RG | owner, admin, accountant | SELECT |
| `archive_bundles_role_gate_engine` | RG | service_role | INSERT |

Note: archive_bundles does not permit UPDATE for any role. The archive is write-once.

TI: Y · OI: N · RG: Y · AO: N (INSERT-only enforced by policy design, not AO type)

### period_snapshots

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `period_snapshots_tenant_isolation` | TI | authenticated | SELECT |
| `period_snapshots_role_gate_owner_admin_accountant` | RG | owner, admin, accountant | SELECT |
| `period_snapshots_role_gate_engine` | RG | service_role | INSERT, UPDATE |

TI: Y · OI: N · RG: Y · AO: N

---

## Block 16 — Dashboard & Reporting

### report_jobs

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `report_jobs_tenant_isolation` | TI | authenticated | SELECT |
| `report_jobs_role_gate_owner_admin_accountant` | RG | owner, admin, accountant | INSERT |
| `report_jobs_role_gate_engine` | RG | service_role | UPDATE |

TI: Y · OI: N · RG: Y · AO: N

### dashboard_widget_configs

| Policy name | Type | Roles | Operation |
| --- | --- | --- | --- |
| `dashboard_widget_configs_tenant_isolation` | TI | authenticated | SELECT |
| `dashboard_widget_configs_owner_isolation` | OI | authenticated | INSERT, UPDATE, DELETE |

TI: Y · OI: Y · RG: N · AO: N

---

## Cross-references

- `row_level_security_policies.md` — policy type definitions and universal RLS requirement
- `rls_policy_template.md` — DDL templates for each standard policy type
- `rls_helper_functions.md` — rls_get_business_id, rls_get_user_id, rls_get_user_role definitions
- `audit_log_policies.md` — per-role SELECT overlays for audit_log
