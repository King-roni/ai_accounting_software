"""SecureClient — httpx wrapper that enforces the project's outbound HTTP policy.

Every outbound HTTP call from the API must go through SecureClient (or an
equivalent layer that wraps SecureClient) so the no-plaintext-fallback rule
and SPKI pinning are uniformly enforced.

Pin verification is done by opening a *separate* TLS connection to the host
(once per (host, port) tuple, cached for the lifetime of the SecureClient) and
checking the peer's SPKI fingerprint against the configured PinSet. The
verified handshake's result is cached; subsequent requests to the same host
reuse the cached verdict. A cache TTL keeps long-lived clients honest.

This is the simplest correct shape — Python's ``ssl`` module doesn't expose
a per-connection verify hook that httpx can plug into, and the cert-chain
inspection during httpx's own handshake is implementation-specific. Doing
the pin check ourselves is more robust to httpx version changes.
"""

from __future__ import annotations

import socket
import ssl
import time
from dataclasses import dataclass
from typing import Mapping
from urllib.parse import urlsplit

import httpx

from .pinning import (
    DEFAULT_PIN_MAP,
    PinMismatchError,
    PinSet,
    PlaintextBlockedError,
    find_pin_set,
    spki_fingerprint_from_der,
)

DEFAULT_PIN_CACHE_TTL_SECONDS = 60.0
DEFAULT_HANDSHAKE_TIMEOUT_SECONDS = 10.0


class SecureClientError(RuntimeError):
    """Base for all SecureClient-specific failures."""


@dataclass
class _PinCacheEntry:
    verified_at: float
    fingerprint: str


class SecureClient:
    """A thin wrapper around ``httpx.Client``.

    Usage::

        from cyprus_bookkeeping_api.secure_http import SecureClient
        with SecureClient() as client:
            r = client.get("https://api.anthropic.com/...")

    Calling with an http:// URL raises ``PlaintextBlockedError``. Calling
    a pinned host whose live SPKI doesn't match raises ``PinMismatchError``.
    """

    def __init__(
        self,
        *,
        pins: Mapping[str, PinSet] = DEFAULT_PIN_MAP,
        cache_ttl: float = DEFAULT_PIN_CACHE_TTL_SECONDS,
        handshake_timeout: float = DEFAULT_HANDSHAKE_TIMEOUT_SECONDS,
        httpx_client: httpx.Client | None = None,
    ) -> None:
        self._pins = pins
        self._cache_ttl = cache_ttl
        self._handshake_timeout = handshake_timeout
        self._pin_cache: dict[tuple[str, int], _PinCacheEntry] = {}
        self._client = httpx_client or httpx.Client(timeout=30.0)
        self._owns_client = httpx_client is None

    # ---- request entry points ------------------------------------------

    def get(self, url: str, **kwargs) -> httpx.Response:
        return self._dispatch("GET", url, **kwargs)

    def post(self, url: str, **kwargs) -> httpx.Response:
        return self._dispatch("POST", url, **kwargs)

    def put(self, url: str, **kwargs) -> httpx.Response:
        return self._dispatch("PUT", url, **kwargs)

    def patch(self, url: str, **kwargs) -> httpx.Response:
        return self._dispatch("PATCH", url, **kwargs)

    def delete(self, url: str, **kwargs) -> httpx.Response:
        return self._dispatch("DELETE", url, **kwargs)

    def request(self, method: str, url: str, **kwargs) -> httpx.Response:
        return self._dispatch(method, url, **kwargs)

    # ---- internals -----------------------------------------------------

    def _dispatch(self, method: str, url: str, **kwargs) -> httpx.Response:
        self._guard_scheme(url)
        self._verify_pinned_host(url)
        return self._client.request(method, url, **kwargs)

    @staticmethod
    def _guard_scheme(url: str) -> None:
        parts = urlsplit(url)
        if parts.scheme != "https":
            raise PlaintextBlockedError(
                f"plaintext outbound blocked: {url!r} (scheme={parts.scheme!r}); only https is permitted"
            )

    def _verify_pinned_host(self, url: str) -> None:
        parts = urlsplit(url)
        host = parts.hostname or ""
        port = parts.port or 443
        pin_set = find_pin_set(host, self._pins)
        if pin_set is None:
            return  # not pinned; ordinary TLS chain verification applies

        cache_key = (host, port)
        cached = self._pin_cache.get(cache_key)
        now = time.monotonic()
        if cached is not None and (now - cached.verified_at) < self._cache_ttl:
            if pin_set.matches(cached.fingerprint):
                return
            self._pin_cache.pop(cache_key, None)

        live_fp = self._fetch_live_spki(host, port)
        if not pin_set.matches(live_fp):
            raise PinMismatchError(
                f"SPKI pin mismatch for {host}: live fingerprint {live_fp} "
                f"not in configured set ({len(pin_set.fingerprints)} pins). "
                f"Either the cert was rotated and the pin set needs updating, "
                f"or the connection is being intercepted."
            )
        self._pin_cache[cache_key] = _PinCacheEntry(verified_at=now, fingerprint=live_fp)

    def _fetch_live_spki(self, host: str, port: int) -> str:
        ctx = ssl.create_default_context()
        ctx.minimum_version = ssl.TLSVersion.TLSv1_3
        with socket.create_connection((host, port), timeout=self._handshake_timeout) as sock:
            with ctx.wrap_socket(sock, server_hostname=host) as ssock:
                der = ssock.getpeercert(binary_form=True)
                if not der:
                    raise SecureClientError(f"no peer cert returned for {host}:{port}")
                return spki_fingerprint_from_der(der)

    # ---- context-manager / lifecycle ----------------------------------

    def close(self) -> None:
        if self._owns_client:
            self._client.close()

    def __enter__(self) -> "SecureClient":
        return self

    def __exit__(self, *exc_info: object) -> None:
        self.close()
