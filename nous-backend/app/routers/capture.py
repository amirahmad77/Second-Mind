"""Chrome-extension capture surface.

Endpoints:
    POST /v1/capture          — web clip OR meet transcript batch
    POST /v1/pair/start       — iOS mints a 6-digit code bound to its user_id
    POST /v1/pair/complete    — extension trades the code for a long-lived token
    POST /v1/stt              — audio chunk transcription (captions-off fallback)
    GET  /v1/meet/active      — iOS polls for actively-recording Meet sessions

Auth model (v1, single-user):
    - iOS app: passes its `user_id` in request bodies (matches the rest of the app).
    - Chrome extension: `Authorization: Bearer <extension_token>` — token is minted
      by /v1/pair/complete and stored in chrome.storage. The token resolves to a
      user_id server-side, so the extension never needs to know its own user_id.
"""
from __future__ import annotations

import base64
import hashlib
import json
import re
import time
from datetime import datetime, timezone
from typing import Annotated
from uuid import UUID, uuid4

from fastapi import APIRouter, Depends, Header, HTTPException, status
from pydantic import BaseModel

from app.deps import get_gemini, get_supabase
from app.graphs.refine_meet import refine_meet_session
from app.graphs.refine_web import refine_web_clip
from app.services import crawler as page_crawler
from app.logging import get_logger
from app.models.capture import (
    CaptureRequest,
    CaptureResponse,
    PairCompleteRequest,
    PairCompleteResponse,
    PairStartResponse,
    STTRequest,
    STTResponse,
    TranscriptSegment,
)
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient

log = get_logger(__name__)
router = APIRouter(prefix="/v1", tags=["capture"])

# ─── Active Meet sessions (in-memory, per-process) ───────────────────────
# Keyed by (user_id_str, meet_id). Auto-expires after 10 min of silence.
# FastAPI/uvicorn is single-threaded async so plain dict ops between awaits
# are race-free.

_MEET_EXPIRY_SECONDS = 600

# { (user_id_str, meet_id): {user_id, meet_id, participants, started_at, last_seen, segment_count} }
_active_meets: dict[tuple[str, str], dict] = {}

# Idempotency: fingerprints of recently-applied transcript batches per meet, so a
# retried POST (backend committed but the client lost the response) can't insert
# the same turns twice. Each flush ships a disjoint batch, so an identical
# non-empty fingerprint can only mean a retry. Bounded; cleared on session end.
_MEET_FP_CAP = 64
_meet_batch_fps: dict[tuple[str, str], list[str]] = {}


def _batch_fingerprint(segments: list[TranscriptSegment]) -> str:
    payload = [[s.speaker or "", s.text, s.at.isoformat() if s.at else ""] for s in segments]
    return hashlib.sha1(json.dumps(payload, separators=(",", ":")).encode()).hexdigest()


def _seen_batch(user_id: UUID, meet_id: str, fp: str) -> bool:
    return fp in _meet_batch_fps.get((str(user_id), meet_id), [])


def _remember_batch(user_id: UUID, meet_id: str, fp: str) -> None:
    key = (str(user_id), meet_id)
    fps = _meet_batch_fps.setdefault(key, [])
    fps.append(fp)
    if len(fps) > _MEET_FP_CAP:
        del fps[: len(fps) - _MEET_FP_CAP]


def _register_meet(user_id: UUID, meet_id: str, participants: list[str],
                   started_at: datetime | None, segment_count: int) -> None:
    key = (str(user_id), meet_id)
    existing = _active_meets.get(key, {})
    _active_meets[key] = {
        "user_id": str(user_id),
        "meet_id": meet_id,
        "participants": participants or existing.get("participants", []),
        "started_at": existing.get("started_at") or (started_at.isoformat() if started_at else None),
        "last_seen": time.monotonic(),
        "segment_count": existing.get("segment_count", 0) + segment_count,
    }


def _clear_meet(user_id: UUID, meet_id: str) -> None:
    _active_meets.pop((str(user_id), meet_id), None)
    _meet_batch_fps.pop((str(user_id), meet_id), None)


def _get_active_meets(user_id: UUID) -> list[dict]:
    now = time.monotonic()
    stale = [k for k, v in _active_meets.items() if now - v["last_seen"] > _MEET_EXPIRY_SECONDS]
    for k in stale:
        del _active_meets[k]
    uid = str(user_id)
    return [v for k, v in _active_meets.items() if k[0] == uid]


# ─── Auth ───────────────────────────────────────────────────────────────

async def _user_from_token(
    authorization: Annotated[str | None, Header()],
    supabase: SupabaseClient,
) -> UUID:
    if not authorization or not authorization.lower().startswith("bearer "):
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "missing bearer token")
    token = authorization.split(None, 1)[1].strip()
    user_id = await supabase.validate_extension_token(token=token)
    if user_id is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "invalid or revoked token")
    return user_id


# ─── Pairing ────────────────────────────────────────────────────────────

class PairStartRequest(BaseModel):
    """iOS → backend. In v1 the client passes its own user_id (matches the rest
    of the app). Tighten when real auth lands."""
    user_id: UUID


@router.post("/pair/start", response_model=PairStartResponse)
async def pair_start(
    req: PairStartRequest,
    supabase: SupabaseClient = Depends(get_supabase),
) -> PairStartResponse:
    code, expires = await supabase.mint_pairing_code(user_id=req.user_id)
    log.info("pairing_code_minted", user_id=str(req.user_id))
    return PairStartResponse(code=code, expires_at=expires)


@router.post("/pair/complete", response_model=PairCompleteResponse)
async def pair_complete(
    req: PairCompleteRequest,
    supabase: SupabaseClient = Depends(get_supabase),
) -> PairCompleteResponse:
    user_id = await supabase.consume_pairing_code(code=req.code)
    if user_id is None:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "invalid or expired code")
    token = await supabase.create_extension_token(user_id=user_id, label=req.label)
    log.info("extension_paired", user_id=str(user_id), label=req.label)
    return PairCompleteResponse(token=token, user_id=user_id)


# ─── Capture ────────────────────────────────────────────────────────────

def _source_payload(req: CaptureRequest) -> dict:
    s = req.source
    out: dict = {"kind": s.kind}
    if s.url:
        out["url"] = s.url
    if s.domain:
        out["domain"] = s.domain
    if s.title:
        out["title"] = s.title
    if s.meta_description:
        out["metaDescription"] = s.meta_description
    if s.meet_id:
        out["meetID"] = s.meet_id
    if s.participants:
        out["participants"] = s.participants
    if s.started_at:
        out["startedAt"] = s.started_at.isoformat()
    if s.ended_at:
        out["endedAt"] = s.ended_at.isoformat()
    return out


async def _embed_and_store(
    *,
    atom_id: UUID,
    user_id: UUID,
    text: str,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> None:
    try:
        vec = await gemini.embed(text, task_type="SEMANTIC_SIMILARITY")
        await supabase.upsert_embedding(atom_id=atom_id, user_id=user_id, vector=vec)
    except Exception as exc:  # noqa: BLE001
        log.warning("embed_failed", atom_id=str(atom_id), err=str(exc)[:200])


@router.post("/capture", response_model=CaptureResponse)
async def capture(
    req: CaptureRequest,
    authorization: Annotated[str | None, Header()] = None,
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> CaptureResponse:
    user_id = await _user_from_token(authorization, supabase)
    source = req.source

    if source.kind == "web":
        return await _capture_web(req, user_id, supabase, gemini)
    if source.kind == "meet":
        return await _capture_meet(req, user_id, supabase, gemini)
    raise HTTPException(status.HTTP_400_BAD_REQUEST, f"unknown source.kind={source.kind}")


def _is_sparse_clip(selection: str) -> bool:
    """True when the saved clip has no meaningful user-selected text.

    Sparse clips are bare-link saves ("[link] URL", "[page] Title") or
    very short selections (< 120 chars) where page content would give the
    refiner substantially more signal than the stub alone.
    """
    s = selection.strip()
    return (
        s.startswith("[link] ")
        or s.startswith("[page] ")
        or s.startswith("http://")
        or s.startswith("https://")
        or len(s) < 120
    )


async def _capture_web(
    req: CaptureRequest,
    user_id: UUID,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> CaptureResponse:
    selection = (req.text or "").strip()
    if len(selection) < 3:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "selection is empty")

    atom_id = uuid4()
    source_payload = _source_payload(req)

    # 1. Created event with raw selection so iOS mirrors see it immediately.
    await supabase.insert_event(
        atom_id=atom_id,
        user_id=user_id,
        kind="created",
        payload={
            "content": selection,
            "source": source_payload,
            # Atom type must match the client's AtomType enum — a web clip is a
            # reference. (Provenance lives in source.kind="web".)
            "type": "reference",
            "createdAt": datetime.now(timezone.utc).isoformat(),
            "clientNonce": req.client_nonce,
        },
    )

    # 2. For sparse clips (bare links, short stubs), crawl the page so the
    #    refiner has real content to work with rather than just a URL stub.
    crawled_markdown: str | None = None
    if _is_sparse_clip(selection) and req.source.url:
        crawled = await page_crawler.crawl(req.source.url, timeout=10.0)
        if crawled:
            crawled_markdown = crawled.markdown
            log.info(
                "page_crawled",
                url=req.source.url,
                chars=len(crawled_markdown),
                atom_id=str(atom_id),
            )

    refined_ok = False
    try:
        refined = await refine_web_clip(
            selection=selection,
            title=req.source.title,
            url=req.source.url,
            domain=req.source.domain,
            meta_description=req.source.meta_description,
            crawled_markdown=crawled_markdown,
            gemini=gemini,
        )
        refined = refined.strip()
        if refined:
            await supabase.insert_event(
                atom_id=atom_id,
                user_id=user_id,
                kind="refined",
                payload={"refinedContent": refined, "source": source_payload},
            )
            await _embed_and_store(
                atom_id=atom_id,
                user_id=user_id,
                text=refined,
                supabase=supabase,
                gemini=gemini,
            )
            refined_ok = True
    except Exception as exc:  # noqa: BLE001
        log.warning("refine_web_failed", atom_id=str(atom_id), err=str(exc)[:200])

    if not refined_ok:
        # Still embed the raw selection so search works.
        await _embed_and_store(
            atom_id=atom_id, user_id=user_id, text=selection, supabase=supabase, gemini=gemini
        )

    return CaptureResponse(atom_id=atom_id, appended=False, refined=refined_ok)


async def _capture_meet(
    req: CaptureRequest,
    user_id: UUID,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> CaptureResponse:
    meet_id = req.source.meet_id
    if not meet_id:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "meet source requires meetID")

    is_final = req.source.ended_at is not None
    # Interim batches must carry segments; the final flush is allowed to be empty
    # (the last window may have had no captions) — it still closes out the atom
    # by re-refining + embedding the cumulative transcript.
    if not req.segments and not is_final:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "meet capture requires segments")

    existing = await supabase.find_meet_atom(user_id=user_id, meet_id=meet_id)
    appended = existing is not None
    atom_id = existing or uuid4()
    source_payload = _source_payload(req)

    # A final flush with no new segments and no prior atom is a no-op (a meeting
    # that never produced a single caption) — nothing to store or refine.
    if not appended and not req.segments:
        return CaptureResponse(atom_id=atom_id, appended=False, refined=False)

    # Idempotency: a retried non-empty batch (same turns) is dropped so the
    # transcript can't gain duplicate turns when a client retries after a lost
    # response.
    if req.segments:
        fp = _batch_fingerprint(req.segments)
        if _seen_batch(user_id, meet_id, fp):
            log.info("meet_batch_duplicate_skipped", atom_id=str(atom_id), fp=fp[:12])
            return CaptureResponse(atom_id=atom_id, appended=appended, refined=False)
    else:
        fp = None

    # Track live session state. Final flush (endedAt set) clears it.
    if is_final:
        _clear_meet(user_id, meet_id)
    else:
        _register_meet(user_id, meet_id, req.source.participants,
                       req.source.started_at, len(req.segments))

    segment_dicts = [s.model_dump(mode="json") for s in req.segments]

    if not appended:
        # First write for this meetID — seed the atom with a `created` event so
        # the meet-lookup index can find it on next append.
        await supabase.insert_event(
            atom_id=atom_id,
            user_id=user_id,
            kind="created",
            payload={
                "content": _segments_plain(req.segments),
                "segments": segment_dicts,
                "source": source_payload,
                # Must match the client's AtomType enum (case `meeting`), not the
                # source kind "meet" — otherwise the atom decodes to `.thought`.
                "type": "meeting",
                "createdAt": datetime.now(timezone.utc).isoformat(),
            },
        )
    elif req.segments:
        # Append raw transcript batch — refiner re-synthesizes below. Skipped for
        # an empty final flush (no new turns to persist).
        await supabase.insert_event(
            atom_id=atom_id,
            user_id=user_id,
            kind="updatedRaw",
            payload={"segments": segment_dicts, "source": source_payload},
        )

    # Mark this batch applied so an identical retry is ignored (above).
    if fp is not None:
        _remember_batch(user_id, meet_id, fp)

    # Refine over the CUMULATIVE transcript (all batches so far), not just this
    # batch. The `refined` reducer keeps only the latest event, so each refine
    # must regenerate a complete body — re-refining a single trailing batch would
    # overwrite the full summary with a sparse (often heading-only) stub.
    #
    # Embedding only happens on the final flush: interim embeds are pure waste
    # (each is immediately superseded by the next batch's refine).
    refined_ok = False
    try:
        all_segments = await supabase.fetch_meet_segments(atom_id=atom_id, user_id=user_id)
        segments = [TranscriptSegment(**s) for s in all_segments]
        if segments:
            refined = (await refine_meet_session(
                segments=segments,
                user_display_name=None,
                participants=req.source.participants,
                meet_id=meet_id,
                is_append=False,
                gemini=gemini,
            )).strip()
            if _has_body(refined):
                await supabase.insert_event(
                    atom_id=atom_id,
                    user_id=user_id,
                    kind="refined",
                    payload={"refinedContent": refined, "source": source_payload},
                )
                if is_final:
                    await _embed_and_store(
                        atom_id=atom_id,
                        user_id=user_id,
                        text=refined,
                        supabase=supabase,
                        gemini=gemini,
                    )
                refined_ok = True
            else:
                log.info("refine_meet_skipped_empty", atom_id=str(atom_id),
                         chars=len(refined))
    except Exception as exc:  # noqa: BLE001
        log.warning("refine_meet_failed", atom_id=str(atom_id), err=str(exc)[:200])

    return CaptureResponse(atom_id=atom_id, appended=appended, refined=refined_ok)


def _has_body(refined: str) -> bool:
    """True when the refined markdown has real content beyond headings/blank
    lines. Guards against the refiner emitting a bare `## session <date>` stub,
    which would otherwise replace a good summary with an empty-looking atom."""
    for line in refined.splitlines():
        s = line.strip()
        if s and not s.startswith("#"):
            return True
    return False


def _segments_plain(segments: list[TranscriptSegment]) -> str:
    lines = []
    for s in segments:
        sp = s.speaker or "speaker"
        lines.append(f"{sp}: {s.text}")
    return "\n".join(lines)


# ─── Active Meet status (iOS polling) ───────────────────────────────────

class ActiveMeetSession(BaseModel):
    meet_id: str
    participants: list[str]
    started_at: str | None
    segment_count: int


class ActiveMeetsResponse(BaseModel):
    sessions: list[ActiveMeetSession]


@router.get("/meet/active", response_model=ActiveMeetsResponse)
async def meet_active(user_id: UUID) -> ActiveMeetsResponse:
    sessions = _get_active_meets(user_id)
    return ActiveMeetsResponse(sessions=[
        ActiveMeetSession(
            meet_id=s["meet_id"],
            participants=s.get("participants") or [],
            started_at=s.get("started_at"),
            segment_count=s.get("segment_count", 0),
        )
        for s in sessions
    ])


# ─── STT (captions-off fallback) ────────────────────────────────────────

_SPEAKER_RE = re.compile(r"^\s*(speaker\s*\d+|[A-Z][\w .'-]{0,40})\s*:\s*(.+)$", re.IGNORECASE)


def _split_transcript(text: str, started_at: datetime) -> list[TranscriptSegment]:
    """Split Gemini transcript output into segments. Each `Speaker N:` line
    becomes its own segment; unlabeled text falls into a single speakerless
    segment. Timestamp is clamped to the chunk start — we don't have word-level
    timing."""
    segments: list[TranscriptSegment] = []
    current_speaker: str | None = None
    buffer: list[str] = []

    def _flush() -> None:
        if not buffer:
            return
        body = " ".join(buffer).strip()
        if body:
            segments.append(TranscriptSegment(speaker=current_speaker, text=body, at=started_at))
        buffer.clear()

    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        m = _SPEAKER_RE.match(line)
        if m:
            _flush()
            current_speaker = m.group(1).strip()
            buffer.append(m.group(2).strip())
        else:
            buffer.append(line)
    _flush()
    return segments


@router.post("/stt", response_model=STTResponse)
async def stt(
    req: STTRequest,
    authorization: Annotated[str | None, Header()] = None,
    supabase: SupabaseClient = Depends(get_supabase),
    gemini: GeminiClient = Depends(get_gemini),
) -> STTResponse:
    await _user_from_token(authorization, supabase)
    try:
        audio = base64.b64decode(req.audio_base64, validate=True)
    except Exception as exc:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, f"bad base64: {exc}")
    if not audio:
        raise HTTPException(status.HTTP_400_BAD_REQUEST, "empty audio")

    text = await gemini.transcribe_audio(audio_bytes=audio, mime=req.mime)
    segments = _split_transcript(text, req.chunk_started_at)
    return STTResponse(segments=segments)
