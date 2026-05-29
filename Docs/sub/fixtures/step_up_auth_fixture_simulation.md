# step_up_auth_fixture_simulation

**Category:** Fixtures · **Owning block:** 15 — Finalization & Secure Archive · **Co-owner:** 02 — Tenancy & Access · **Stage:** 4 sub-doc (Layer 1 cross-block fixture spec)

The simulation mechanism for fresh-MFA step-up authentication in test fixtures. Per `step_up_validity_window_policy`: production gated actions require a real TOTP code or passkey. Tests can't (and shouldn't) generate real TOTP codes from real Vault-backed secrets — the simulation provides test-only step-up tokens that the harness recognizes.

Critical: the simulation MUST be unreachable in production. The mechanism is gated by an explicit test-mode flag.

---

## Test-mode flag

```sql
SET app.test_step_up_simulation_active = 'true';
```

The flag is set by the test harness at the start of any fixture that needs step-up. Production code paths never set this flag. A check at the step-up verification layer:

```ts
function verifyStepUpToken(token, surface, business_id): boolean {
  // Real verification
  const realResult = verifyRealStepUpToken(token, surface, business_id);
  if (realResult.valid) return true;

  // Test simulation
  if (process.env.NODE_ENV === 'test'
      && (await query("SELECT current_setting('app.test_step_up_simulation_active', true)")) === 'true') {
    return verifySimulatedStepUpToken(token, surface, business_id);
  }

  return false;
}
```

The `NODE_ENV === 'test'` check is a defense in depth — even if the session variable leaked, production never has `NODE_ENV === 'test'`.

## Simulated token shape

```
sim_<business_id>_<user_id>_<surface>_<random>
```

Example:
```
sim_a1b2c3...d_e4f5g6...h_FINALIZATION_x7y8z9
```

The token is regex-matched at the verifier:

```regex
^sim_[a-f0-9-]+_[a-f0-9-]+_(FINALIZATION|BUSINESS_SETTINGS_EDIT|USER_INVITE|EXTERNAL_INTEGRATION)_[a-z0-9]+$
```

Per `step_up_validity_window_policy`: only step-up-requiring surfaces are accepted. A simulated token for a non-gated surface fails verification.

## Issuance in fixtures

```ts
import { simulateStepUp } from "@/test-harness";

const stepUpToken = await simulateStepUp({
  user_id: "...",
  business_id: "...",
  surface: "FINALIZATION",
});

// Use in fixture
await callFinalizationApprove({
  workflow_run_id,
  step_up_token: stepUpToken,
});
```

The harness:

1. Generates a unique simulated token matching the regex
2. Inserts a `step_up_tokens` row with `simulated = true` flag + standard fields
3. Returns the token string

The `simulated = true` column on `step_up_tokens` lets production-monitoring detect any leaked test row. Per `step_up_validity_window_policy`: production `step_up_tokens` always have `simulated = false`.

## Audit recording in fixtures

```ts
emitAudit("STEP_UP_PASSED", {
  user_id,
  business_id,
  surface,
  factor_kind: "SIMULATED",                       // present only in test mode
  simulated: true,                                 // present only in test mode
});
```

The `factor_kind = "SIMULATED"` audit value is reserved for test-mode use. Per `audit_event_taxonomy`: this value never appears in production audit logs. Repo-wide lint per `audit_event_taxonomy` enforces.

## Per-surface simulation

Each step-up surface has its own simulation:

| Surface | Simulated `factor_kind` |
| --- | --- |
| `FINALIZATION` | SIMULATED (TOTP-shape) |
| `BUSINESS_SETTINGS_EDIT` | SIMULATED |
| `USER_INVITE` | SIMULATED |
| `EXTERNAL_INTEGRATION` | SIMULATED |

The fixture's `setup` block typically pre-issues the necessary simulated tokens; the fixture's `input` references them.

## Production-safety verification

The test suite includes a meta-fixture per Block 15 Phase 10:

```ts
{
  name: "production_safety_no_simulation_tokens",
  description: "Verifies that simulated step-up cannot be used in production",
  setup: {
    business: { ... },
    // Note: no app.test_step_up_simulation_active set
  },
  test: async () => {
    const sim_token = "sim_abc_def_FINALIZATION_xyz";
    const result = await verifyStepUpToken(sim_token, "FINALIZATION", "<business>");
    expect(result.valid).toBe(false);
    expect(getEmittedAudit()).toContain({
      event_type: "STEP_UP_SIMULATION_REJECTED_IN_PRODUCTION_MODE",
    });
  },
}
```

This fixture itself runs in test mode (NODE_ENV=test) but does NOT set `app.test_step_up_simulation_active`. The fixture verifies the rejection path; failure of this fixture indicates a production-safety regression.

## Time-aware simulation

Per `step_up_validity_window_policy`: step-up tokens expire after 5 minutes (default). Fixtures that need to test expiry:

```ts
const stepUpToken = await simulateStepUp({ ..., expires_at: mockTime.add({ minutes: 4 }) });

await mockTime.advance({ minutes: 6 });

// Subsequent action should reject the now-expired token
```

Mock time per `fixture_format_spec`: each fixture can advance the test clock independently.

## Multi-business safety in fixtures

A simulated token issued for business A cannot authorize an action on business B. The simulation respects the production binding rule.

If a fixture has `user_id` with roles on multiple businesses, simulating step-up for one business binds the token to that business only. The fixture must simulate separately for each business action.

## Removal of simulation rows

Per `step_up_tokens` retention: simulated rows are retention-deleted alongside real rows. A leaked test row that escaped to production (unlikely but possible via fixture leakage) would be flagged by the `simulated = true` column and cleaned by ops.

The retention engine emits `STEP_UP_SIMULATION_ROW_PURGED` per `audit_event_taxonomy` when purging simulated rows in production — this should fire zero times in normal operation.

## Lint enforcement

CI lints production source code for the presence of `simulateStepUp` import — any production module importing the test harness's simulation function fails the build.

```bash
pnpm lint:no-test-simulation-in-production
```

The lint runs alongside `pnpm lint:gateway-bypass` per `gateway_bypass_detection_policy` shape.

## Cross-references

- `step_up_validity_window_policy` — base step-up policy
- `step_up_auth_for_workflow_approval_policy` — when step-up fires
- `step_up_ui_spec` — the production UI
- `totp_secret_storage_integration` — production TOTP source
- `gateway_bypass_detection_policy` — sibling test-mode pattern
- `audit_log_policies` — `STEP_UP_*` events + `SIMULATED` factor_kind
- `audit_event_taxonomy` — STEP_UP_SIMULATION_* events
- `fixture_format_spec` — base fixture shape
- `out_workflow_per_fixture_content` — Block 12 fixture usage
- Block 02 Phase 06 — step-up auth architecture
- Block 15 Phase 03 — approval modality & step-up
- Block 15 Phase 10 — end-to-end finalization tests (production-safety meta-fixture host)
