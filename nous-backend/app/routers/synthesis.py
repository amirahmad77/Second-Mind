"""Synthesis (GraphRAG) + Pushback SSE endpoints."""
from __future__ import annotations

from fastapi import APIRouter, Depends
from sse_starlette.sse import EventSourceResponse

from app.config import Settings
from app.deps import get_gemini, get_supabase, settings_dep
from app.graphs.pushback import run_pushback
from app.graphs.synthesis import run_synthesis
from app.models.synthesis import PushbackRequest, SynthesisRequest
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient
from app.sse import safe_stream

router = APIRouter(prefix="/v1", tags=["synthesis"])


@router.post("/synthesize")
async def synthesize(
    req: SynthesisRequest,
    settings: Settings = Depends(settings_dep),
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> EventSourceResponse:
    """SSE stream. Channels: update, citation, token, done, error."""
    stream = run_synthesis(
        user_id=req.user_id,
        question=req.question,
        context_limit=req.context_limit,
        settings=settings,
        supabase=supabase,
        gemini=gemini,
    )
    return EventSourceResponse(
        safe_stream(stream),
        ping=15,  # heartbeat every 15s — keeps Cloud Run / proxies from idling out
    )


@router.post("/pushback")
async def pushback(
    req: PushbackRequest,
    settings: Settings = Depends(settings_dep),
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> EventSourceResponse:
    """SSE stream. JSONL items arrive on `token` channel."""
    stream = run_pushback(
        user_id=req.user_id,
        since_days=req.since_days,
        max_atoms=req.max_atoms,
        settings=settings,
        supabase=supabase,
        gemini=gemini,
    )
    return EventSourceResponse(safe_stream(stream), ping=15)
