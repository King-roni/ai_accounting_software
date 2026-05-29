# VIES Quarterly Submission Failure — Runbook
**Category:** Runbooks · Block 11 — Ledger & Cyprus VAT
**Last updated:** 2026-05-16

---

## 1. Overview

This runbook covers diagnosis and recovery when a VIES quarterly submission fails or is incomplete. VIES (VAT Information Exchange System) submissions are required quarterly under Cyprus VAT law for intra-EU B2B supplies. Failures range from transient API outages to data quality issues affecting individual counterparty records.

Run this runbook whenever:
- A VIES submission job returns a non-success status.
- The audit log contains `VIES_SUBMISSION_FAILED` or `VIES_VALIDATION_SYSTEM_ERROR`.
- A submission deadline is approaching and the prior submission has no confirmed reference number.

---

## 2. Failure Scenarios

| # | Scenario | Primary indicator |
|---|---|---|
| 1 | VIES API unavailable | HTTP 5xx or SOAP fault `INVALID_REQUESTER_INFO` |
| 2 | Counterparty VAT number invalid | VIES returns INVALID for a previously-VALID number |
| 3 | Submission reference not returned | API timeout after POST; no reference in response |
| 4 | Partial submission | Some records accepted, some rejected in the same submission |
| 5 | Submission accepted but confirmation email not received | No email despite successful API response |

---

## 3. Scenario 1 — VIES API Unavailable

**Symptoms:** The submission job emits `VIES_VALIDATION_SYSTEM_ERROR`. HTTP response code is 5xx or the SOAP response contains `INVALID_REQUESTER_INFO`.

**Steps:**

1. Check `vies_record_schema.md`: confirm the `error_code` field on the affected VIES records. Expected value: `SYSTEM_UNAVAILABLE` or `SOAP_FAULT`.
2. Confirm the audit event `VIES_VALIDATION_SYSTEM_ERROR` was emitted for the current submission run. Query the audit log by `run_id`.
3. Check the VIES status page (EU Commission) for known maintenance windows. VIES is taken offline for maintenance periodically, typically outside EU business hours.
4. Wait 1 hour and retry the submission job.
5. If unavailable for more than 24 consecutive hours:
   - Document the start and end of the outage in `decisions_log.md`.
   - Export the submission payload as a manual XML file per `vies_xml_schema.md`.
   - Submit the XML directly to the Cyprus Tax Department (TAXISnet portal or email submission, per current TAXISnet guidance).
   - Record the manual submission reference in `vies_submission_tracking_schema.md` with `submission_method = MANUAL`.
6. Audit event to emit after manual submission: `VIES_SUBMISSION_MANUAL_FALLBACK`.

---

## 4. Scenario 2 — Counterparty VAT Number Invalid

**Symptoms:** VIES returns `INVALID` for one or more counterparty VAT numbers that previously returned `VALID`. The submission is rejected for those records.

**Steps:**

1. Identify the affected `counterparty_id` values from the submission rejection response. These are logged in `vies_record_schema.md` under `validation_result = INVALID`.
2. Check `vat_validation_cache_schema.md` for the counterparty. If a `VALID` cache entry exists from a previous check, the customer's VAT registration may have lapsed or been deregistered.
3. Contact the client to confirm their VAT registration status. Request a current VIES confirmation from their side if needed.
4. Assess the supply:
   - If the VAT number is genuinely invalid/lapsed: the supply may need reclassification from intra-EU zero-rated to domestic standard-rated. Consult Cyprus VAT Circular guidance on deregistered counterparties.
   - If the VAT number is valid but VIES is returning a false INVALID (known intermittent VIES issue): re-run `vies.validate` against the EU VIES API directly to confirm. If confirmed valid by direct check, document this in `decisions_log.md` and proceed with submission.
5. Update the counterparty record with the corrected VAT number or a note on the invalid status.
6. Invalidate the affected cache entry in `vat_validation_cache_schema.md`.
7. Re-run the VIES eligibility check for the affected transactions via `vies_quarterly_eligibility_policy.md`.
8. Resubmit the affected records.
9. Audit event: `VIES_COUNTERPARTY_VAT_INVALIDATED`.

---

## 5. Scenario 3 — Submission Reference Not Returned (Timeout)

**Symptoms:** The submission POST succeeded (no 5xx), but the API response timed out before returning a `submission_reference`. The `submission_reference` field in `vies_submission_tracking_schema.md` is null.

**Steps:**

1. Check `vies_submission_tracking_schema.md` for the submission record. Confirm `submission_reference IS NULL` and `submitted_at` is set (indicating the POST was sent).
2. Do not resubmit automatically. Duplicate submissions to VIES can result in duplicate entries, which require a correction submission to reverse.
3. Log into the Cyprus Tax Department's TAXISnet portal directly. Search for submissions by:
   - `submitted_at` date
   - Business VAT number
4. If the submission exists in the portal:
   - Manually record the reference number in `vies_submission_tracking_schema.md` with `reference_source = MANUAL_PORTAL_LOOKUP`.
   - Emit audit event: `VIES_SUBMISSION_REFERENCE_MANUALLY_RECONCILED`.
5. If the submission does not exist in the portal after 2 hours:
   - The POST was likely dropped before reaching VIES. Resubmit.
   - Emit audit event: `VIES_SUBMISSION_RESUBMITTED` with `resubmit_reason = REFERENCE_NOT_RETURNED`.

---

## 6. Scenario 4 — Partial Submission

**Symptoms:** The VIES API response contains a mix of accepted and rejected records within a single submission batch.

**Steps:**

1. Parse the VIES response to separate accepted `submission_line_id` values from rejected ones.
2. Mark accepted records in `vies_submission_tracking_schema.md` with `line_status = ACCEPTED`.
3. For rejected records: extract the rejection reason code per VIES response schema.
4. Apply per-record fixes based on rejection reason:
   - Invalid VAT number: follow Scenario 2 above.
   - Amount format error: correct the amount field format in the payload.
   - Missing mandatory field: identify and populate the missing field.
5. Resubmit only the rejected rows as an amendment submission. Do not resubmit accepted rows.
6. Mark the amendment submission in `vies_submission_tracking_schema.md` with `submission_type = AMENDMENT` and reference the original `submission_id`.
7. Audit event: `VIES_SUBMISSION_PARTIAL_RESUBMITTED`.

---

## 7. Scenario 5 — No Confirmation Email

**Symptoms:** The VIES submission API returned a success response and a `submission_reference`, but the confirmation email from the Cyprus Tax Department was not received.

**Steps:**

1. Confirm the `submission_reference` is recorded in `vies_submission_tracking_schema.md`.
2. A missing confirmation email is not an indicator of submission failure. Confirmation emails from TAXISnet are sometimes delayed by 24–48 hours.
3. Verify the submission status directly via the TAXISnet portal using the `submission_reference`.
4. If the submission is confirmed in the portal, no further action is required. Note the missing email in `decisions_log.md` for the record.
5. If the submission is not found in the portal despite having a reference, escalate (see Section 8).

---

## 8. Escalation

If none of the above scenarios resolve the issue within 5 business days of the submission deadline:

1. Prepare a written log of the failure timeline, error codes, and all recovery steps attempted.
2. Contact the Cyprus Tax Department VIES helpdesk. Contact details are maintained in internal runbook supplemental docs.
3. If the deadline has passed and the submission is still unresolved, consult the business's tax advisor regarding any penalty mitigation available under Force Majeure or system unavailability provisions.

---

## Cross-references

- `vies_record_schema.md` — error_code field, validation_result values
- `vies_submission_tracking_schema.md` — submission_reference, submission_method, line_status
- `vies_xml_schema.md` — manual XML format for fallback submissions
- `vat_validation_cache_schema.md` — cache entry structure, cache invalidation
- `vies_quarterly_eligibility_policy.md` — which transactions qualify for VIES reporting
- `audit_event_taxonomy.md` — VIES_SUBMISSION_FAILED, VIES_VALIDATION_SYSTEM_ERROR event definitions
- `decisions_log.md` — manual submission notes and outage documentation
