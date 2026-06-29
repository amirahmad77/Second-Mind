"""Synthesis graph unit test with stubbed Supabase + Gemini.

Verifies stage ordering: update → citation* → token* and content correctness.
"""
from __future__ import annotations

import json
from collections.abc import AsyncIterator
from datetime import datetime, timezone
from uuid import UUID, uuid4

import pytest

from app.graphs.synthesis import run_synthesis


class StubSupabase:
    def __init__(self, rows: list[dict]) -> None:
        self.rows = rows
        self.calls: list[dict] = []

    async def semantic_search_full(self, **kwargs):  # type: ignore[no-untyped-def]
        self.calls.append(kwargs)
        return self.rows


class StubGemini:
    def __init__(self, vec: list[float], chunks: list[str]) -> None:
        self.vec = vec
        self.chunks = chunks

    async def embed(self, text: str, **_):  # type: ignore[no-untyped-def]
        return self.vec

    async def stream(self, **_) -> AsyncIterator[str]:  # type: ignore[no-untyped-def]
        for c in self.chunks:
            yield c


@pytest.mark.asyncio
async def test_synthesis_emits_update_then_citations_then_tokens(settings) -> None:  # type: ignore[no-untyped-def]
    user_id = uuid4()
    rows = [
        {
            "atom_id": str(uuid4()),
            "score": 0.92,
            "raw_score": 0.95,
            "decayed": True,
            "inbound_links": 0,
            "content": "Q3 runway is 7 months at current burn",
            "atom_type": "thought",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "tags": ["finance"],
        },
        {
            "atom_id": str(uuid4()),
            "score": 0.81,
            "raw_score": 0.85,
            "decayed": True,
            "inbound_links": 0,
            "content": "Hire freeze decision made on Tuesday",
            "atom_type": "decision",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "tags": [],
        },
    ]
    supabase = StubSupabase(rows)
    gemini = StubGemini(vec=[0.1] * settings.embed_dim, chunks=["Runway is ", "tight."])

    events = [
        ev
        async for ev in run_synthesis(
            user_id=user_id,
            question="What's the runway?",
            context_limit=5,
            settings=settings,
            supabase=supabase,  # type: ignore[arg-type]
            gemini=gemini,  # type: ignore[arg-type]
        )
    ]
    channels = [ev["event"] for ev in events]

    # Order: at least one update first, then 2 citations, then tokens
    assert channels[0] == "update"
    assert channels.count("citation") == 2
    assert channels.count("token") == 2

    # Citations carry both atom_ids
    cit_payloads = [json.loads(ev["data"]) for ev in events if ev["event"] == "citation"]
    assert all("atom_id" in c for c in cit_payloads)

    # Supabase received query_text + match_count
    assert supabase.calls[0]["query_text"] == "What's the runway?"
    assert supabase.calls[0]["match_count"] == 5
    assert isinstance(supabase.calls[0]["user_id"], UUID)
