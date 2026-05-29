# Prompt Corpus — Cyprus Bookkeeping SaaS

Source of truth for AI prompts. Synced into the `public.prompt_registry` table
in Supabase via `scripts/sync_prompts_to_registry.py`.

## Layout

```
prompts/
  <block_dir>/<prompt_name>/v<n>/
    prompt.txt                — the template
    meta.yaml                 — metadata (prompt_id, version, schemas, ai_tier, …)
    tests/<case_name>.json    — one test case per file (≥5 per version, ≥1 adversarial)
```

`<block_dir>` is the two-digit owning block (e.g. `08_classification`).

`<prompt_id>` in `meta.yaml` is dot-namespaced lowercase (e.g.
`classification.supplier_name_normalization`). Same regex enforced by the
`prompt_registry_id_namespaced` CHECK in the DB.

`<version>` is full semver (e.g. `1.0.0`). Enforced by
`prompt_registry_version_semver`.

## Content rules

* Content per version is **immutable**. Bumping any field in `meta.yaml`, any
  byte in `prompt.txt`, or any test case requires a new version.
* Each `v<n>` directory **must** contain at least 5 test cases including at
  least one with `"is_adversarial_anchor": true`. Enforced by
  `register_prompt` in the DB.
* Removing a test case from a published version requires a documented removal
  entry in the per-prompt CHANGELOG (sub-doc workflow; not yet authored).

## Sync workflow

`scripts/sync_prompts_to_registry.py` walks this directory and calls
`public.register_prompt` for each `v<n>/` it finds. The script is idempotent:

* If `(prompt_id, version)` is already registered with the same `content_hash`,
  it skips.
* If `(prompt_id, version)` is registered with a **different** `content_hash`,
  the script fails (content drift between filesystem and DB — manual review
  required).

## Regression workflow

`scripts/run_prompt_regression.py` walks the corpus and validates structural
integrity (every meta.yaml parses, every test case JSON parses, every case's
`input` matches `meta.input_schema`, every `expected_output` matches
`meta.output_schema`). Output comparison against live model dispatch will land
once B06·P05 / B06·P06 are built.
