from __future__ import annotations

import os
from collections.abc import Iterator

import pytest

# Inject minimal env so Settings() validates during import.
os.environ.setdefault("SUPABASE_URL", "https://test.supabase.co")
os.environ.setdefault("SUPABASE_ANON_KEY", "test-anon")
os.environ.setdefault("GEMINI_API_KEY", "test-key")


@pytest.fixture
def settings() -> Iterator[object]:
    from app.config import get_settings

    get_settings.cache_clear()  # type: ignore[attr-defined]
    yield get_settings()
    get_settings.cache_clear()  # type: ignore[attr-defined]
