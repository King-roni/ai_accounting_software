# Block 03 — Workflow Engine

## Role in the System

The workflow engine is the only component that advances bookkeeping state. Every domain block exposes tools (parse, classify, match, extract, validate, generate); the engine decides when those tools run, in what order, against which data, and whether their results allow the run to advance to the next phase.

If the workflow engine is not invoked, no bookkeeping decision can be made. This is the hard contract that makes Principle 1 (Workflow-First Architecture) enforceable.

---

## Scope

### In scope
- The Workflow Run, Phase, Gate, and Tool model
- The state machine that controls run advancement
- Tool registration and invocation
- Audit-coupled state transitions
- Pause, resume, abort, and adjustment-run semantics
- Concurrency rules (one active run per business per workflow type)

### Out of scope (covered elsewhere)
- The actual logic of parsing, matching, extraction, classification → Blocks 07–11
- The OUT and IN pipelines as concrete sequences → Blocks 12 and 13
- Permission checks on phase invocation → Block 02 (Tenancy & Access Control)
- Audit log persistence → Block 05 (Security & Audit Layer)

---

## Core Concepts

### Workflow Run
A single end-to-end execution of a workflow against an accounting period, for a single business. Identified by `workflow_run_id`, scoped by `organization_id` and `business_id`. Carries lifecycle status, period bounds, started_by/finalized_by, and a summary JSON.

### Workflow Type
The named pipeline being run. Initial types: `OUT_MONTHLY`, `IN_MONTHLY`. Adjustment runs (`OUT_ADJUSTMENT`, `IN_ADJUSTMENT`) are separate types and produce amendment records, not edits to the original run.

The registry is **static + per-business config**: workflow types and their phase sequences are defined in code (compiled in, deployed via release), and a per-business configuration layer can enable or disable specific phases or tools (e.g. one business uses Drive search, another doesn't). New workflow types require a deploy; tuning of existing types per business does not.

### Phase
A step inside a workflow type. Each phase has:
- a unique name within its workflow type (e.g. `parse_statement`, `match_email_invoices`)
- declared input requirements (what must already exist in the run state)
- declared output guarantees (what the phase produces or transitions)
- one or more tool invocations
- entry and exit gate definitions

### Gate
A precondition that must evaluate true before the engine permits a transition. Gates are implemented as **registered functions per phase** — each phase declares its gate functions alongside its tool registrations, and the engine invokes them. Gate logic lives next to the phase it guards, which keeps the engine generic and the gate logic close to the data model it inspects. Examples:
- "all transactions in this run have a `transaction_type` set"
- "no review issue with severity `BLOCKING` is open"
- "user approval row exists for this run"

A gate failure does not crash the run; it produces a recorded reason and either holds the run at the current phase or routes it to a side phase (e.g. review).

### Tool
A function exposed by a domain block, registered with the engine, callable only inside a phase. Tools are pure with respect to the run state — they read inputs, produce outputs, and do not mutate state outside the phase contract.

### State
The combined set of records associated with a run: transactions, evidence files, match records, draft ledger entries, review issues, plus the run's own status and metadata.

---

## Run Lifecycle

```text
CREATED
  → RUNNING (engine begins phase 1)
     → PAUSED (manual hold; phase frozen)
     → RUNNING
     → REVIEW_HOLD (blocking issues exist; user action needed)
     → RUNNING
  → AWAITING_APPROVAL (all gates passed except user approval)
  → FINALIZING (lock sequence in progress)
  → FINALIZED (locked; archive package built)
ABORTED (terminal; only via explicit role-permitted action; full audit trail)
```

- A run can move from `RUNNING` to `REVIEW_HOLD` automatically when blocking issues appear, and back when they are resolved.
- `FINALIZED` is terminal and immutable (Block 15 owns the lock). To make changes, an adjustment run is created.
- `ABORTED` requires explicit role permission (Owner or Admin) and a written reason.

---

## State Transitions

Every transition (run state, phase entry, phase exit, gate evaluation, tool invocation) emits an audit event with:

- `workflow_run_id`, `phase_name`, `transition_kind`
- before-state and after-state identifiers
- the principal context from Block 02
- timestamp and reason
- tool name and tool result digest, when applicable

Block 05 persists these events to the audit log. The engine itself does not own audit storage; it only emits.

---

## Tool Registration

Each domain block declares its tools at startup. A registration includes:

- tool name (namespaced by block, e.g. `bank_pipeline.parse_csv`)
- input schema and output schema
- side-effect declaration (read-only, writes-to-run-state, calls-external-api)
- AI tier classification (Tier 1, 2, or 3 — see Block 06)
- failure semantics (retryable vs. fatal)

The engine refuses to invoke a tool whose declaration does not match the phase's expectation. This prevents accidental privilege expansion (e.g. a phase that promises "read-only" running a tool that mutates state).

---

## Run Triggers

Runs in MVP can be started in two ways:

- **Manual.** A user with appropriate role clicks Start in the UI for a given business, workflow type, and period.
- **Event-based.** Specific events automatically start a run — most importantly, a successful statement upload triggers the OUT (and optionally IN) workflow for the corresponding period.

Scheduled (cron-like) triggers are deferred beyond MVP. They can be added later without changing the engine model.

## Failure Policy

When a tool hits a transient external error (Gmail rate limit, OCR vendor blip, Anthropic API timeout, etc.), the engine applies **bounded retry, then notify the user**:

1. Retry the tool a small bounded number of times with backoff.
2. If it still fails, surface a structured review issue (severity HIGH or BLOCKING depending on phase) and pause the phase.
3. The user takes action (retry, skip, escalate). The engine resumes from the same phase boundary.

Per-tool overrides are possible at registration time but are the exception, not the default. Crashes and non-transient errors (schema violations, missing data) follow a different path: they fail the phase immediately and produce a review issue with diagnostic detail.

## Concurrency Rules

- One active run per (business, workflow type) at a time. Starting a second `OUT_MONTHLY` for a business while one is `RUNNING` is rejected.
- Adjustment runs may run concurrently with the next monthly run, but only against finalized periods. They produce **adjustment records carrying an explicit reason and a structured delta** against the original finalized data — never edits to the original.
- Inside a single run, phases execute sequentially by default. Parallel phase execution is permitted only when the engine can prove the phases write to disjoint state.

---

## Resumability

- The engine is resumable: a process restart mid-run picks up at the last persisted phase boundary.
- Tool invocations are idempotent or the engine wraps them with a deduplication key. Re-running a phase after a crash must produce the same state.
- A phase that calls an external service (Gmail search, OCR vendor) records the external request id so reruns can either dedupe or replay deterministically.

---

## Interfaces

### Inputs
- A start request from the user (via the UI or scheduled trigger), carrying workflow type, business, period
- Tool registrations from Blocks 06–13
- Gate evaluation results from gate functions registered alongside phases

### Outputs
- State transitions written to the operational database
- Audit events emitted to Block 05
- Run summaries available to Block 16 (Dashboard & Reporting)
- Finalization handoff to Block 15 (Finalization & Secure Archive)

---

## Operating Rules

- **Principle 1 (Workflow-First):** the engine is the sole advancer of bookkeeping state. UI may display, but cannot transition.
- **Principle 2 (Structured Data is Truth):** phase outputs write to structured records first; any generated artifact (e.g. evidence PDF) is a downstream effect.
- **Principle 3 (AI Assists, Rules Decide):** every gate is deterministic. AI may produce inputs that gates evaluate, but the gate logic itself is rules-only.

---

## Stage 1 Resolutions

All initially-open questions have been resolved (see `Docs/decisions_log.md`):

- **Workflow type registry:** static (compiled-in) + per-business config — covered above in Workflow Type.
- **Gate evaluation:** registered functions per phase — covered above in Gate.
- **Run triggers:** manual + event-based in MVP, no cron — covered in Run Triggers.
- **Failure policy:** bounded retry then notify the user — covered in Failure Policy.
- **Adjustment diffing:** explicit reason + structured delta — covered in Concurrency Rules.

No open questions remain at the architecture level. Phase docs will define exact retry counts/backoff curves, the event taxonomy that drives event-based triggers, and the schema of the adjustment delta.
