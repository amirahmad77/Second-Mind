from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, Field


class SuggestLinksRequest(BaseModel):
    user_id: UUID
    atom_id: UUID = Field(..., description="Source atom; used to dedupe self + fetch text if not provided")
    text: str = Field(..., min_length=3, max_length=8000, description="Source atom's content")
    candidate_pool: int = Field(default=10, ge=3, le=20)
    max_picks: int = Field(default=3, ge=0, le=5)


class LinkSuggestion(BaseModel):
    atom_id: UUID
    reason: str = Field(default="", max_length=200)
    score: float = Field(default=0.0, ge=0.0, le=1.0)


class SuggestLinksResponse(BaseModel):
    source_atom_id: UUID
    suggestions: list[LinkSuggestion]
    candidate_count: int
