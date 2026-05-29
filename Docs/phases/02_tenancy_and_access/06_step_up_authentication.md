# Block 02 — Phase 06: Step-Up Authentication

## References

- Block doc: `Docs/blocks/02_tenancy_and_access.md` (Authentication section)
- Block doc: `Docs/blocks/05_security_and_audit.md` (Access Control Runtime — step-up policy)
- Block doc: `Docs/blocks/15_finalization_and_secure_archive.md` (Approval Modality)
- Decisions log: `Docs/decisions_log.md` (finalization step-up uses the same TOTP/passkey factor as login)

## Phase Goal

Sensitive actions require a fresh MFA challenge before they can proceed, even when the user already has a valid session. Step-up is the mechanism that makes the step-up flag in `canPerform`'s decision actually do something. After this phase, finalization, user management, integration disconnect, finalized-archive export, and role escalation are all gated by a recent MFA proof.

## Dependencies

- Phase 03 (MFA factors enrolled)
- Phase 04 (`canPerform` returns `REQUIRE_STEP_UP` for the right surfaces)

## Deliverables

- **`mfa_recent_at` claim** on the principal context, updated whenever a step-up challenge succeeds.
- **Step-up validity window** — successful step-up grants a short trust window (default: 5 minutes, configurable via sub-doc) during which subsequent sensitive actions don't re-prompt.
- **Step-up challenge UI** — a modal or short-page interstitial that presents the user's enrolled factor (TOTP or passkey) and verifies it without disrupting the underlying action's state.
- **Step-up challenge endpoint** — server-side verification, mfa_recent_at update.
- **Surface configuration runtime** — Phase 06 **reads the `STEP_UP_REQUIRED` flag from Phase 04's permission matrix** rather than maintaining its own list. The runtime observes the flag at decision time and triggers the challenge for surfaces such as: finalization, user management, integration disconnect, finalized-archive export, role escalation, secrets/key rotation.
- **Audit events:** `STEP_UP_CHALLENGE_REQUESTED`, `STEP_UP_CHALLENGE_PASSED`, `STEP_UP_CHALLENGE_FAILED`.
- **Failure handling** — three failed step-ups in a row triggers the same lockout flow as login (Phase 02).

## Definition of Done

- A user clicking "Finalize period" is challenged with their enrolled MFA factor before the finalization phase starts.
- After a successful step-up, the user can perform additional sensitive actions for the validity window without re-prompting.
- After the window expires, the next sensitive action prompts again.
- A failed step-up keeps the user on the originating page; the action does not proceed.
- All step-up events appear in the audit log with the surface name.
- Lockout after repeated failures works.

## Sub-doc Hooks (Stage 4)

- **Step-up validity window sub-doc** — exact duration, per-surface override (some surfaces may want a tighter window).
- **Step-up surface registry sub-doc** — the canonical list, format, how new surfaces are added.
- **Step-up UI sub-doc** — modal vs interstitial, accessibility, factor switcher behaviour.
