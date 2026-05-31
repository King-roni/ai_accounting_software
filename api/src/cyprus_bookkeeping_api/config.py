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


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
