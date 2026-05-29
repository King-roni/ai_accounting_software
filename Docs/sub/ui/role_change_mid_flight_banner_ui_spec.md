# role_change_mid_flight_banner_ui_spec

**Category:** UI specs · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 16 — Dashboard & Reporting · **Stage:** 4 sub-doc (Layer 2)

The UI surface that communicates a **role-change-while-runs-active** condition to affected users. Companion to `role_change_propagation_policy.md` (the dispatch policy this banner makes visible) and `principal_context_schema.md` §8-§9 (the snapshot mechanism the banner narrates).

The banner answers the user-facing question: *"Why did my action just go through under my old role?"* or *"Why was my action denied even though I just got promoted?"* It is the visible explanation of the otherwise-invisible snapshot mechanism.

---

## 1. When the banner appears

Two distinct trigger conditions, two distinct audiences:

### Trigger A — Affected user is the role-changed party

The current user's role on the current business has changed within the last 24 hours **AND** at least one active workflow run (status NOT IN `(FINALIZED, COMPENSATING, CANCELLED)`) exists where the snapshot role differs from the current live role.

Detected per request via a small query bound to dashboard load:

```sql
SELECT EXISTS (
  SELECT 1
  FROM workflow_runs wr
  WHERE wr.business_id = current_business_id()
    AND wr.status NOT IN ('FINALIZED', 'COMPENSATING', 'CANCELLED')
    AND wr.principal_context_snapshot_json->>'app_user_id' = current_user_id()::text
    AND wr.principal_context_snapshot_json->>'role' <> current_role()::text
);
```

### Trigger B — Owner / Admin observing a role mutation

An Owner / Admin viewing the team page or the workflow-runs index sees the banner when at least one **active run for any user** has a divergence between snapshot role and live role on the same business.

```sql
SELECT json_build_object(
  'affected_user_count',  COUNT(DISTINCT wr.principal_context_snapshot_json->>'app_user_id'),
  'active_run_count',     COUNT(*)
)
FROM workflow_runs wr
JOIN business_user_roles bur
  ON bur.user_id = (wr.principal_context_snapshot_json->>'app_user_id')::uuid
 AND bur.business_id = wr.business_id
WHERE wr.business_id = current_business_id()
  AND wr.status NOT IN ('FINALIZED', 'COMPENSATING', 'CANCELLED')
  AND wr.principal_context_snapshot_json->>'role' <> bur.role::text;
```

The 24-hour window does NOT apply to Trigger B — Owners always see divergence regardless of recency, because the run-completion may take days.

---

## 2. Copy

### Variant A — Affected user (Trigger A)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ⓘ  Your role on [Business Name] changed recently.                       │
│                                                                          │
│      You are now [New Role]. The 3 workflows you started before the      │
│      change continue under your previous role ([Previous Role]). New     │
│      workflows you start now will use your current role.                 │
│                                                                          │
│      [View affected workflows]                            [Dismiss]      │
└──────────────────────────────────────────────────────────────────────────┘
```

Variables substituted from the trigger query: business name from `business_entities.name`, new role from `current_role()`, previous role from the most-recent `TENANCY_ROLE_CHANGED` audit event for this user on this business, count of affected workflows.

**Special case — demotion that would block continuation:** if the new role is `READ_ONLY` and any affected run requires write authority for its remaining steps, the copy adds a sentence:

> "Some workflows may require a colleague with higher access to complete the remaining steps."

The "remaining steps" check is approximate (it compares the run's next-phase write requirements against the live role); false positives are acceptable here because the message is informational.

### Variant B — Owner / Admin (Trigger B, no specific affected user known)

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ⓘ  Role changes are in effect for [N] team members with active work.    │
│                                                                          │
│      Active workflows started before the change continue under the       │
│      members' previous roles. Members can finish in-flight work; new     │
│      actions outside of those workflows use the updated roles.           │
│                                                                          │
│      [View team activity]                                 [Dismiss]      │
└──────────────────────────────────────────────────────────────────────────┘
```

`[N]` is the `affected_user_count` from the Trigger B query.

### Variant C — Membership removal (special-case of Variant A)

If `business_user_roles` has no row for the current user on this business (the user was fully removed but still has an active session because session revocation is asynchronous OR they belong to another business in the same org), the banner copy differs:

```
┌──────────────────────────────────────────────────────────────────────────┐
│  ⚠  Your access to [Business Name] has been removed.                     │
│                                                                          │
│      The 2 workflows you started here are still running and will         │
│      complete; you will not be able to start new work for this           │
│      business.                                                           │
│                                                                          │
│      [View your remaining work]                                          │
└──────────────────────────────────────────────────────────────────────────┘
```

Note: no Dismiss button on Variant C. The state is sticky for the session's remaining lifetime. The banner disappears when (a) all affected runs reach a terminal state OR (b) the session ends.

---

## 3. Visual treatment

| Element | Token | Notes |
|---|---|---|
| Container | `--color-bg-info-subtle` (Variants A + B); `--color-bg-warning-subtle` (Variant C) | Subtle, non-alarming for the snapshot-divergence case; warning for the removal case. |
| Border | `--color-border-info` / `--color-border-warning` (1 px) | Matches the container variant. |
| Icon | Lucide `Info` (Variants A + B); Lucide `AlertTriangle` (Variant C) | 20 × 20 px, leading-aligned with body copy. |
| Icon colour | `--color-status-info` / `--color-status-warning` | — |
| Body text | `--color-text-primary` at 14 px / 20 px line-height | Reading-comfortable; multi-line. |
| Primary action | `Button` variant `text-action`, no fill | Subdued; this is informational, not a CTA. |
| Dismiss | Inline trailing button `text-muted`; affordance is text + icon (X) | Variants A + B only. Variant C has no dismiss. |
| Border-radius | `--radius-md` (8 px) | Matches dashboard card variants. |
| Shadow | None | Banner is in-flow, not floating. |
| Padding | 12 px vertical / 16 px horizontal | Consistent with Banner component. |

The banner sits in the **dashboard top region** above the main content area, below the global navigation. It does NOT float, does NOT push above modals, and does NOT block interactions.

For Variant C (removal), the banner additionally appears at the top of the workflow-runs index page even when the user navigates away from the dashboard — the state is too significant to live only on dashboard. For Variants A + B, the banner is dashboard-only.

---

## 4. Dismiss behaviour

Variants A + B support per-session dismissal:

- Click [Dismiss] → banner hidden for the remainder of the session (sessionStorage key `role_change_banner_dismissed:<business_id>:<session_id>`).
- New session → banner re-evaluates per §1 triggers and re-appears if conditions still hold.
- Role change to a NEW role mid-session → key invalidated; banner re-appears with updated copy.

Variant C has no dismiss; it is sticky.

**No persisted dismissal.** A user who dismisses on Tuesday and returns Wednesday sees the banner again if conditions still hold. This is deliberate — the alternative (persisted dismissal) creates a class of bug where users forget the snapshot is in effect and are confused when their next action runs under the old role.

---

## 5. "View affected workflows" deep link

Clicking the action button opens the workflow-runs index filtered to runs whose `principal_context_snapshot_json.role` differs from the user's live role. Filter chip is pre-applied; user can toggle it off.

The filter is implemented as a query parameter `?filter=role_diverged_for_me=1` so the link is shareable and bookmarkable.

For Variant B, the deep-link target is the **team activity page**, filtered to the users with divergence. The team-page UI is owned by `team_members_ui_spec.md`; a new filter chip "role changed with active work" is required there. **Cross-block coordination flagged for BOOK-205 team_members_ui_spec extension.**

---

## 6. Per-business scoping

Each business renders its own banner independently. A user with active runs on business-A (where their role changed) and active runs on business-B (where their role did not change) sees the banner only when viewing business-A's dashboard.

Switching businesses re-evaluates triggers. The dismissed-key in sessionStorage is keyed by `business_id`, so dismissing on business-A does not silence the banner on business-C.

---

## 7. Audit footprint

The banner is a presentation surface, not an action surface — it does not emit audit events on render. Clicks on [View affected workflows] do not emit events either (workflow-runs-index views are not separately audited).

The triggering condition's underlying event (`TENANCY_ROLE_CHANGED` / `TENANCY_MEMBER_REMOVED`) is audited at the role-mutation moment per `role_change_propagation_policy.md` §7. The banner is a read-only consumer of that audit trail.

---

## 8. Accessibility

- The banner uses `role="status"` for Variants A + B (non-urgent informational) and `role="alert"` for Variant C (membership removal — significant access change).
- Tab order: body text → primary action → dismiss button (where present).
- Dismiss action has `aria-label="Dismiss role change banner"`.
- Sufficient contrast: info-subtle background + primary text > 4.5:1 per WCAG AA; warning-subtle background + primary text > 4.5:1 verified per `design_system_tokens.md` accessibility table.
- Screen reader announces banner text on initial render; dismissal moves focus back to the prior focus target.

---

## 9. Mobile

The banner renders on mobile with reduced padding (8 px / 12 px) and the action button stacks below the body copy. Otherwise behaviour is identical.

Important: dismissal IS persisted to sessionStorage and synchronised across web + mobile sessions for the same `session_id` — a user who dismisses on desktop does not see the banner again on mobile within the same session. This is via the shared `user_sessions` table (no separate mobile storage).

---

## 10. Component bindings

| Component | Source |
|---|---|
| Banner container | `Banner` from `component_library_ui_spec.md` (info + warning variants) |
| Icon | `Icon` wrapper from `component_library_ui_spec.md` |
| Action button | `Button` variant `text-action` |
| Dismiss control | `Button` variant `text-muted` with trailing X icon |

---

## 11. Cross-references

- `role_change_propagation_policy.md` — the dispatch policy this banner makes user-visible (§1 trigger conditions consume the snapshot/live divergence the policy defines)
- `principal_context_schema.md` — snapshot column + helpers consumed by §1 queries
- `permission_matrix.md` — role enum (Owner / Admin / Bookkeeper / Accountant / Reviewer / Read-only)
- `audit_event_taxonomy.md` — `TENANCY_ROLE_CHANGED` / `TENANCY_MEMBER_REMOVED` produces the underlying state change (no banner audit emission)
- `team_members_ui_spec.md` — Variant B deep-link target; needs new filter chip (coordination flagged in §5)
- `workflow_run_schema.md` — `status` enum + non-terminal state list used in §1 queries
- `component_library_ui_spec.md` — Banner / Icon / Button components
- `design_system_tokens.md` — info-subtle, warning-subtle, status-info, status-warning tokens
- `mobile_write_rejection_endpoints.md` — banner is read-only so not affected; mobile rendering documented in §9
- Block 02 Phase 09 — role-change propagation (architecture)
- Block 16 — dashboard top region (consumer of banner placement)
- Stage 1 decision — role-change propagation; this banner is the user-facing companion
