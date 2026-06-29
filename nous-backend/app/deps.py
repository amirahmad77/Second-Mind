"""FastAPI dependency providers. Use as `Depends(get_supabase)` etc."""
from __future__ import annotations

from collections.abc import AsyncIterator

from fastapi import Depends, Request

from app.config import Settings, get_settings
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient


def settings_dep() -> Settings:
    return get_settings()


async def get_supabase(request: Request) -> AsyncIterator[SupabaseClient]:
    """Borrow the process-wide Supabase client (lifecycle managed in main.py)."""
    yield request.app.state.supabase


async def get_gemini(request: Request) -> AsyncIterator[GeminiClient]:
    yield request.app.state.gemini


__all__ = ["settings_dep", "get_supabase", "get_gemini", "Depends"]
