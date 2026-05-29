# google_cloud_project_setup

**Category:** Reference data · **Owning block:** 02 — Tenancy & Access · **Co-owner:** 09 — Document Intake & Extraction · **Stage:** 4 sub-doc (Layer 2)

The Google Cloud Console-side configuration that backs the platform's Google OAuth integration. Companion to `gmail_oauth_integration.md` which covers the runtime flow; this doc covers the GCP-side artefacts (projects, OAuth clients, redirect URIs, scope strings, consent screen, EU verification posture) that the runtime flow assumes already exist.

Read this before B02·P08 implementation to know exactly what to provision in GCP Console.

---

## 1. GCP project topology

Three projects per environment-isolation rule (mirrors BOOK-173 passkey RP-ID isolation):

| Environment | GCP project ID | Region |
|---|---|---|
| Production | `cypbk-prod` | `europe-west1` (Belgium) |
| Staging | `cypbk-staging` | `europe-west1` |
| Dev | `cypbk-dev` | `europe-west1` |

**Each environment has its own OAuth client; tokens DO NOT cross env boundaries.** A user who connects Gmail to staging cannot use that token against production; the OAuth client IDs are distinct and Google's authorization scopes tokens to the issuing client.

Billing accounts: separate per environment for clean cost attribution. Per the Stage-1 EU-residency commitment, all three projects pin to EU regions; us-central / asia regions are explicitly disallowed.

---

## 2. OAuth 2.0 client IDs

One Web Application client per project. Created at: GCP Console → APIs & Services → Credentials → Create credentials → OAuth client ID → Web application.

| Environment | OAuth Client name | Authorized JavaScript origins | Authorized redirect URIs |
|---|---|---|---|
| Production | `cypbk-web-prod` | `https://cypbk.eu`, `https://app.cypbk.eu` | `https://app.cypbk.eu/oauth/google/callback` |
| Staging | `cypbk-web-staging` | `https://staging.cypbk.eu`, `https://app.staging.cypbk.eu` | `https://app.staging.cypbk.eu/oauth/google/callback` |
| Dev | `cypbk-web-dev` | `https://dev.cypbk.eu`, `http://localhost:3000` | `https://app.dev.cypbk.eu/oauth/google/callback`, `http://localhost:3000/oauth/google/callback` |

**HTTPS-only for non-dev**; localhost may use HTTP per Google's allowance for dev. Adding a new redirect URI takes effect within ~5 minutes of save in GCP Console.

---

## 3. Client ID + secret storage

| Artefact | Sensitivity | Storage location |
|---|---|---|
| Client ID (e.g., `123456789-abc...apps.googleusercontent.com`) | **Non-secret** (appears in the user-facing OAuth redirect URL) | App config / Supabase environment variable `GOOGLE_OAUTH_CLIENT_ID` |
| Client secret | **Secret** | Supabase Vault per `secrets_management_policy.md` at path `vault:env=prod:google_oauth_client_secret` (per-env paths for staging + dev) |

Access pattern: the OAuth-flow Edge Function reads the client secret via Vault at request entry only; never logs the secret; never returns it across HTTP boundaries. The secret is held in a stack-local variable for the token-exchange call duration only — same pattern as TOTP secret handling in BOOK-171.

---

## 4. APIs to enable per project

Exactly two Google APIs are enabled in each project:

| API | Service name | Purpose |
|---|---|---|
| Gmail API | `gmail.googleapis.com` | Read inbox + message bodies + attachments per BOOK-209-area `document_gmail_query_schema` |
| Google Drive API | `drive.googleapis.com` | Read Drive file metadata + content download |

No other Google APIs are enabled. The minimal-API surface reduces the blast radius of a credential leak: a leaked client secret cannot be misused to call APIs that aren't enabled on the project.

Stage-2+ may add Calendar / Sheets / Docs APIs if invoice extraction expands beyond email + Drive surfaces; each addition requires a `Docs/decisions_log.md` amendment + a new Google verification cycle (per §6).

---

## 5. Scope strings

Two scopes, both **read-only**. These are the canonical strings used both in OAuth authorization requests and as the values stored in `oauth_tokens.scopes_granted`:

| Scope string | Tier | Purpose |
|---|---|---|
| `https://www.googleapis.com/auth/gmail.readonly` | Restricted | Read Gmail inbox + message content + attachments |
| `https://www.googleapis.com/auth/drive.readonly` | Restricted | Read Drive file metadata + content |

Both scopes are categorised by Google as **restricted** scopes (the highest-sensitivity tier), which is the reason production verification (§6) is mandatory before launch.

**No write scopes ever requested.** This is a documented design constraint per `gmail_oauth_integration.md` §Scopes — both this doc and that doc commit to read-only. Adding a write scope (e.g., `drive.file` for upload-back to user's Drive) requires:

1. Major-review decisions-log amendment.
2. New Google verification cycle (because adding a restricted scope re-triggers review).
3. Re-prompt all connected users for the new scope via the `AUTH_OAUTH_PERMISSION_DOWNGRADED`-style re-authorization flow.

Incremental authorization is NOT used — both scopes are requested in a single authorization request per `gmail_oauth_integration.md`. Simpler UX (one consent screen) at the cost of finer-grained user choice.

---

## 6. OAuth consent screen — EU configuration

Configured at: GCP Console → APIs & Services → OAuth consent screen.

| Field | Value |
|---|---|
| **User Type** | **External** |
| App name | "Cyprus Bookkeeping" |
| App logo | 240×48 PNG (same asset as BOOK-204 §6 invitation email header) |
| User support email | `support@cypbk.eu` (operations channel; not the SOC channel) |
| App domain | `cypbk.eu` |
| Authorized domains | `cypbk.eu` ONLY (staging/dev domains live on the staging/dev projects, not on the production consent screen) |
| Developer contact information | `gdpr@cypbk.eu` (GDPR-team mailbox / EU-data-controller contact per GDPR Article 13) |
| Privacy policy URL | `https://cypbk.eu/privacy` |
| Terms of service URL | `https://cypbk.eu/terms` |

**User Type rationale**: External, not Internal. The platform's users are not in a Google Workspace org; they're external Google account holders consenting to share their Gmail/Drive with this platform. Internal would restrict to a single Workspace org.

The privacy policy + terms of service URLs MUST be live and reviewable by Google's verification team before submitting for verification.

---

## 7. EU verification status

Google subjects EU-data-handling apps using restricted scopes to additional review. The verification process is a hard prerequisite for production launch.

### 7.1 What's required

- **Submit for verification**: via the OAuth consent screen's "Submit for verification" button after all §6 fields are populated.
- **Restricted scope justification document**: written prose explaining how the platform uses Gmail + Drive data, retention period (≤6 years per Block 04), GDPR compliance posture, encryption at rest (per `encryption_at_rest_policy.md`), incident response posture. Submitted as part of the verification packet.
- **Demo video**: 3–5 minutes showing (a) where in the app the OAuth scopes are exercised, (b) how the user views connected integrations, (c) how the user disconnects + revokes. Required per Google's policy for restricted scopes.
- **Domain ownership**: verified via DNS TXT record per Google's standard procedure. Same TXT record can satisfy both Google verification and the DKIM/SPF/DMARC requirements per `email_delivery_integration.md`.
- **Security assessment**: Google may request a CASA (Cloud Application Security Assessment) review for restricted scopes — usually waived for sub-10k-user apps but explicitly possible. Have `encryption_at_rest_policy.md` + the Block 05 audit-chain docs ready as evidence.

### 7.2 Timeline

Verification takes **4–6 weeks** for apps requesting restricted scopes like `gmail.readonly`. This is a hard dependency on production launch and should be initiated as early as the consent screen is configurable (well before the OAuth flow is implementation-ready).

### 7.3 Pre-verification state (Testing mode)

During the verification waiting period, the production app is in "Testing" status. Only **Test users** added via the consent screen can authenticate. Add the founding team's Google emails as test users. The test-user list is purged once verification completes; production accepts any external Google user post-verification.

---

## 8. Refresh-token behaviour by verification state

| App status | Refresh-token TTL | Implication |
|---|---|---|
| **Testing** (pre-verification) | **7 days** | Refresh tokens expire weekly — breaks the platform's long-refresh-token model |
| **In production** (post-verification) | Indefinite (until revoked) | The platform's 1-hour-access-token + long-lived-refresh-token model documented in `gmail_oauth_integration.md` §Refresh Strategy works as designed |

**This is the binding reason to complete verification before production launch.** Testing-mode refresh-token expiry would force users to re-authenticate weekly — incompatible with the platform's intake-pipeline design (which expects refresh tokens to survive months of dormancy between active intake runs).

---

## 9. GCP changes — decisions-log audit trail

GCP Console changes are NOT in the platform's audit chain (they're audited by Google's own infrastructure). The platform's compensating practice:

Every material GCP Console change is recorded in `Docs/decisions_log.md` with:

- Operator name (the human who made the change).
- Change description.
- Before/after screenshots if material (redirect-URI changes, scope additions, consent-screen field changes).
- Timestamp.

Stage-2+ may add Google Cloud Audit Logs ingestion for automated traceability via the `cloudaudit.googleapis.com/data_access` log sink. Until then, the decisions-log + Google's own console history are the compensating record.

---

## 10. Operational runbook pointers

| Operation | Procedure |
|---|---|
| Rotate client secret | Quarterly per `secrets_management_policy.md`. GCP Console → Credentials → edit client → "Reset secret" → update Vault → emit `OAUTH_CLIENT_SECRET_ROTATED` (MEDIUM) audit event. In-flight refresh-token exchanges may fail; reactive refresh retries per `gmail_oauth_integration.md` §Refresh Strategy. |
| Add a new redirect URI | GCP Console → Credentials → edit client → add URI under Authorized redirect URIs → save → wait ~5 min for propagation → smoke-test from the new URI. |
| Recover from leaked client secret | Rotate immediately via GCP Console; update Vault; emit `OAUTH_CLIENT_SECRET_ROTATED` with `rotation_reason: 'SUSPECTED_LEAK'`; document in decisions-log; consider revoking all existing `oauth_tokens` if leak window is significant. |
| Remove the OAuth integration entirely | Stage-2+ business decision. Procedure: revoke all `oauth_tokens` per `gmail_oauth_integration.md` §Token Revocation → disable Gmail + Drive APIs in GCP → delete the OAuth client → archive the decisions-log entry. Irreversible without re-creating the GCP project from scratch + re-undergoing verification. |
| Re-verify after scope change | Trigger Google's verification flow again from the consent screen; expect another 4-6-week wait; existing tokens remain valid in the interim (Google's grandfathering rule). |
| Add a test user during pre-verification | GCP Console → OAuth consent screen → Test users → Add user → enter Google account email → save. Takes effect immediately. |

---

## 11. GDPR / data-subject-rights interaction

Per `gdpr_data_subject_rights_policy.md`:

When a user submits a data-erasure request:

1. All `oauth_tokens` rows for the user × business pair are deleted (per `gmail_oauth_integration.md` §Token Revocation deletion path).
2. All cached email / Drive content pulled by the platform is deleted per the document-content retention rule.
3. The platform calls Google's revoke endpoint (`https://oauth2.googleapis.com/revoke`) for the user's refresh token — best-effort fire-and-forget; Google's response is not awaited.
4. The platform's decisions-log entry on the erasure references the deleted token IDs for audit traceability.

Google retains its own copy of the user's consent history per Google's privacy policy — that is Google's record, not the platform's. The platform's GDPR posture covers only data the platform held.

---

## 12. Cost model

Gmail + Drive APIs have generous free tiers:

| API | Free-tier quota |
|---|---|
| Gmail API | 1 billion units/day per project; typical operation costs 1-10 units |
| Google Drive API | 20,000 queries per 100 seconds per project; 1 billion queries per day |

The platform's expected usage is well under both tiers for any reasonable MVP scale (≤ 10,000 businesses, each with ≤ 100 intake runs per month). No billing-alert thresholds needed at MVP. Stage-2+ may add per-business quota allocation if a single tenant's intake activity threatens to consume a disproportionate share.

GCP billing alerts (separate from app-side quotas): set a budget alert at $100/month per project with notification to `gdpr@cypbk.eu` (the same address listed on the consent screen). Mostly a defense against runaway integration bugs.

---

## 13. Cross-references

- `gmail_oauth_integration.md` — runtime OAuth flow that consumes this setup; the §2 "Step-by-step" runs against the OAuth client + redirect URI defined here
- `oauth_state_schema.md` — `oauth_states` table used during the auth-code-flow callback
- `oauth_token_encryption_schema.md` — `oauth_tokens` AES-256-GCM encryption
- `oauth_policy.md` — higher-level OAuth governance
- `secrets_management_policy.md` — Vault path conventions for client secret storage
- `encryption_at_rest_policy.md` — AES-256-GCM baseline cited in §7.1 verification packet
- `gdpr_data_subject_rights_policy.md` — DSAR interaction (§11)
- `audit_event_taxonomy.md` — `OAUTH_CLIENT_SECRET_ROTATED` (this doc's introduction; needs adding to taxonomy) + the broader `AUTH_OAUTH_*` event family already in BOOK-208's runtime flow
- `mobile_write_rejection_endpoints.md` — OAuth flow is desktop-only
- `passkey_relying_party_integration.md` (BOOK-173) — same env-isolation rule pattern (passkey RP ID + GCP project both isolate per env)
- `invitation_email_template.md` (BOOK-204) — shared brand assets (logo, app name) used on the OAuth consent screen
- `email_delivery_integration.md` — DKIM/SPF/DMARC DNS records that share the cypbk.eu domain-verification chain
- `Docs/decisions_log.md` — GCP-change audit trail per §9
- Block 02 Phase 08 — owning phase (OAuth integration foundation)
- Block 09 Phase 05 — Email finder (Gmail consumer)
- Block 09 Phase 06 — Drive finder (Drive consumer)
- Stage 1 decision — EU-only hosting + read-only Google scope policy
