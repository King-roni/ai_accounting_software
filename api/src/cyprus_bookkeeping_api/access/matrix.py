"""The canonical (role, surface) → Decision matrix.

Mirrors the live `public.permission_matrix` table (and the consolidated table in
`Docs/sub/reference/permission_matrix.md`). Step-up is marked on FINALIZATION,
APPROVAL_STEP_UP, and WORKFLOW_RUN (upload / manual run trigger). The
per-business-optional toggles on BUSINESS_SETTINGS_EDIT / USER_INVITE /
EXTERNAL_INTEGRATION are deferred Stage 2 toggles and are NOT encoded as
REQUIRE_STEP_UP here.

Adding or changing a grant requires a `Docs/decisions_log.md` amendment.
"""
from __future__ import annotations

from cyprus_bookkeeping_api.access.enums import Decision, PermissionSurface, Role

_ALLOW = Decision.ALLOW
_DENY = Decision.DENY
_STEP = Decision.REQUIRE_STEP_UP

# Roles in column order matching the matrix doc, for clarity.
_ROLES_IN_COLUMN_ORDER: tuple[Role, ...] = (
    Role.OWNER,
    Role.ADMIN,
    Role.BOOKKEEPER,
    Role.ACCOUNTANT,
    Role.REVIEWER,
    Role.READ_ONLY,
)

# Each row: (surface, [owner, admin, bookkeeper, accountant, reviewer, read_only])
# Sourced verbatim from permission_matrix.md "Consolidated matrix (all surfaces)".
_ROWS: tuple[tuple[PermissionSurface, tuple[Decision, ...]], ...] = (
    (PermissionSurface.SESSION_MANAGE,           (_ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW)),
    (PermissionSurface.USER_INVITE,              (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.BUSINESS_SETTINGS_EDIT,   (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.EXTERNAL_INTEGRATION,     (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.WORKFLOW_TRIGGER,         (_ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY,  _DENY)),
    (PermissionSurface.WORKFLOW_APPROVE,         (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.FINALIZATION,             (_STEP,  _STEP,  _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.REVIEW_QUEUE_VIEW,        (_ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW)),
    (PermissionSurface.REVIEW_QUEUE_RESOLVE,     (_ALLOW, _ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY)),
    (PermissionSurface.REVIEW_ASSIGN,            (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.REVIEW_REGENERATE,        (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.REPORT_EXPORT_BASIC,      (_ALLOW, _ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY)),
    (PermissionSurface.REPORT_EXPORT_FULL,       (_ALLOW, _ALLOW, _DENY,  _ALLOW, _DENY,  _DENY)),
    (PermissionSurface.DASHBOARD_VIEW,           (_ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW)),
    (PermissionSurface.DASHBOARD_REFRESH_MANUAL, (_ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW, _ALLOW)),
    # Later-block surfaces — decisions mirrored from the live permission_matrix.
    (PermissionSurface.APPROVAL_STANDARD,        (_ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY,  _DENY)),
    (PermissionSurface.APPROVAL_STEP_UP,         (_STEP,  _STEP,  _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.CLIENT_MANAGE,            (_ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY,  _DENY)),
    (PermissionSurface.CREDIT_NOTE_ISSUE,        (_ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY,  _DENY)),
    (PermissionSurface.INVOICE_CREATE,           (_ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY,  _DENY)),
    (PermissionSurface.INVOICE_MANAGE,           (_ALLOW, _ALLOW, _ALLOW, _DENY,  _DENY,  _DENY)),
    (PermissionSurface.WORKFLOW_CONFIG_MANAGE,   (_ALLOW, _ALLOW, _DENY,  _DENY,  _DENY,  _DENY)),
    (PermissionSurface.WORKFLOW_RUN,             (_STEP,  _STEP,  _DENY,  _DENY,  _DENY,  _DENY)),
)


def _build_matrix() -> dict[tuple[Role, PermissionSurface], Decision]:
    out: dict[tuple[Role, PermissionSurface], Decision] = {}
    for surface, decisions in _ROWS:
        if len(decisions) != len(_ROLES_IN_COLUMN_ORDER):
            raise AssertionError(
                f"matrix row for {surface!r} has {len(decisions)} columns, "
                f"expected {len(_ROLES_IN_COLUMN_ORDER)}"
            )
        for role, decision in zip(_ROLES_IN_COLUMN_ORDER, decisions, strict=True):
            out[(role, surface)] = decision
    return out


PERMISSION_MATRIX: dict[tuple[Role, PermissionSurface], Decision] = _build_matrix()


def assert_matrix_complete() -> None:
    """Fail loudly if any (role, surface) cell is missing.

    Called by the application bootstrap; also covered as a unit test so the
    failure surfaces before runtime.
    """
    missing: list[tuple[str, str]] = []
    for role in Role:
        for surface in PermissionSurface:
            if (role, surface) not in PERMISSION_MATRIX:
                missing.append((role.value, surface.value))
    if missing:
        raise AssertionError(
            f"Permission matrix incomplete: {len(missing)} missing cells: {missing}"
        )


def matrix_as_table() -> str:
    """Render the matrix as a markdown table for documentation / audit print.

    Matches the column order in `permission_matrix.md` for diff-friendly review.
    """
    header_cells = ["Surface", *[r.value for r in _ROLES_IN_COLUMN_ORDER]]
    sep_cells = ["---"] * len(header_cells)
    lines = [
        "| " + " | ".join(header_cells) + " |",
        "| " + " | ".join(sep_cells) + " |",
    ]
    symbol = {Decision.ALLOW: "✓", Decision.DENY: "✗", Decision.REQUIRE_STEP_UP: "✓ + step-up"}
    for surface, _ in _ROWS:
        row = [surface.value]
        for role in _ROLES_IN_COLUMN_ORDER:
            row.append(symbol[PERMISSION_MATRIX[(role, surface)]])
        lines.append("| " + " | ".join(row) + " |")
    return "\n".join(lines)
