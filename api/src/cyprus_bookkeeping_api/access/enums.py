"""Closed enumerations for the role model and permission matrix.

Adding a role or surface requires a `Docs/decisions_log.md` amendment plus
synchronized changes to `Docs/sub/reference/permission_matrix.md` and
`Docs/sub/reference/permission_surface_enum.md`.
"""
from __future__ import annotations

from enum import Enum


class Role(str, Enum):
    """The six base roles. Per Stage 1, no External Auditor and no custom-role
    builder in MVP — this set is closed.

    String values are the internal canonical names. The matrix doc records
    the API/JWT-claim namespace mapping (`org:owner`, `org:viewer`, etc.);
    see `Role.from_jwt_claim`.
    """

    OWNER = "OWNER"
    ADMIN = "ADMIN"
    BOOKKEEPER = "BOOKKEEPER"
    ACCOUNTANT = "ACCOUNTANT"
    REVIEWER = "REVIEWER"
    READ_ONLY = "READ_ONLY"

    @classmethod
    def from_jwt_claim(cls, claim: str) -> "Role":
        """Parse an `org:*` JWT role claim into the internal Role enum."""
        mapping = {
            "org:owner": cls.OWNER,
            "org:admin": cls.ADMIN,
            "org:bookkeeper": cls.BOOKKEEPER,
            "org:accountant": cls.ACCOUNTANT,
            "org:viewer": cls.REVIEWER,
            "org:readonly": cls.READ_ONLY,
        }
        try:
            return mapping[claim]
        except KeyError as exc:
            raise ValueError(f"unknown JWT role claim: {claim!r}") from exc


class PermissionSurface(str, Enum):
    """The 15 action/intent-oriented permission surfaces from the canonical
    consolidated matrix. Each value is checked against the matrix to return
    a `Decision`.

    Note: `BUSINESS_ACCESS` / `BANK_ACCOUNT_ACCESS` / `DOCUMENT_VIEW` from
    the original Block 02 Phase 04 architecture are intentionally NOT here —
    they are enforced as row-level tenant filters (RLS), not as action-level
    decisions through this matrix.
    """

    SESSION_MANAGE = "SESSION_MANAGE"
    USER_INVITE = "USER_INVITE"
    BUSINESS_SETTINGS_EDIT = "BUSINESS_SETTINGS_EDIT"
    EXTERNAL_INTEGRATION = "EXTERNAL_INTEGRATION"
    WORKFLOW_TRIGGER = "WORKFLOW_TRIGGER"
    WORKFLOW_APPROVE = "WORKFLOW_APPROVE"
    FINALIZATION = "FINALIZATION"
    REVIEW_QUEUE_VIEW = "REVIEW_QUEUE_VIEW"
    REVIEW_QUEUE_RESOLVE = "REVIEW_QUEUE_RESOLVE"
    REVIEW_ASSIGN = "REVIEW_ASSIGN"
    REVIEW_REGENERATE = "REVIEW_REGENERATE"
    REPORT_EXPORT_BASIC = "REPORT_EXPORT_BASIC"
    REPORT_EXPORT_FULL = "REPORT_EXPORT_FULL"
    DASHBOARD_VIEW = "DASHBOARD_VIEW"
    DASHBOARD_REFRESH_MANUAL = "DASHBOARD_REFRESH_MANUAL"


class Decision(str, Enum):
    """The three possible outcomes returned by `can_perform`."""

    ALLOW = "ALLOW"
    DENY = "DENY"
    REQUIRE_STEP_UP = "REQUIRE_STEP_UP"


class DenyReason(str, Enum):
    """Machine-readable reasons attached to AUTH_PERMISSION_DENIED events.

    Not exposed to end users — these are for internal audit and ops only.
    """

    CROSS_TENANT_ACCESS_ATTEMPT = "CROSS_TENANT_ACCESS_ATTEMPT"
    ROLE_LACKS_SURFACE = "ROLE_LACKS_SURFACE"
    UNKNOWN_SURFACE = "UNKNOWN_SURFACE"
    USER_SUSPENDED = "USER_SUSPENDED"
