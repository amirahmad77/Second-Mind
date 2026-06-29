"""Pydantic models for the web-capture extension surface."""
from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field


# ─── Capture ────────────────────────────────────────────────────────────

class SourceMeta(BaseModel):
    """Origin metadata attached to each captured atom. Stored verbatim in the
    event payload under `source` so iOS can render a source chip."""
    kind: Literal["web", "meet"]
    url: str | None = None
    domain: str | None = None
    title: str | None = None
    meta_description: str | None = Field(default=None, alias="metaDescription")

    # Meet-specific
    meet_id: str | None = Field(default=None, alias="meetID")
    participants: list[str] = Field(default_factory=list)
    started_at: datetime | None = Field(default=None, alias="startedAt")
    ended_at: datetime | None = Field(default=None, alias="endedAt")

    model_config = {"populate_by_name": True}


class TranscriptSegment(BaseModel):
    """Single speaker turn from Meet captions or audio STT."""
    speaker: str | None = None
    text: str
    at: datetime | None = None  # captured-at relative to the session


class CaptureRequest(BaseModel):
    source: SourceMeta
    # For web: `text` is the user's selection (or page summary if no selection).
    # For meet: `text` is ignored; `segments` is the authoritative transcript.
    text: str | None = None
    segments: list[TranscriptSegment] = Field(default_factory=list)

    # Optional client hint — extension marks each page-save w/ a correlation
    # id so retries are idempotent. Not required for meet (meet_id handles it).
    client_nonce: str | None = None


class CaptureResponse(BaseModel):
    atom_id: UUID
    appended: bool  # true = appended to existing meet atom; false = new atom
    refined: bool   # true = refined synchronously; false = refined in background


# ─── Pairing ────────────────────────────────────────────────────────────

class PairStartResponse(BaseModel):
    """iOS → backend: mint a short-lived 6-digit code bound to the user."""
    code: str
    expires_at: datetime


class PairCompleteRequest(BaseModel):
    code: str
    label: str | None = None  # "Arc on MacBook" etc. shown in iOS pair list


class PairCompleteResponse(BaseModel):
    token: str
    user_id: UUID


# ─── STT (tab audio fallback) ───────────────────────────────────────────

class STTRequest(BaseModel):
    """Audio chunk upload from the Meet content script when captions are off.
    Audio sent as base64 webm/opus, 16kHz mono, ~15-30s per chunk."""
    meet_id: str = Field(alias="meetID")
    chunk_started_at: datetime = Field(alias="chunkStartedAt")
    audio_base64: str = Field(alias="audioBase64")
    mime: str = "audio/webm"

    model_config = {"populate_by_name": True}


class STTResponse(BaseModel):
    segments: list[TranscriptSegment]
