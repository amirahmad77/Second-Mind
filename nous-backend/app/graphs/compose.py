"""Compose-from-atoms pipeline.

User picks a writing intent + an ordered list of atoms (their notes) from
their graph. Gemini drafts a short post / essay / outline grounded in those
atoms, citing each via [atom:N] inline. Same SSE shape as synthesis so iOS
can reuse the existing stream renderer.

Stages:
  1. fetch     — load each atom's refined/raw text by id from the events table
  2. format    — number them in the user-chosen order
  3. compose   — Gemini stream with strict grounding rules

Tone presets shape the SYSTEM prompt:
  - "post"   — short blog-style post, conversational
  - "essay"  — argumentative essay paragraphs
  - "outline"— bullet outline only, no prose
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from uuid import UUID

from app.config import Settings
from app.logging import get_logger
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient
from app.sse import token, update

log = get_logger(__name__)


SYSTEM_BASE = """You are NOUS Compose. Draft writing grounded in the user's
own notes (their atoms), preserving their voice.

Hard rules:
- Every claim must come from an atom in the CONTEXT block. Cite using [atom:N]
  where N is the atom's index in the block. One inline citation per claim is
  enough; don't pile them up.
- Use the user's own phrasings where they read well — don't paraphrase to the
  point of losing their voice.
- If atoms contradict each other, surface the tension explicitly rather than
  smoothing it over.
- Do NOT invent dates, names, links, or quotes.
- Do NOT add preamble ("Here's a draft of…"), closing remarks, or meta-commentary.
- Output the draft only."""

TONE_RULES = {
    "post": "Form: short blog post. 200-400 words. Conversational. One H2 heading optional.",
    "essay": "Form: argumentative essay. 3-6 paragraphs. Build a thesis. No headings.",
    "outline": "Form: bullet outline only, 5-12 items. No prose. Indent for sub-points.",
}


async def _fetch_atom_texts(
    *,
    user_id: UUID,
    atom_ids: list[UUID],
    supabase: SupabaseClient,
) -> dict[UUID, str]:
    """For each atom_id, return its latest refined or raw content."""
    out: dict[UUID, str] = {}
    if not atom_ids:
        return out
    # PostgREST `in.()` filter: events where atom_id matches + user_id matches.
    # Fetch all events for these atoms and reduce client-side (≤ ~50 atoms).
    ids_csv = ",".join(str(i) for i in atom_ids)
    params = {
        "select": "atom_id,kind,payload,created_at",
        "user_id": f"eq.{user_id}",
        "atom_id": f"in.({ids_csv})",
        "order": "created_at.desc",
        "limit": "2000",
    }
    r = await supabase._rest("GET", "events", params=params)
    rows = r.json()
    # First pass: latest refined per atom; fallback latest content.
    refined: dict[UUID, str] = {}
    raw: dict[UUID, str] = {}
    for row in rows:
        try:
            aid = UUID(row["atom_id"])
        except Exception:
            continue
        kind = row.get("kind")
        payload = row.get("payload") or {}
        if kind == "refined" and aid not in refined:
            text = (payload.get("refinedContent") or "").strip()
            if text:
                refined[aid] = text
        elif kind in ("created", "updatedRaw") and aid not in raw:
            text = (payload.get("content") or "").strip()
            if text:
                raw[aid] = text
    for aid in atom_ids:
        out[aid] = refined.get(aid) or raw.get(aid) or ""
    return out


def _format_context(ordered_ids: list[UUID], texts: dict[UUID, str]) -> str:
    parts = []
    for i, aid in enumerate(ordered_ids, start=1):
        body = texts.get(aid, "(missing)").strip()
        parts.append(f"[atom:{i}] {body}")
    return "\n\n".join(parts)


async def run_compose(
    *,
    user_id: UUID,
    intent: str,
    atom_ids: list[UUID],
    tone: str,
    settings: Settings,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> AsyncIterator[dict[str, str]]:
    yield update("fetch", f"loading {len(atom_ids)} atoms")
    texts = await _fetch_atom_texts(user_id=user_id, atom_ids=atom_ids, supabase=supabase)
    if not any(texts.values()):
        yield update("compose", "no atom content found")
        yield token("(no atoms had content to draw from)")
        return

    yield update("compose", "drafting")
    context = _format_context(atom_ids, texts)
    tone_rule = TONE_RULES.get(tone, TONE_RULES["post"])
    system = f"{SYSTEM_BASE}\n\n{tone_rule}"
    user = (
        f"WRITING INTENT:\n{intent.strip()}\n\n---\n\nCONTEXT (atoms in order):\n\n{context}\n\n"
        f"---\n\nDraft the {tone} now. Cite atoms inline as [atom:N]."
    )
    async for chunk in gemini.stream(
        system=system,
        user=user,
        max_tokens=1400,
        temperature=0.55,
    ):
        if chunk:
            yield token(chunk)
