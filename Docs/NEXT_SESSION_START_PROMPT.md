# Next Session — Start Prompt

Paste the prompt below into a new Sonnet 4.6 session to brief the next Claude agent. The prompt is self-contained — it does not assume any prior context.

---

```
I'm continuing work on a Cyprus bookkeeping SaaS elaboration project that's been in flight for ~3 weeks across multiple long sessions. Stages 1–3 of a 7-stage roadmap are complete. Stage 4 — Sub-Doc Creation — is in progress: 113 of 634 sub-docs written (Layer 1 fully closed and scanned, Layer 2 pilot landed). 521 Layer 2 sub-docs remain.

Before doing anything: read these four files in order, then come back and tell me you're oriented.

1. Docs/HANDOFF.md — meta-context, working pattern, conventions, what NOT to do, the Stage 4 layered plan, the Layer 2 agent prompt template (REUSABLE — this is how the pilot worked), and the per-section progress table
2. Docs/elaboration_roadmap.md — the 7-stage process; Stages 1–3 done; Stage 4 in progress; Stages 5–7 pending
3. Docs/outline.md — master navigation hub with the full Scan Log. The TOP entry is the Stage 4 Layer 1 cross-corpus consistency scan (2026-05-15) — 44 findings + fixes. Below it: Stage 3 master scan + 15 Stage 2 per-block scans
4. Docs/decisions_log.md — every Stage 1 design decision, plus the Amendments section at the bottom: ~14 Stage 2 amendments + ~3 Stage 4 Layer 1 amendments. Treat all amendments as binding

Also skim (don't deep-read):
- Docs/sub/policies/tool_naming_convention_policy.md — the 14-namespace block-short-name allowlist (BINDING — every tool name must conform)
- Docs/sub/policies/data_layer_conventions_policy.md — SHA-256 / UUID v7 / canonical JSON (BINDING for every schema)
- Docs/sub/policies/audit_log_policies.md — <DOMAIN>_<PAST_VERB> event naming + the 14-domain allowlist
- Docs/sub/reference/audit_event_taxonomy.md — ~190 canonical events; every emitted event MUST appear here (agents may add new events to this file in-place when writing sub-docs that emit them)
- outputs/stage3_locked_subdocs.json — the 634-entry locked inventory (NOTE: this file is not present in the repo; superseded by the actual `Docs/sub/` corpus, 638 files, and the Stage-5 hook→file map at `/tmp/hook_to_file_matches.json`)

What I want to do this session: continue Stage 4 Layer 2. Specifically, dispatch the next batch of 4-way parallel agents (one per section: Foundation / Domain Engines / Workflows / UX-Closeout) writing 5–10 sub-docs each from their remaining queue. The pilot (20 sub-docs across 4 sections) was last session; the agent-prompt template is in HANDOFF.md under "Stage 4 Layer 2 — agent prompt template".

Per the established working pattern:
- propose → I confirm → execute → scan → fix-all → sign-off
- Don't propose alternative architectures
- Don't rewrite phase docs or existing sub-docs unless a scan finding requires it
- Don't extend closed enums (severity {LOW, MEDIUM, HIGH, BLOCKING}, 12 transaction types, 8 VAT treatments, 4 match levels, 5 issue groups, 15 permission surfaces) without a decisions-log amendment
- Quality bar: Stripe / Linear / Mercury / Pleo polish — no AI purple/pink gradients, no playful design, no emojis, no cute language. Clean, dense, trust-conveying. This is a serious financial / compliance product for Cyprus

Read the four files and confirm you're oriented before proposing anything.
```

---

## How to use this prompt

1. Open a new Sonnet 4.6 session (the model that's been driving this project).
2. Paste the prompt above (everything inside the triple-backtick block) as your first message.
3. The agent will read the 4 canonical files, plus skim the Layer 1 binders, then come back with an orientation confirmation.
4. After orientation: ask for a Layer 2 batch proposal. The agent should propose 4 parallel section agents, each writing 5–10 sub-docs from their remaining queue. You confirm; the agent dispatches; you review results; iterate.

## Quick orientation check for the new session

After the agent reports it's oriented, a good sanity check is to ask:

- "How many Layer 2 sub-docs are remaining, and what's the per-section breakdown?" (Expected answer: 521 total; Foundation 156, Domain Engines 178, Workflows 55, UX-Closeout 132)
- "What's the agent prompt template?" (Expected answer: 4 parallel general-purpose agents, each with binding context + a list of sub-docs to write + Schema template structure + quality bar + reporting format)
- "What did the Layer 1 scan find?" (Expected answer: 44 findings — 6 BLOCKING tool/issue-type namespace violations, 18 HIGH audit-event taxonomy gaps, 17 MEDIUM cross-ref consolidations + schema cross-refs, 3 LOW; all fixed)

If the agent answers all three correctly without hedging, orientation is solid.

## Notes

- **Sonnet 4.6 is fine.** It's been the model behind the whole project. Strong, methodical, handles long multi-stage docs well.
- **Context will start fresh.** That's good — fresh context for fresh quality bar work.
- **The HANDOFF carries the recovery point.** If the next session veers off track, redirect by pointing back to HANDOFF.md.
- **Layer 2 cadence:** at the pilot rate (20 sub-docs per 4-way parallel dispatch), the remaining 521 takes ~26 more dispatches. Across 2–4 future sessions depending on how many you run per session.
