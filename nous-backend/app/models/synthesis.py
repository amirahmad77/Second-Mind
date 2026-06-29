from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, Field


class SynthesisRequest(BaseModel):
    user_id: UUID
    question: str = Field(min_length=1, max_length=4000)
    context_limit: int = Field(default=12, ge=1, le=40)
    include_recent: bool = Field(
        default=True,
        description="If true, also surface recent atoms (last 7d) regardless of similarity score.",
    )


class PushbackRequest(BaseModel):
    user_id: UUID
    since_days: int = Field(default=14, ge=1, le=180)
    max_atoms: int = Field(default=30, ge=5, le=120)
