from __future__ import annotations

from fastapi import APIRouter, Depends

from app.config import Settings
from app.deps import get_gemini, get_supabase, settings_dep
from app.graphs.suggest_links import run_suggest_links
from app.models.links import SuggestLinksRequest, SuggestLinksResponse
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient

router = APIRouter(prefix="/v1", tags=["links"])


@router.post("/suggest-links", response_model=SuggestLinksResponse)
async def suggest_links(
    req: SuggestLinksRequest,
    settings: Settings = Depends(settings_dep),
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> SuggestLinksResponse:
    suggestions, candidate_count = await run_suggest_links(
        user_id=req.user_id,
        source_atom_id=req.atom_id,
        source_text=req.text,
        candidate_pool=req.candidate_pool,
        max_picks=req.max_picks,
        settings=settings,
        supabase=supabase,
        gemini=gemini,
    )
    return SuggestLinksResponse(
        source_atom_id=req.atom_id,
        suggestions=suggestions,
        candidate_count=candidate_count,
    )
