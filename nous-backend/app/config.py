"""Runtime configuration loaded from environment variables."""
from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Backend settings. All overridable via env vars or .env file."""

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=False,
    )

    # ── Service ──────────────────────────────────────────────
    service_name: str = "nous-backend"
    environment: str = Field(default="dev", description="dev | staging | prod")
    log_level: str = "INFO"

    # ── HTTP ─────────────────────────────────────────────────
    cors_allow_origins: list[str] = Field(
        default_factory=lambda: ["*"],
        description="CORS origins. Tighten in prod.",
    )
    request_timeout_seconds: float = 30.0

    # ── Supabase (PostgREST) ─────────────────────────────────
    supabase_url: str = Field(..., description="https://<ref>.supabase.co")
    supabase_anon_key: str = Field(..., description="anon JWT")
    supabase_service_role_key: str | None = Field(
        default=None,
        description="Optional. Bypasses RLS for backend admin ops. Keep secret.",
    )

    # ── Gemini ───────────────────────────────────────────────
    gemini_api_key: str = Field(..., description="generativelanguage API key")
    gemini_embed_model: str = "gemini-embedding-001"
    gemini_chat_model: str = "gemini-2.5-flash"
    embed_dim: int = 768

    # ── Ranking (PRD §4) ─────────────────────────────────────
    decay_lambda_year: float = Field(
        default=0.21072,
        description="ln(1/0.9)/0.5 ≈ ~10% decay / 6 months. Tunable via env.",
    )
    backlink_threshold: int = 3
    semantic_search_default_limit: int = 12

    # ── Synthesis ────────────────────────────────────────────
    synthesis_max_context_atoms: int = 12
    synthesis_max_tokens: int = 1024
    synthesis_temperature: float = 0.4

    # ── Pushback ─────────────────────────────────────────────
    pushback_recent_window_days: int = 14
    pushback_max_atoms: int = 30
    pushback_max_tokens: int = 600
    pushback_temperature: float = 0.5


@lru_cache
def get_settings() -> Settings:
    """Cached settings instance. Treat as a singleton."""
    return Settings()  # type: ignore[call-arg]
