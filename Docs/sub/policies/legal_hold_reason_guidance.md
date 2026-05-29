# Legal Hold Reason Guidance

**Category:** Policies · **Owning block:** 04 — Data Architecture · **Co-owner:** 05 — Security & Audit · **Stage:** 4 sub-doc (Layer 2)

Content rules + canonical examples for `legal_holds.hold_kind`, `legal_holds.hold_authority`, and `legal_holds.lift_reason` text. Per the Phase 11 phase doc: "example reasons, retention notes, redaction considerations for any sensitive content in the reason text."

The hold-reason text is BOTH operationally visible (Owner sees in UI) AND audit-visible (permanently retained per `data_retention_policy.md` audit-log permanent retention). PII or sensitive third-party content in these fields lives forever; this policy pins what should and should not appear.

---

## 1. The three text fields

| Field | When set | Visibility | Editable post-set |
|---|---|---|---|
| `hold_kind` | At filing | All roles on the business (UI badge), audit log permanently | No |
| `hold_authority` | At filing | Owner + Admin (UI history), audit log permanently | No |
| `lift_reason` | At lift | Owner + Admin (UI history), audit log permanently | No |

None of these fields are editable after the lifecycle event that sets them per `legal_hold_lifecycle_policy.md` §3-4. This immutability is intentional — a hold's reason at filing is the binding rationale and cannot be retroactively edited.

---

## 2. `hold_kind` — fixed enum

A controlled vocabulary of 5 values:

| `hold_kind` | When to use |
|---|---|
| `TAX_INVESTIGATION` | A tax authority has opened an investigation; records must be preserved beyond standard retention |
| `COURT_ORDER` | A court has issued an order preserving records (litigation hold) |
| `GDPR_ENQUIRY` | A data-subject or supervisory-authority enquiry under GDPR Articles 15-22 is pending |
| `REGULATOR_REQUEST` | A regulator other than the tax authority has requested records (e.g., AML, financial conduct) |
| `OTHER` | Catch-all for novel scenarios; the UI requires a free-text clarification appended to `hold_authority` |

Enforced via CHECK constraint (NOT a Postgres `ENUM` type):

```sql
ALTER TABLE legal_holds
  ADD CONSTRAINT legal_hold_kind_allowed
  CHECK (hold_kind IN (
    'TAX_INVESTIGATION', 'COURT_ORDER', 'GDPR_ENQUIRY', 'REGULATOR_REQUEST', 'OTHER'
  ));
```

Adding a new value is an additive migration. The constraint is preferred over a Postgres ENUM because (a) ALTER TYPE ADD VALUE has deferred visibility per the data-conventions policy, and (b) CHECK gives clearer error messages on rejection.

---

## 3. `hold_authority` — examples

Free text. Required, non-empty, ≤ 200 characters. Identifies the issuing authority + case reference.

| Good | Bad |
|---|---|
| `"Tax Department of Cyprus / Case #2026-AC-1923"` | `"Tax"` (insufficient detail) |
| `"District Court of Nicosia / Civil 4321/2026"` | `"a court ordered it"` (no case ref) |
| `"Office of the Commissioner for Personal Data Protection / Ref. CY-DPA-2026-088"` | `"GDPR thing"` |
| `"Cyprus Securities and Exchange Commission / Investigation #CySEC-2026-114"` | `"because the regulator said so"` |

Rule: anyone reading this field 6 years later should be able to identify the issuing body + case number without external context.

---

## 4. `lift_reason` — examples

Required at lift, ≤ 2000 characters.

> "Tax investigation concluded on 2026-04-22 with no findings; ref Tax Dept letter dated 2026-04-15. No further records preservation required."

> "Court case dismissed by District Court of Nicosia, judgment ref 4321/2026 issued 2026-05-10. Retention window restored to standard policy."

> "GDPR enquiry closed by OCPDP letter ref CY-DPA-2026-088-CLOSED dated 2026-06-01. Records were not subject to an erasure request."

Rule: capture the closing event's date + reference + outcome in one sentence; expand only as needed.

---

## 5. Content rules — what NOT to write

Apply to `hold_authority` and `lift_reason` (the `hold_kind` enum is auto-controlled). Content discipline:

1. **No personal data of third parties** — names of opposing counsel, witnesses, individual investigators, accused individuals. Reference the case/file number, not the person.
2. **No data-subject content** — if a GDPR data-subject is the holder of a right being investigated, do not include their identifying information in the hold reason. The case file at the regulator already contains it.
3. **No speculation or commentary** — facts only. "Court case dismissed" not "court correctly dismissed our argument."
4. **No internal-confidential information** — strategy notes, settlement amounts, attorney-client material. Keep these in privileged internal records, not audit-visible fields.
5. **No credentials or secrets** — no passwords, API keys, account numbers, or individuals' tax IDs.

A `legal_hold_reason_lint` function (cross-block coordination flagged for B05·P09 GDPR redaction) is proposed but NOT in MVP — content discipline is enforced by training + UI helper text + post-hoc audit review.

---

## 6. Redaction at write

Unlike `adjustment_reason_text` (which is exempt from PII redaction per Stage-6 `audit_pii_redaction_policy`), legal-hold reason text **IS** subject to standard PII redaction at the audit-payload write boundary per `redaction_at_write_policy.md`:

- Email addresses → `[EMAIL]`
- Phone numbers → `[PHONE]`
- IBAN / credit-card-like sequences → `[FINANCIAL_NUMBER]`
- Cyprus VAT IDs (`CY` + 9 digits) of natural persons → `[VAT_ID]` (organizational VAT IDs are preserved; the redactor cannot distinguish — Stage-6 reconcile)

If a hold-reason field unavoidably must include a redactable token (rare; usually for cross-reference), the operator should reconsider whether the reference is necessary. The redactor errs on the side of over-redaction for permanently-retained audit content.

---

## 7. Multi-language

`hold_authority` and `lift_reason` are stored in their original language. The Cyprus legal system operates in English and Greek primarily. The UI does NOT translate these fields — they are displayed verbatim. The audit log preserves the original text.

For non-EN/EL hold authorities (rare; foreign court orders), the original-language text is preserved. An optional `hold_authority_en` translation column is proposed for Stage-2 (cross-block coordination flagged).

---

## 8. Audit visibility

The hold-reason fields appear in:

- `LEGAL_HOLD_SET` audit event payload — `hold_kind`, `hold_authority`
- `LEGAL_HOLD_LIFTED` audit event payload — `lift_reason`
- The UI legal-hold panel history
- Accountant pack exports (cross-block coordination flagged for B15·P06 — accountant_pack manifest must include active legal holds)

All audit-visible payloads inherit the permanent-retention rule of `data_retention_policy.md` audit-log section. Hold reasons are never deleted under any circumstance.

---

## 9. Cross-references

- `legal_hold_lifecycle_policy.md` — schema definition + CHECK constraint
- `legal_hold_ui_spec.md` — form fields + UI rendering
- `redaction_at_write_policy.md` — PII-redaction patterns applied to audit payloads (this cycle's B04·P06 work)
- `audit_pii_redaction_policy` (Stage-6 doc-write candidate) — central PII catalog
- `audit_log_policies.md` — `LEGAL_HOLD_*` event severity + visibility
- `adjustment_reason_text_policy.md` — sibling content policy (different exemption rules)
- `data_retention_policy.md` — audit log permanent retention
- Block 04 Phase 11 — owning phase
- Block 05 Phase 09 — GDPR redaction interaction
- Block 15 Phase 06 — accountant_pack manifest legal-hold inclusion (cross-block coordination flagged)
