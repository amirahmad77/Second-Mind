"""Search router. iOS hits Supabase RPC directly normally; this exists for
backend parity, debugging, and future server-side query rewriting."""
from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException

from app.config import Settings
from app.deps import get_gemini, get_supabase, settings_dep
from app.models.atom import AtomCandidate
from app.models.search import SearchRequest, SearchResponse
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient

router = APIRouter(prefix="/v1", tags=["search"])


@router.post("/search", response_model=SearchResponse)
async def search(
    req: SearchRequest,
    settings: Settings = Depends(settings_dep),
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> SearchResponse:
    try:
        vec = await gemini.embed(
            req.query,
            task_type="RETRIEVAL_QUERY",
            output_dim=settings.embed_dim,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc

    rows = await supabase.semantic_search_full(
        user_id=req.user_id,
        query_vector=vec,
        query_text=req.query,
        match_count=req.limit,
    )
    return SearchResponse(
        query=req.query,
        hits=[AtomCandidate.model_validate(r) for r in rows],
        decay_lambda_year=settings.decay_lambda_year,
        backlink_threshold=settings.backlink_threshold,
    )
