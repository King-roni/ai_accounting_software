"""Runtime configuration sourced from environment variables.

Stage 7-2 baseline. Keeps secrets and project identifiers in one place so
every other module reads from ``settings``.
"""
from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
        extra="ignore",
    )

    # --- Supabase ---
    supabase_url: str = Field(
        default="https://noxvmnxrqlzsdfngfiww.supabase.co",
        description="HTTPS URL of the Supabase project.",
    )
    supabase_publishable_key: str = Field(
        default="",
        description="Publishable / anon key. Safe for client use; required for JWT issuer URLs.",
    )
    supabase_service_role_key: str = Field(
        default="",
        description="Service-role key. SERVER-ONLY. Bypasses RLS.",
    )
    supabase_project_ref: str = Field(
        default="noxvmnxrqlzsdfngfiww",
        description="Project reference (subdomain segment).",
    )
    supabase_jwt_audience: str = Field(
        default="authenticated",
        description="JWT 'aud' claim Supabase Auth signs into user tokens.",
    )

    # --- App ---
    app_env: str = Field(default="local")
    log_level: str = Field(default="info")

    # --- Orchestrator / worker (P0.1) ---
    worker_poll_interval_seconds: float = Field(
        default=5.0,
        description="Seconds the worker sleeps between outbox/run-drive ticks.",
    )
    worker_batch_size: int = Field(
        default=10,
        description="Max runnable runs advanced per tick.",
    )
    worker_max_phase_iterations: int = Field(
        default=60,
        description="Safety bound on phases advanced in a single drive_run call.",
    )
    worker_system_actor_user_id: str = Field(
        default="",
        description=(
            "Fallback public.users id used as the actor for auto-transitions when a "
            "run carries no started_by and no principal actor (pure-system event runs)."
        ),
    )
    worker_drive_optional_phases: bool = Field(
        default=False,
        description=(
            "When false, optional phases that need external keys (evidence discovery / "
            "OCR) are skipped until P2."
        ),
    )
    worker_tick_secret: str = Field(
        default="",
        description=(
            "Shared secret for POST /internal/worker/tick (P0.4). When empty the "
            "endpoint is disabled; the default deployment runs the continuous worker "
            "and a scheduler (pg_cron+pg_net / external cron) only needs this for the "
            "serverless tick-on-demand mode."
        ),
    )

    # --- Export-generation worker (R7.1) ---
    worker_generate_exports: bool = Field(
        default=True,
        description="When true, each tick also generates claimable PENDING exports.",
    )
    worker_export_batch_size: int = Field(
        default=10,
        description="Max PENDING exports generated per tick.",
    )
    export_bucket: str = Field(
        default="export-artifacts",
        description="Private storage bucket generated export artifacts are written to.",
    )

    # --- Statement-ingestion worker (R7.2) ---
    worker_parse_statements: bool = Field(
        default=True,
        description="When true, each tick also parses claimable UPLOADED statements into transactions.",
    )
    worker_statement_batch_size: int = Field(
        default=10,
        description="Max UPLOADED statements parsed per tick.",
    )
    raw_upload_bucket: str = Field(
        default="raw-uploads",
        description="Private bucket uploaded statement/document bytes are read from.",
    )
    statement_default_currency: str = Field(
        default="EUR",
        description="Currency assumed for statement rows that don't carry one.",
    )
    statement_dedup_soft_window_days: int = Field(
        default=30,
        description="Date window for the B07 soft (probable) duplicate check.",
    )
    statement_dedup_amount_tolerance_cents: int = Field(
        default=1,
        description="Amount tolerance (cents) for the B07 soft (probable) duplicate check.",
    )

    # --- Notifications (R7.3) ---
    worker_project_notifications: bool = Field(
        default=True,
        description="When true, each tick projects notifications (review/run/export/token events).",
    )

    # --- VIES VAT validation (R7.6) ---
    worker_verify_vies: bool = Field(
        default=True,
        description="When true, each tick verifies a batch of clients' EU VAT numbers via VIES.",
    )
    worker_vies_batch_size: int = Field(
        default=25,
        description="Max client VAT numbers verified against VIES per tick.",
    )
    vies_recheck_days: int = Field(
        default=30,
        description="Re-verify a VAT number with VIES after this many days.",
    )
    vies_endpoint: str = Field(
        default="https://ec.europa.eu/taxation_customs/vies/rest-api/check-vat-number",
        description="EU VIES check-vat-number REST endpoint (public, no key).",
    )
    vies_timeout_seconds: float = Field(
        default=20.0,
        description="Per-request timeout for VIES calls.",
    )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
