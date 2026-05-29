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


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
