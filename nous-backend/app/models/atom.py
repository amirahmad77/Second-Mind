"""Domain types — mirror iOS AtomSnapshot / NoteEvent shape."""
from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class AtomCandidate(BaseModel):
    """One row from semantic_search_full RPC."""

    model_config = ConfigDict(populate_by_name=True)

    atom_id: UUID
    score: float
    raw_score: float
    decayed: bool
    inbound_links: int
    content: str
    atom_type: str = Field(default="thought")
    created_at: datetime
    tags: list[str] = Field(default_factory=list)


class AtomSummary(BaseModel):
    """Lighter projection used in pushback / recent listings."""

    atom_id: UUID
    content: str
    atom_type: str = "thought"
    created_at: datetime
    tags: list[str] = Field(default_factory=list)
