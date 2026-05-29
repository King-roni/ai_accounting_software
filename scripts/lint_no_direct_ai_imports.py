#!/usr/bin/env python3
"""B06·P02 bypass-detection lint.

Implements the static half of the spec's "bypass detection" requirement
(Docs/phases/06_ai_layer/02_privacy_gateway_pipeline.md §Deliverables, §DoD).

Refuses direct imports of LLM provider SDKs (Anthropic, OpenAI, Ollama,
llama_cpp, and equivalent JS packages) outside the canonical AI integration
directories. Those directories are where B06·P05 (Tier 3 Anthropic) and
B06·P06 (Tier 2 local LLM) land their dispatch code. The runtime-refusal
half of bypass detection is owned by those phases inside the integration
modules.

Exits 0 on clean, 1 on any violation. Designed to be wired into CI before
merge and runnable locally as `python3 scripts/lint_no_direct_ai_imports.py`.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

# Directories scanned. Paths are relative to REPO_ROOT.
SCAN_ROOTS = [
    "api/src",
    "web/src",
]

# Allow-list: any import is OK if its file lives under one of these paths.
# These are the canonical homes for AI provider dispatch code. They do not
# need to exist yet — B06·P05 / B06·P06 will create them. Adding a new
# allow-listed dir requires a corresponding ADR entry, not a silent edit.
ALLOWED_DIRS = [
    "api/src/cyprus_bookkeeping_api/ai_integrations",
    "web/src/lib/ai_integrations",
]

# Patterns the linter refuses outside ALLOWED_DIRS.
# Python: `import X`, `from X import …`, including dotted submodule access.
PY_PATTERNS = [
    re.compile(r"^\s*(?:from|import)\s+(anthropic)\b"),
    re.compile(r"^\s*(?:from|import)\s+(openai)\b"),
    re.compile(r"^\s*(?:from|import)\s+(ollama)\b"),
    re.compile(r"^\s*(?:from|import)\s+(llama_cpp)\b"),
    re.compile(r"^\s*(?:from|import)\s+(google\.generativeai)\b"),
]

# TypeScript / JavaScript: `import … from 'pkg'` / `require('pkg')`.
TS_PATTERNS = [
    re.compile(r"""(?:from|require\(?)\s*['"]@anthropic-ai/sdk(?:/[^'"]*)?['"]"""),
    re.compile(r"""(?:from|require\(?)\s*['"]anthropic(?:/[^'"]*)?['"]"""),
    re.compile(r"""(?:from|require\(?)\s*['"]openai(?:/[^'"]*)?['"]"""),
    re.compile(r"""(?:from|require\(?)\s*['"]ollama(?:/[^'"]*)?['"]"""),
    re.compile(r"""(?:from|require\(?)\s*['"]@google/generative-ai(?:/[^'"]*)?['"]"""),
]

PY_EXT = {".py"}
TS_EXT = {".ts", ".tsx", ".mts", ".cts", ".js", ".jsx", ".mjs", ".cjs"}


@dataclass(frozen=True)
class Violation:
    path: Path
    line_no: int
    line: str
    matched: str


def is_allowed(path: Path) -> bool:
    rel = path.relative_to(REPO_ROOT).as_posix()
    return any(rel.startswith(d + "/") or rel == d for d in ALLOWED_DIRS)


def iter_files(root: Path):
    for dirpath, dirnames, filenames in os.walk(root):
        # Prune common skip dirs in place so os.walk doesn't recurse into them.
        dirnames[:] = [
            d for d in dirnames
            if d not in {"node_modules", ".next", "dist", "build", "__pycache__", ".venv"}
        ]
        for fn in filenames:
            p = Path(dirpath) / fn
            ext = p.suffix.lower()
            if ext in PY_EXT or ext in TS_EXT:
                yield p


def scan_file(path: Path) -> list[Violation]:
    if is_allowed(path):
        return []
    ext = path.suffix.lower()
    patterns = PY_PATTERNS if ext in PY_EXT else TS_PATTERNS
    out: list[Violation] = []
    try:
        text = path.read_text(encoding="utf-8")
    except (UnicodeDecodeError, OSError):
        return []
    for i, line in enumerate(text.splitlines(), start=1):
        for pat in patterns:
            m = pat.search(line)
            if m:
                out.append(Violation(path=path, line_no=i, line=line.rstrip(),
                                     matched=m.group(0).strip()))
                break  # one violation per line is enough
    return out


def main() -> int:
    violations: list[Violation] = []
    for root_rel in SCAN_ROOTS:
        root = REPO_ROOT / root_rel
        if not root.exists():
            continue
        for path in iter_files(root):
            violations.extend(scan_file(path))

    if not violations:
        print("lint_no_direct_ai_imports: clean")
        return 0

    print(f"lint_no_direct_ai_imports: {len(violations)} violation(s) found", file=sys.stderr)
    print("Direct LLM-SDK imports are only allowed under:", file=sys.stderr)
    for d in ALLOWED_DIRS:
        print(f"  - {d}", file=sys.stderr)
    print("All other code must go through public.ai_gateway_invoke_begin /", file=sys.stderr)
    print("ai_gateway_invoke_finalize (B06·P02). See bypass-detection in", file=sys.stderr)
    print("Docs/phases/06_ai_layer/02_privacy_gateway_pipeline.md.", file=sys.stderr)
    print("", file=sys.stderr)
    for v in violations:
        rel = v.path.relative_to(REPO_ROOT).as_posix()
        print(f"{rel}:{v.line_no}: {v.matched}", file=sys.stderr)
        print(f"    {v.line}", file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
