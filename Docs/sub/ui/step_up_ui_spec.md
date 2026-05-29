# step_up_ui_spec

**Category:** UI specs · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 15 — Finalization & Secure Archive · **Stage:** 4 sub-doc (Layer 1 cross-block UI spec)

The challenge UX for step-up authentication. When a gated action (per `permission_matrix`'s step-up-required surfaces) needs fresh MFA, the UI surfaces an inline challenge per this spec. Used by FINALIZATION, optionally by BUSINESS_SETTINGS_EDIT / USER_INVITE / EXTERNAL_INTEGRATION per `step_up_validity_window_policy`.

Stripe / Linear / Mercury polish — token-driven via `design_system_tokens`. The challenge feels like a natural part of the workflow, not an interruption.

---

## Trigger

A user clicks a gated action (e.g., "Finalize Period"). Backend returns:

```json
{
  "error_code": "STEP_UP_REQUIRED",
  "step_up_surface": "FINALIZATION",
  "workflow_run_id": "<uuid>",
  "challenge_session_id": "<uuid>",                // pre-generated; valid for 5 minutes
  "available_factors": ["TOTP", "PASSKEY"],
  "user_default_factor": "TOTP"
}
```

The UI receives this and presents the step-up modal inline.

## Modal layout

```
┌─────────────────────────────────────────┐
│  Verify your identity                   │
│                                         │
│  Enter the 6-digit code from your       │
│  authenticator app                      │
│                                         │
│  [ ] [ ] [ ] [ ] [ ] [ ]                │
│                                         │
│  Use a passkey instead                  │
│                                         │
│  [Cancel]              [Verify]         │
└─────────────────────────────────────────┘
```

Modal width: 480px. Height: auto. Padding: `var(--space-6)` (24px). Border: `--color-border-subtle`. Background: `--color-bg-overlay`. Border-radius: `--radius-xl` (12px). Shadow: `--shadow-3`.

## Code input field

Six digit boxes per RFC 6238 — TOTP codes are exactly 6 digits. Per `component_library_ui_spec`:

- Each box: 56px × 64px
- Gap between boxes: `--space-2` (8px)
- Border: `--color-border-subtle` rest, `--color-border-focus` on active box
- Tabular-num font per `tabular_figures_column_width_ui_spec`
- Auto-advance to next box on digit entry
- Auto-submit when all 6 digits entered (no separate "Verify" click required for happy path)
- Paste handling: a 6-digit string pastes across all boxes
- Backspace empties current box and moves to previous

## Passkey path

If the user has a passkey enrolled (per `mfa_required_role_rechallenge_policy`), the "Use a passkey instead" link is visible. Clicking it:

1. Replaces the TOTP code-input UI with a passkey prompt
2. Invokes the WebAuthn `navigator.credentials.get()` API
3. The browser surfaces the platform's passkey UI (TouchID / FaceID / Windows Hello / security key)
4. On success: same as TOTP path — token issued, modal dismissed, gated action proceeds

If the user has no passkey enrolled: the link is hidden.

## States

| State | Visual |
| --- | --- |
| `default` | Empty input boxes; "Verify" button disabled until 6 digits entered |
| `submitting` | Spinner overlays the input area; "Verify" button shows spinner; modal not dismissable |
| `failed` | Error message above input: "Code didn't match. Try again."; input boxes cleared + focused on first |
| `succeeded` | Brief checkmark animation; modal dismisses; gated action proceeds |
| `expired` | Error: "Challenge expired. Please try again."; full reset |

## Accessibility

Per WCAG 2.1 AA:

- Focus management: opens with focus on first input box; Tab cycles input → input → ... → Cancel → Verify; Esc cancels
- Screen reader: modal announced as "Verify your identity dialog"; each input box labeled `aria-label="Digit X of 6"`
- Screen-reader announcement: "Enter the 6-digit code from your authenticator"
- High contrast: all elements ≥ 4.5:1 contrast against background
- Color-blind safe: focus state uses border-color + 3px focus ring; no color-only indicators

Per `component_library_ui_spec`: focus rings preserved with `box-shadow: 0 0 0 3px var(--color-border-focus)`.

## Mobile

Step-up challenges run on desktop only per `mobile_write_rejection_endpoints` — the workflows that require step-up are themselves desktop-only.

A mobile user encountering a step-up requirement (rare; would require a workflow misconfiguration) sees the mobile rejection error per the standard mobile-rejection contract.

## Failure UX detail

```
"Code didn't match. Try again."
```

(NOT: "Wrong code", "Invalid code", or anything implying the system knows whether the code was wrong vs the user is impersonating someone.)

After 3 consecutive failures within 60 seconds:

```
"Too many attempts. Try again in 60 seconds."
```

Per `auth_rate_limit_policy` (now part of Block 02 auth policies): rate-limit at the API layer; UI displays the count.

After the cooldown: the modal becomes interactive again.

## Token issuance feedback

On success: the modal flashes a checkmark for 600ms, then dismisses with a fade-out. The gated action proceeds.

The token is held by the client (in memory only, NEVER persisted) and included in the subsequent API call to the gated action.

## Per-surface adaptation

The headline copy varies by surface:

| Surface | Headline | Body |
| --- | --- | --- |
| `FINALIZATION` | Verify before finalizing | Finalizing a period creates an immutable archive. Verify your identity to confirm. |
| `BUSINESS_SETTINGS_EDIT` | Verify before changing settings | Changes to business settings affect future workflows. Verify your identity. |
| `USER_INVITE` | Verify before inviting | Inviting a user grants them access to this business. Verify your identity. |

The adaptation is per `step_up_surface_registry`.

## Component bindings

| Component | Source |
| --- | --- |
| Modal | `Modal` from `component_library_ui_spec` |
| Input | Six instances of a specialized `CodeDigit` component (single-char input) |
| Spinner | `Spinner` from `component_library_ui_spec` |
| Button | `Button` (Cancel = ghost; Verify = primary) |
| Link | `Link` styled per `design_system_tokens` brand color |

Storybook stories: TOTP default, passkey default, submitting, failed, expired, mobile-rejection (illustrative for documentation; never actually renders on mobile).

## Cross-references

- `step_up_validity_window_policy` — challenge lifecycle
- `step_up_auth_for_workflow_approval_policy` — when challenge fires
- `permission_matrix` — step-up surfaces
- `component_library_ui_spec` — base components
- `design_system_tokens` — color / spacing / typography
- `design_token_lint_policy` — enforcement
- `mobile_write_rejection_endpoints` — mobile rejection
- `auth_rate_limit_policy` (Block 02 auth policies) — rate-limit
- `totp_secret_storage_integration` — TOTP factor source
- `mfa_required_role_rechallenge_policy` — passkey enrollment
- Block 02 Phase 03 — MFA architecture
- Block 02 Phase 06 — step-up auth (architecture)
- Block 15 Phase 03 — FINALIZATION approval modality (consumer)
