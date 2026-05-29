"""Block 02 Phase 04 — matrix coverage tests.

Asserts every (role × surface) cell is present and matches the canonical
permission_matrix.md table.
"""
from __future__ import annotations

import pytest

from cyprus_bookkeeping_api.access import (
    PERMISSION_MATRIX,
    Decision,
    PermissionSurface,
    Role,
    assert_matrix_complete,
    matrix_as_table,
)

# Canonical truth from Docs/sub/reference/permission_matrix.md (consolidated
# matrix section). Layout: surface -> {role: expected_decision}.
_ALLOW = Decision.ALLOW
_DENY = Decision.DENY
_STEP = Decision.REQUIRE_STEP_UP

EXPECTED: dict[PermissionSurface, dict[Role, Decision]] = {
    PermissionSurface.SESSION_MANAGE: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _ALLOW, Role.READ_ONLY: _ALLOW,
    },
    PermissionSurface.USER_INVITE: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.BUSINESS_SETTINGS_EDIT: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.EXTERNAL_INTEGRATION: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.WORKFLOW_TRIGGER: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.WORKFLOW_APPROVE: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.FINALIZATION: {
        Role.OWNER: _STEP, Role.ADMIN: _STEP, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.REVIEW_QUEUE_VIEW: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _ALLOW, Role.READ_ONLY: _ALLOW,
    },
    PermissionSurface.REVIEW_QUEUE_RESOLVE: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.REVIEW_ASSIGN: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.REVIEW_REGENERATE: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _DENY, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.REPORT_EXPORT_BASIC: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.REPORT_EXPORT_FULL: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _DENY,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _DENY, Role.READ_ONLY: _DENY,
    },
    PermissionSurface.DASHBOARD_VIEW: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _ALLOW, Role.READ_ONLY: _ALLOW,
    },
    PermissionSurface.DASHBOARD_REFRESH_MANUAL: {
        Role.OWNER: _ALLOW, Role.ADMIN: _ALLOW, Role.BOOKKEEPER: _ALLOW,
        Role.ACCOUNTANT: _ALLOW, Role.REVIEWER: _ALLOW, Role.READ_ONLY: _ALLOW,
    },
}


def test_matrix_is_complete() -> None:
    assert_matrix_complete()


def test_matrix_covers_every_surface() -> None:
    """Every PermissionSurface enum value is represented in EXPECTED."""
    assert set(EXPECTED.keys()) == set(PermissionSurface), (
        f"test fixture EXPECTED missing surfaces: "
        f"{set(PermissionSurface) - set(EXPECTED.keys())}"
    )


@pytest.mark.parametrize(
    ("role", "surface", "decision"),
    [
        (role, surface, decision)
        for surface, by_role in EXPECTED.items()
        for role, decision in by_role.items()
    ],
)
def test_matrix_cell(role: Role, surface: PermissionSurface, decision: Decision) -> None:
    assert PERMISSION_MATRIX[(role, surface)] is decision


def test_matrix_can_be_printed() -> None:
    """DoD: 'The permission matrix can be printed as a clean table.'"""
    table = matrix_as_table()
    assert "| Surface |" in table
    for surface in PermissionSurface:
        assert surface.value in table
    for role in Role:
        assert role.value in table
