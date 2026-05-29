# Mobile Write Rejection Endpoints

**Category:** Reference data · **Owning block:** 14 — Review Queue · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 1 reference)

The canonical list of endpoints, tool surfaces, and UI affordances that reject `client_form_factor = MOBILE`. Per the Stage 1 decision, mobile is read-only: dashboards / drill-down / queue browsing are allowed; every write surface rejects mobile clients.

Block 14 Phase 09 owns the mobile read-only consumer contract. This sub-doc enumerates the write surfaces every block must reject — Stage 7 implementation enforces the list via shared middleware.

---

## How mobile is detected

`client_form_factor` is set per request:

- HTTP header: `X-Client-Form-Factor: MOBILE | TABLET | DESKTOP`
- Fallback: User-Agent parsing per `tablet_form_factor_policy` (Block 14) — Stage 2+ tablets-as-desktop deferral lives here
- The header is set by the web client at boot based on viewport + touch capability detection

The middleware that enforces this lives in Block 02's API layer per Block 14 Phase 09 — every protected endpoint passes through it.

## Rejection contract

When a mobile client invokes a rejected endpoint:

```
HTTP 403 Forbidden
Content-Type: application/json

{
  "error_code": "MOBILE_WRITE_REJECTED",
  "endpoint": "out_workflow.user_approval",
  "remediation": "This action is desktop-only. Open Cyprus Bookkeeping on a laptop or desktop browser to complete it."
}
```

Audit event: `MOBILE_WRITE_REJECTED` (under the `TENANCY` domain — the rejection is an authorization-flavoured event, not a domain-specific one) with `{ user_id, business_id, endpoint, user_agent }`.

The error message is i18n-aware (per `localized_number_date_format_policy` + EU language extensions). The default English copy is above.

## The endpoints (canonical inventory)

### Block 02 — Tenancy & Access

| Endpoint | Notes |
| --- | --- |
| Settings edits (any) | Per Block 02 Phase 11 — settings is desktop-only in MVP |
| `auth.invite_user` | User invitation flow |
| `auth.rotate_oauth_token` | OAuth refresh writes |
| `auth.grant_role` / `auth.revoke_role` | Role management |
| `auth.update_password` | Password change |

### Block 03 — Workflow Engine

| Endpoint | Notes |
| --- | --- |
| `engine.manual_trigger` | Manual run triggers (HTTP POST /workflow-runs) — per `tool_manual_trigger_api` |
| `engine.pause_run` / `engine.resume_run` / `engine.cancel_run` | Run lifecycle controls (Owner/Admin) |

### Block 06 — AI Layer

| Endpoint | Notes |
| --- | --- |
| `ai.override_cost_ceiling` | Per Block 06 Phase 08 — cost-ceiling override (Owner only) |
| Prompt registry edits (any) | Boot-time, not user-callable — listed for completeness |

### Block 07 — Bank Statement Pipeline

| Endpoint | Notes |
| --- | --- |
| `intake.upload_statement` | Statement upload (per `tool_upload_pipeline_api`) |
| Manual partial-upload acknowledgement | Per Stage 1 partial-upload policy |

### Block 09 — Document Intake

| Endpoint | Notes |
| --- | --- |
| `intake.upload_document` | Manual document upload (per `manual_upload_ui_spec`) |
| `intake.document_dismiss` | DISMISSED state transition |
| `intake.email_finder_run` / `intake.drive_finder_run` | Manual finder triggers (Owner/Admin) |

### Block 12 — OUT Workflow

| Endpoint | Notes |
| --- | --- |
| `out_workflow.user_approval` | HUMAN_REVIEW_HOLD approval (Owner/Admin/Bookkeeper) |
| `out_workflow.revoke_approval` | Approval revocation |
| `out_workflow.start_run_manually` | Manual OUT_MONTHLY trigger |
| `out_workflow.adjustment_intake` | OUT_ADJUSTMENT creation |
| `out_workflow.document_exception` | Mark-as-no-invoice-available (writes to `transactions.effective_match_status`) |

### Block 13 — IN Workflow

| Endpoint | Notes |
| --- | --- |
| `in_workflow.user_approval` | HUMAN_REVIEW_HOLD approval |
| `in_workflow.revoke_approval` | Approval revocation |
| `in_workflow.start_run_manually` | Manual IN_MONTHLY trigger |
| `in_workflow.adjustment_intake` | IN_ADJUSTMENT creation |
| Invoice CRUD (any) | `invoice.create`, `invoice.send`, `in_workflow.mark_invoice_paid`, `invoice.write_off`, `invoice.credit_note_issue`, `invoice.pro_forma_convert`, etc. |
| Client CRUD (any) | `client.create`, `client.update`, `client.deactivate` |
| Recurring template CRUD | `recurring.create`, `recurring.update`, `recurring.deactivate` |

### Block 14 — Review Queue

Per Block 14 Phase 09: every action in `resolution_action_enum` is mobile-rejected. The `REVIEW_QUEUE_RESOLVE`, `REVIEW_ASSIGN`, `REVIEW_REGENERATE` surfaces all gate on `client_form_factor ≠ MOBILE`.

| Endpoint | Notes |
| --- | --- |
| `review_queue.apply_resolution_action` | The 13 resolution actions |
| `review_queue.bulk_action` | Bulk-apply |
| `review_queue.snooze` / `review_queue.unsnooze` | Snooze management |
| `review_queue.regenerate_card` | Manual card-content regeneration |
| `review_queue.add_note` | Note attachment |

`REVIEW_QUEUE_VIEW` is allowed on mobile (read-only queue browsing is the intended mobile use case).

### Block 15 — Finalization

| Endpoint | Notes |
| --- | --- |
| `archive.finalize_period` | The finalization action (Owner/Admin + step-up) |
| `archive.adjustment_finalize` | Adjustment-finalization |

### Block 16 — Dashboard & Reporting

Dashboards themselves render on mobile (read-only). Writes / refresh-initiated-asynchronous-jobs / exports reject:

| Endpoint | Notes |
| --- | --- |
| `report.trigger_export` (any of the 13 exports) | Per Block 16 Phase 09 |
| `report.trigger_accountant_pack` | Per Block 16 Phase 11 |
| `report.force_regenerate` | Force-regenerate exports |
| Per-business settings edits (accountant-pack config, etc.) | `BUSINESS_SETTINGS_EDIT` surface |

### Allowed on mobile (NOT rejected)

| Endpoint | Why allowed |
| --- | --- |
| `dashboard.view` (any card) | Read intent |
| `report.list_exports` | Read intent |
| `report.download_export` (existing export by signed URL) | Read intent |
| `report.refresh_now` | **Treated as READ intent on mobile per Block 16 Phase 12 correction** — refresh-now triggers a dashboard re-fetch from existing materialized state, not a new build; not soft-prompted |
| `review_queue.view_issue` | Read intent |
| `review_queue.list_my_inbox` | Read intent |
| `audit_log.read` | Read intent |
| `archive.read_finalized_period` | Read intent |
| `auth.login` / `auth.logout` / `auth.refresh_session` | Session lifecycle is desktop-or-mobile |

## Lint enforcement

Every protected endpoint declares its mobile policy in a manifest:

```ts
@MobilePolicy("REJECT")   // or "ALLOW"
async function out_workflow_user_approval(...) { ... }
```

CI lints:
1. Every endpoint in the canonical inventory above has `@MobilePolicy("REJECT")`
2. Every endpoint NOT in the inventory has either `@MobilePolicy("ALLOW")` or `@MobilePolicy("REJECT")` (no implicit)
3. The middleware actually enforces what the manifest declares (runtime audit)

## Tablet handling

Per Stage 1 decision: mobile = read-only; **tablet is treated as mobile for MVP** (also read-only). Stage 2+ `tablet_form_factor_policy` (Block 14) reconsiders this — tablets as desktop-for-select-actions is a deferred decision.

The middleware reads `X-Client-Form-Factor` as one of `MOBILE | TABLET | DESKTOP`. Both `MOBILE` and `TABLET` route to the rejection path in MVP. A future amendment can split these.

## Cross-references

- `permission_matrix` — role grants are checked AFTER mobile policy; mobile-rejection short-circuits before role evaluation
- `audit_log_policies` — `MOBILE_WRITE_REJECTED` event
- `tablet_form_factor_policy` (Block 14) — Stage 2+ tablet deferral
- `localized_number_date_format_policy` — i18n of the rejection message
- Block 14 Phase 09 — mobile read-only UX (architecture)
- Block 16 Phase 12 — accessibility / i18n / mobile UI commitments
- Stage 1 decision — mobile is read-only
