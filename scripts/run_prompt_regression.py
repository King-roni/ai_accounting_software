#!/usr/bin/env python3
"""B06·P04 — Prompt regression runner (structural validation half).

Walks the canonical prompt corpus at `prompts/` and validates:

* every `meta.yaml` parses and carries the required keys
* every test case JSON parses and carries the required keys
* every case's `input` satisfies `meta.input_schema.required` and
  `meta.input_schema.additionalProperties=false` when set
* every case's `expected_output` (when present) satisfies the same against
  `meta.output_schema`

The output-comparison half (call the prompt via the gateway with each case's
input and compare against `expected_output` + `must_contain_assertions`) lands
once B06·P05 / B06·P06 wire real model dispatch. The hook is the
`compare_against_dispatch` function below — currently a TODO no-op.

Exits 0 on clean structural validation, 1 on any failure. Designed to be
hooked into CI before merge; runnable locally as
`python3 scripts/run_prompt_regression.py`.
"""

from __future__ import annotations

import json
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


@dataclass
class Finding:
    path: Path
    message: str

    def fmt(self) -> str:
        rel = self.path.relative_to(REPO_ROOT)
        return f"{rel}: {self.message}"


def _check_required_keys(payload: dict, required: list, path: Path,
                         where: str, findings: list) -> None:
    for key in required:
        if key not in payload:
            findings.append(Finding(path, f"{where}: missing required key '{key}'"))


def _check_additional_properties(payload: dict, schema: dict, path: Path,
                                 where: str, findings: list) -> None:
    if schema.get("additionalProperties") is False:
        allowed = set((schema.get("properties") or {}).keys())
        actual = set(payload.keys())
        extra = actual - allowed
        if extra:
            findings.append(Finding(
                path, f"{where}: unexpected keys (additionalProperties=false): "
                       f"{sorted(extra)}"))


def validate_payload_against_schema(payload, schema: dict, path: Path,
                                    where: str, findings: list) -> None:
    if not isinstance(payload, dict):
        findings.append(Finding(path, f"{where}: must be a JSON object"))
        return
    _check_required_keys(payload, schema.get("required", []), path, where, findings)
    _check_additional_properties(payload, schema, path, where, findings)


def compare_against_dispatch(meta: dict, case: dict, case_path: Path,
                              findings: list) -> None:
    """TODO(B06·P05/P06): when real model dispatch lands, this should:
      1. Call public.ai_gateway_invoke_begin(...) with case['input'] against
         a tool wired to this prompt_id.
      2. Application-layer dispatch (Anthropic / local LLM).
      3. Call public.ai_gateway_invoke_finalize(...) with the raw response.
      4. Compare validated_output against case.expected_output (exact match for
         structured; semantic comparator + must_contain_assertions for free
         text — see sub-doc test_corpus_structure.md).
      5. record_prompt_regression_failed() with any failing cases.

    For now: structural validation only. No-op here so the runner is
    callable today.
    """
    return None


def validate_version_dir(version_dir: Path, findings: list) -> None:
    meta_path = version_dir / "meta.yaml"
    template_path = version_dir / "prompt.txt"
    tests_dir = version_dir / "tests"

    if not meta_path.is_file():
        findings.append(Finding(version_dir, "missing meta.yaml"))
        return
    if not template_path.is_file():
        findings.append(Finding(version_dir, "missing prompt.txt"))
    try:
        meta = yaml.safe_load(meta_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as e:
        findings.append(Finding(meta_path, f"meta.yaml parse error: {e}"))
        return
    if not isinstance(meta, dict):
        findings.append(Finding(meta_path, "meta.yaml must be a mapping"))
        return
    for field in ("prompt_id", "version", "purpose", "input_schema",
                  "output_schema", "ai_tier"):
        if field not in meta:
            findings.append(Finding(meta_path, f"missing required key '{field}'"))

    if not tests_dir.is_dir():
        findings.append(Finding(version_dir, "missing tests/ directory"))
        return

    case_files = sorted(tests_dir.glob("*.json"))
    if len(case_files) < 5:
        findings.append(Finding(
            tests_dir, f"only {len(case_files)} test case file(s); "
                        f"spec requires ≥5"))
    seen_adversarial = False
    for case_file in case_files:
        try:
            case = json.loads(case_file.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            findings.append(Finding(case_file, f"JSON parse error: {e}"))
            continue
        for field in ("case_name", "input"):
            if field not in case:
                findings.append(Finding(case_file, f"missing required key '{field}'"))
        if "input_schema" in meta and "input" in case:
            validate_payload_against_schema(
                case["input"], meta["input_schema"], case_file, "input", findings)
        if "output_schema" in meta and case.get("expected_output") is not None:
            validate_payload_against_schema(
                case["expected_output"], meta["output_schema"], case_file,
                "expected_output", findings)
        if case.get("is_adversarial_anchor"):
            seen_adversarial = True
        compare_against_dispatch(meta, case, case_file, findings)
    if case_files and not seen_adversarial:
        findings.append(Finding(
            tests_dir, "no test case has is_adversarial_anchor=true; spec requires ≥1"))


def main() -> int:
    if not PROMPTS_ROOT.is_dir():
        print(f"no prompts/ directory at {PROMPTS_ROOT}", file=sys.stderr)
        return 1
    findings: list = []
    version_dirs = sorted(PROMPTS_ROOT.glob("*/*/v*"))
    if not version_dirs:
        print(f"no prompt versions under {PROMPTS_ROOT.relative_to(REPO_ROOT)}")
        return 0
    for vd in version_dirs:
        if not vd.is_dir():
            continue
        validate_version_dir(vd, findings)

    if not findings:
        print(f"run_prompt_regression: clean ({len(version_dirs)} version(s) validated)")
        return 0
    print(f"run_prompt_regression: {len(findings)} finding(s):", file=sys.stderr)
    for f in findings:
        print(f"  {f.fmt()}", file=sys.stderr)
    print("Note: output-comparison against live dispatch lands with B06·P05/P06.",
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
