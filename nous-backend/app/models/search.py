from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, Field

from app.models.atom import AtomCandidate


class SearchRequest(BaseModel):
    user_id: UUID
    query: str = Field(min_length=1, max_length=1024)
    limit: int = Field(default=20, ge=1, le=100)


class SearchResponse(BaseModel):
    query: str
    hits: list[AtomCandidate]
    decay_lambda_year: float
    backlink_threshold: int
