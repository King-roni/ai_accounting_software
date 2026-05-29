# Cyprus Compliance Calendar Reference

**Block:** out_workflow
**Layer:** 2 — Sub-Doc
**Status:** Draft

## Overview

This reference document defines the recurring compliance filing obligations for
businesses registered in Cyprus that use this platform. It covers VAT filings, VIES
submissions, income tax, statutory audit requirements, and social insurance contributions.
It also defines the penalty schedule for late filings and payments, the Cyprus bank
holiday calendar, and the rule for deadline rollovers when a deadline falls on a
non-business day.

This document maps directly to the `vat_filing_deadline` field in `period_schema.md`
and provides the basis for automated deadline reminders triggered by the platform.

---

## VAT Filing Deadlines — Quarterly

Cyprus VAT-registered businesses on the standard quarterly scheme must file a VAT return
(TD2 form) and remit any VAT due by the following deadlines. The VAT period ends on the
last day of the quarter.

| Quarter | Period                  | Filing and Payment Deadline |
|---------|-------------------------|-----------------------------|
| Q1      | 1 January – 31 March    | 10 April                    |
| Q2      | 1 April – 30 June       | 10 July                     |
| Q3      | 1 July – 30 September   | 10 October                  |
| Q4      | 1 October – 31 December | 10 January (following year) |

Filing is done electronically via the Cyprus Tax Department's TaxisNet portal
(https://taxisnet.mof.gov.cy). Paper filing is no longer accepted.

**Note:** if the 10th of the month falls on a Saturday, Sunday, or Cyprus public holiday,
the deadline rolls to the next business day. See the Bank Holiday and Deadline Rollover
sections below.

The platform sets `period.vat_filing_deadline` automatically when a period is created,
using these rules. The value stored is the effective deadline after holiday rollover.

---

## VAT Filing Deadlines — Monthly

Businesses required to file monthly (annual intra-EU supplies exceeding €50,000) follow
the same pattern but for each calendar month:

| Period | Deadline          |
|--------|-------------------|
| Jan    | 10 February       |
| Feb    | 10 March          |
| Mar    | 10 April          |
| Apr    | 10 May            |
| May    | 10 June           |
| Jun    | 10 July           |
| Jul    | 10 August         |
| Aug    | 10 September      |
| Sep    | 10 October        |
| Oct    | 10 November       |
| Nov    | 10 December       |
| Dec    | 10 January (next) |

The threshold for mandatory monthly filing is reviewed annually by the Cyprus Tax
Department. The current threshold is €50,000 of intra-EU supplies per calendar year.
When a business crosses this threshold mid-year, monthly filing applies from the
following month.

---

## VIES Submission Deadlines

VIES (VAT Information Exchange System) submissions report intra-EU supplies of goods
and services. Submission frequency mirrors the VAT filing frequency.

| Frequency  | Submission Deadline                              |
|------------|--------------------------------------------------|
| Quarterly  | Same as VAT filing deadline (10th of month)      |
| Monthly    | Same as monthly VAT deadline (10th of month)     |

The platform generates VIES data automatically during the OUT run finalization phase
and stores it in `vies_records`. See `vies_record_format.md` for the record structure.

Submission is made via TaxisNet or by submitting the XML export to the Tax Department.

---

## Annual Income Tax — Corporate

| Obligation                          | Deadline                                      |
|-------------------------------------|-----------------------------------------------|
| Provisional tax return (first)      | 31 July of the current tax year               |
| Provisional tax return (second)     | 31 December of the current tax year           |
| Final corporate tax return (IR4)    | 31 March of the following year                |
| Extension option                    | Electronic submissions may receive extension — confirm with Tax Department annually |

**Corporate Tax Rate (2026):** 12.5% on net profits.

Exemptions and deductions applicable to Cyprus resident companies:
- Dividend income received: generally exempt (subject to SDC rules).
- Royalty income under IP Box regime: 80% exempt (effective rate 2.5%).
- Capital gains on disposal of shares: generally exempt.

Note: the platform does not file corporate tax returns directly. It provides profit and
loss reports and chart-of-accounts summaries that the accountant uses to prepare the IR4.

---

## Audit Requirements

| Condition                                  | Requirement                                      |
|--------------------------------------------|--------------------------------------------------|
| Annual turnover > €100,000                 | Statutory audit required — Companies Law Cap. 113 |
| Annual turnover ≤ €100,000                 | Audit not mandatory; accountant review recommended |
| Public interest entities                   | Audit required regardless of turnover             |
| Dormant companies                          | Simplified accounts; audit waiver available        |

The statutory audit must be conducted by a registered Cyprus auditor (member of the
Institute of Certified Public Accountants of Cyprus — ICPAC). Audited accounts must be
filed with the Registrar of Companies within 12 months of the financial year end.

The platform export bundle (see `archive_bundle_file_manifest.md`) provides the
auditor with the full transaction set, categorised ledger, and VAT workings needed to
conduct the audit. The bundle is tamper-evident via TSA timestamp and hash chain.

---

## Social Insurance Contributions

Employers and self-employed persons must remit social insurance contributions monthly.

| Contributor Type    | Deadline                           | Portal                              |
|---------------------|------------------------------------|-------------------------------------|
| Employer            | 10th of the following month        | Social Insurance Services — e-SI    |
| Self-employed       | 10th of the following month        | Social Insurance Services — e-SI    |
| Employee (PAYE)     | Deducted at source; remitted monthly by employer | — |

**Contribution rates (2026, indicative — verify against current Social Insurance Law):**

| Fund                         | Employer % | Employee % |
|------------------------------|------------|------------|
| Social Insurance             | 8.8%       | 8.8%       |
| General Healthcare (GHS)     | 2.9%       | 2.65%      |
| Redundancy Fund              | 1.2%       | —          |
| Human Resource Development   | 0.5%       | —          |
| Social Cohesion Fund         | 2.0%       | —          |

Late payment of social insurance contributions attracts a 3% surcharge per annum on the
outstanding amount, plus a fixed penalty of €50 per late return.

---

## Penalty Schedule

### VAT Penalties

| Violation                              | Penalty                                                   |
|----------------------------------------|-----------------------------------------------------------|
| Late payment of VAT due                | 10% of VAT amount due, plus daily interest at ECB rate + 2% |
| Late submission of VAT return          | €50 per month late (max €3,000 per return)                |
| Failure to register for VAT            | €85 one-off penalty plus retroactive VAT liability         |
| Incorrect VAT return (underpayment)    | 10% of underpaid amount plus interest                      |
| VIES non-submission                    | €50 per month late                                         |

### Income Tax Penalties

| Violation                              | Penalty                                               |
|----------------------------------------|-------------------------------------------------------|
| Late submission of tax return          | €100 flat fee                                         |
| Late payment of income tax             | Interest at ECB rate + 3.5% per annum                 |
| Inaccurate return                      | 10% of tax shortfall + interest                       |

### General Notes

- Penalties are assessed by the Cyprus Tax Department. The platform surfaces upcoming
  deadlines to help users avoid late filings but does not guarantee compliance.
- Users are advised to retain a qualified Cyprus accountant for all tax filings.

---

## Cyprus Bank Holiday Schedule

The following dates are public holidays in Cyprus. Deadlines falling on these dates
roll to the next business day.

| Date                  | Holiday Name                                     |
|-----------------------|--------------------------------------------------|
| 1 January             | New Year's Day                                   |
| 6 January             | Epiphany                                         |
| Variable (late Feb / Mar) | Green Monday (Kathari Deftera) — 48 days before Easter |
| 25 March              | Greek Independence Day                           |
| 1 April               | Cyprus National Day (EOKA Day)                   |
| Variable (Apr)        | Good Friday (Orthodox)                           |
| Variable (Apr / May)  | Easter Sunday (Orthodox)                         |
| Variable (Apr / May)  | Easter Monday (Orthodox)                         |
| 1 May                 | Labour Day                                       |
| Variable (May / Jun)  | Whit Monday (Kataklysmos) — 50 days after Orthodox Easter |
| 15 August             | Assumption of the Virgin Mary                    |
| 1 October             | Cyprus Independence Day                          |
| 28 October            | Ochi Day (Greek National Day)                    |
| 25 December           | Christmas Day                                    |
| 26 December           | Second Day of Christmas                          |

Note: Orthodox Easter varies by year. The platform recalculates Orthodox Easter
programmatically (Meeus/Jones/Butcher algorithm) for each year when computing
effective deadline dates. Do not hardcode Easter-adjacent holiday dates.

---

## Deadline Rollover Rule

When a statutory deadline falls on a Saturday, Sunday, or Cyprus public holiday:

- The effective deadline moves to the **next calendar day that is neither a Saturday,
  Sunday, nor a Cyprus public holiday**.
- The platform stores the effective (rolled) deadline in `period.vat_filing_deadline`.
- The platform stores the nominal (statutory) deadline in `period.vat_filing_deadline_nominal`
  for audit and display purposes.

### Rollover Examples

| Nominal Deadline | Day          | Rolled To     |
|------------------|--------------|---------------|
| 10 April 2027    | Saturday     | 12 April 2027 (Monday) |
| 10 July 2026     | Friday       | 10 July 2026 (no roll needed) |
| 10 January 2027  | Sunday       | 11 January 2027 (Monday) |

---

## GDPR Annual Review Recommendation

Although not a statutory filing deadline, Cyprus DPA guidance recommends an annual
internal review of:

| Review Activity                           | Recommended Timing              |
|-------------------------------------------|---------------------------------|
| Privacy Notice review and update          | January of each year            |
| Data Retention Schedule review            | January of each year            |
| DPA audit readiness self-assessment       | Q1 of each year                 |
| Data Processing Agreements (DPAs) review  | Upon any change in sub-processors |
| DPIA update for high-risk processing      | Whenever processing scope changes |

The platform retains audit log data per `redaction_field_map.md` retention rules.
Annual GDPR review should confirm that automated deletion of expired personal data is
running correctly and that no manual overrides have created retention exceptions.

---

## Integration with Platform — period_schema.md

The `periods` table includes the following compliance deadline fields, populated
automatically by the platform using the rules above:

| Field                             | Description                                          |
|-----------------------------------|------------------------------------------------------|
| `vat_filing_deadline`             | Effective deadline after holiday rollover             |
| `vat_filing_deadline_nominal`     | Statutory deadline before rollover                    |
| `vies_submission_deadline`        | Same value as vat_filing_deadline (same schedule)     |
| `filing_frequency`                | QUARTERLY or MONTHLY — from business entity settings  |

Reminder events are triggered by the platform at:
- T-14 days: reminder notification to business entity admin.
- T-7 days: reminder with urgency flag.
- T-1 day: final reminder if filing not yet submitted.
- T+0 (deadline day, 08:00 CY time): overdue alert if status is not FINALIZED.

---

## Related Documents

- `/Docs/sub/reference/vat_rate_table_reference.md`
- `/Docs/sub/reference/cyprus_vat_rule_catalog.md`
- `/Docs/sub/reference/vies_record_format.md`
- `/Docs/sub/ui/settings_vat_ui_spec.md`
- `/Docs/sub/ui/vat_period_overview_ui_spec.md`
- `/Docs/sub/runbooks/vat_submission_rejection_runbook.md`
- `/Docs/sub/runbooks/vies_submission_failure_runbook.md`
