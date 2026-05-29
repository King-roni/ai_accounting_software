#!/usr/bin/env python3
"""B06·P04 — Sync prompts/ to the Supabase prompt_registry.

Walks the canonical prompt corpus at `prompts/` and emits `register_prompt`
calls for every `(prompt_id, version)` found on disk. Source of truth is the
filesystem; the DB is a runtime mirror.

Default mode is `--dry-run`: prints what *would* be called. `--apply` performs
the actual DB inserts via the Supabase service-role connection (env var
`SUPABASE_DB_URL` must be set to a postgres:// URL).

Idempotency:
  * Same `(prompt_id, version)` already registered, same `content_hash` → skip.
  * Same `(prompt_id, version)`, **different** `content_hash` → fail loudly.
    Content per version is immutable.

Requires PyYAML (system Python on the dev box already has it via the api/ env).
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
from dataclasses import dataclass
from pathlib import Path

try:
    import yaml  # type: ignore
except ImportError:
    print("ERROR: PyYAML required (pip install pyyaml)", file=sys.stderr)
    sys.exit(2)

REPO_ROOT = Path(__file__).resolve().parent.parent
PROMPTS_ROOT = REPO_ROOT / "prompts"


@dataclass(frozen=True)
class PromptVersion:
    prompt_id: str
    version: str
    purpose: str
    input_schema: dict
    output_schema: dict
    ai_tier: str
    prompt_template_text: str
    content_hash: str
    test_cases: list
    on_disk_path: Path


def compute_content_hash(meta: dict, template: str, cases: list) -> str:
    """Stable SHA-256 of the canonical-serialised triple. Order-independent for
    object keys via json.dumps(..., sort_keys=True)."""
    blob = json.dumps(
        {"meta": meta, "template": template, "cases": cases},
        sort_keys=True,
        ensure_ascii=False,
    ).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()


def load_prompt_version(version_dir: Path) -> PromptVersion:
    meta_path = version_dir / "meta.yaml"
    template_path = version_dir / "prompt.txt"
    if not meta_path.is_file():
        raise ValueError(f"{version_dir.relative_to(REPO_ROOT)}: missing meta.yaml")
    if not template_path.is_file():
        raise ValueError(f"{version_dir.relative_to(REPO_ROOT)}: missing prompt.txt")
    meta = yaml.safe_load(meta_path.read_text(encoding="utf-8"))
    template = template_path.read_text(encoding="utf-8")
    for field in ("prompt_id", "version", "purpose", "input_schema",
                  "output_schema", "ai_tier"):
        if field not in meta:
            raise ValueError(
                f"{meta_path.relative_to(REPO_ROOT)}: missing required key '{field}'")
    cases_dir = version_dir / "tests"
    if not cases_dir.is_dir():
        raise ValueError(
            f"{version_dir.relative_to(REPO_ROOT)}: missing tests/ directory")
    cases = []
    for case_file in sorted(cases_dir.glob("*.json")):
        case = json.loads(case_file.read_text(encoding="utf-8"))
        for field in ("case_name", "input"):
            if field not in case:
                raise ValueError(
                    f"{case_file.relative_to(REPO_ROOT)}: missing required key '{field}'")
        cases.append(case)
    if len(cases) < 5:
        raise ValueError(
            f"{version_dir.relative_to(REPO_ROOT)}: only {len(cases)} test case(s) "
            f"on disk; B06·P04 spec requires ≥5")
    if not any(c.get("is_adversarial_anchor") for c in cases):
        raise ValueError(
            f"{version_dir.relative_to(REPO_ROOT)}: no test case has "
            f"is_adversarial_anchor=true; B06·P04 spec requires ≥1")
    content_hash = compute_content_hash(meta, template, cases)
    return PromptVersion(
        prompt_id=meta["prompt_id"],
        version=meta["version"],
        purpose=meta["purpose"],
        input_schema=meta["input_schema"],
        output_schema=meta["output_schema"],
        ai_tier=meta["ai_tier"],
        prompt_template_text=template,
        content_hash=content_hash,
        test_cases=cases,
        on_disk_path=version_dir,
    )


def discover_versions(root: Path):
    """Yield PromptVersion for every prompts/.../v<n>/ directory found."""
    if not root.is_dir():
        return
    for version_dir in sorted(root.glob("*/*/v*")):
        if not version_dir.is_dir():
            continue
        yield load_prompt_version(version_dir)


def apply_via_supabase(pv: PromptVersion, owner_user_id: str, db_url: str) -> str:
    """Calls register_prompt over psycopg. Returns 'inserted' | 'skipped' | 'drift'.

    Imported lazily so the dry-run path has zero external deps.
    """
    try:
        import psycopg  # type: ignore
    except ImportError as exc:
        raise SystemExit(
            "ERROR: --apply requires `psycopg` (pip install psycopg[binary])"
        ) from exc

    with psycopg.connect(db_url) as conn:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT content_hash FROM public.prompt_registry "
                "WHERE prompt_id = %s AND version = %s",
                (pv.prompt_id, pv.version),
            )
            row = cur.fetchone()
            if row is not None:
                if row[0] == pv.content_hash:
                    return "skipped"
                return "drift"
            cur.execute(
                "SELECT public.register_prompt(%s,%s,%s,%s,%s::jsonb,%s::jsonb,"
                "%s::ai_tier_enum,%s,%s,%s::jsonb)",
                (
                    owner_user_id, pv.prompt_id, pv.version, pv.purpose,
                    json.dumps(pv.input_schema), json.dumps(pv.output_schema),
                    pv.ai_tier, pv.prompt_template_text, pv.content_hash,
                    json.dumps(pv.test_cases),
                ),
            )
            envelope = cur.fetchone()[0]
            conn.commit()
            if not envelope.get("ok"):
                raise SystemExit(
                    f"register_prompt rejected {pv.prompt_id}@{pv.version}: {envelope}")
            return "inserted"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apply", action="store_true",
                        help="actually call register_prompt (default is dry-run)")
    parser.add_argument("--owner-user-id",
                        help="UUID of the Owner user to record as registered_by")
    args = parser.parse_args()

    try:
        versions = list(discover_versions(PROMPTS_ROOT))
    except ValueError as e:
        print(f"corpus structural error: {e}", file=sys.stderr)
        return 1

    if not versions:
        print(f"No prompt versions found under {PROMPTS_ROOT.relative_to(REPO_ROOT)}")
        return 0

    print(f"Discovered {len(versions)} prompt version(s):")
    for pv in versions:
        print(f"  {pv.prompt_id}@{pv.version}  hash={pv.content_hash[:12]}…  "
              f"cases={len(pv.test_cases)}  path={pv.on_disk_path.relative_to(REPO_ROOT)}")

    if not args.apply:
        print("\n(dry-run; pass --apply --owner-user-id <uuid> to register)")
        return 0

    db_url = os.environ.get("SUPABASE_DB_URL")
    if not db_url:
        print("ERROR: SUPABASE_DB_URL env var required for --apply", file=sys.stderr)
        return 2
    if not args.owner_user_id:
        print("ERROR: --owner-user-id required for --apply", file=sys.stderr)
        return 2

    for pv in versions:
        result = apply_via_supabase(pv, args.owner_user_id, db_url)
        print(f"  {pv.prompt_id}@{pv.version}: {result}")
        if result == "drift":
            print(
                f"FATAL: on-disk content_hash {pv.content_hash} does not match the "
                f"DB-registered hash for {pv.prompt_id}@{pv.version}. Prompt content "
                f"per version is immutable — bump the version instead.",
                file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
