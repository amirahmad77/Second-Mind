"""Compose-from-atoms SSE endpoint.

POST /v1/compose
  body: { user_id: UUID, intent: str, atom_ids: [UUID], tone: "post"|"essay"|"outline" }
  emits SSE channels: update, token, done, error
"""
from __future__ import annotations

from typing import Literal
from uuid import UUID

from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field
from sse_starlette.sse import EventSourceResponse

from app.config import Settings
from app.deps import get_gemini, get_supabase, settings_dep
from app.graphs.compose import run_compose
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient
from app.sse import safe_stream

router = APIRouter(prefix="/v1", tags=["compose"])


class ComposeRequest(BaseModel):
    user_id: UUID
    intent: str = Field(min_length=2, max_length=400)
    atom_ids: list[UUID] = Field(min_length=1, max_length=24)
    tone: Literal["post", "essay", "outline"] = "post"


@router.post("/compose")
async def compose(
    req: ComposeRequest,
    settings: Settings = Depends(settings_dep),
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> EventSourceResponse:
    stream = run_compose(
        user_id=req.user_id,
        intent=req.intent,
        atom_ids=req.atom_ids,
        tone=req.tone,
        settings=settings,
        supabase=supabase,
        gemini=gemini,
    )
    return EventSourceResponse(safe_stream(stream), ping=15)
