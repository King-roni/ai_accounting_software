"""Error types raised by ``ai_integrations``.

``ModelError`` carries the ``transient`` flag B03·P08 consumes for retry policy.
``BypassAttemptBlockedError`` is the runtime half of bypass detection.
``SecretMissingError`` distinguishes "API key not provisioned in
``secrets.managed_secrets``" from other transport failures.
"""

from __future__ import annotations


class ModelError(Exception):
    """Maps HTTP / transport failures to the canonical MODEL_ERROR shape.

    Mirrors the AIResult MODEL_ERROR variant returned by the gateway in
    B06·P02. ``transient=True`` is the signal to B03·P08's retry policy that a
    retry could plausibly succeed.
    """

    __slots__ = ("transient", "code", "http_status", "message")

    def __init__(
        self,
        *,
        transient: bool,
        code: str,
        http_status: int | None,
        message: str,
    ) -> None:
        super().__init__(f"{code}: {message}")
        self.transient = transient
        self.code = code
        self.http_status = http_status
        self.message = message

    def to_dispatch_error_detail(self) -> dict:
        """Shape passed to ``ai_gateway_invoke_finalize`` as p_dispatch_error_detail."""
        return {
            "code": self.code,
            "transient": self.transient,
            "http_status": self.http_status,
            "message": self.message,
        }


class BypassAttemptBlockedError(Exception):
    """Raised when an entry point is called with ``via_gateway=False``.

    The integration emits a TIER_3_BYPASS_ATTEMPT_BLOCKED audit event before
    raising so the bypass attempt is durable in the audit log even if the
    caller swallows the exception.
    """


class SecretMissingError(Exception):
    """Raised when ``secrets.get_secret`` returns NULL for the Anthropic API key.

    Separate from ``ModelError`` because this is a deployment configuration
    failure (the key was never provisioned, was destroyed, or vault read
    failed) — retrying the same call cannot succeed. The audit row is already
    emitted by ``secrets.get_secret`` (SECRET_ACCESS_DENIED / SECRET_ACCESS_FAILED).
    """
