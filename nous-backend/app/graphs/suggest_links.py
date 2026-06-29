"""Auto-link suggester.

Pipeline:
  1. Embed source text (RETRIEVAL_QUERY task type — we're searching, not storing).
  2. Cosine top-K against the user's existing embeddings (semantic_search_full).
  3. Drop the source atom itself (self-match).
  4. Hand top-K + source text to Gemini, ask for 0..max_picks "substantively related"
     atoms with a one-line reason each. Strict JSON output.
  5. Filter Gemini's response to UUIDs that were actually in the candidate pool
     (defends against hallucinated IDs).

Cheap to call multiple times — only the Gemini step has token cost; embedding
is small + fast on `gemini-embedding-001`.
"""
from __future__ import annotations

import json
from uuid import UUID

from app.config import Settings
from app.logging import get_logger
from app.models.atom import AtomCandidate
from app.models.links import LinkSuggestion
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient

log = get_logger(__name__)


SUGGEST_SYSTEM = """You curate links between thoughts in the user's personal knowledge graph.

Given a SOURCE atom and a numbered list of CANDIDATE atoms, identify which 0 to MAX_PICKS
candidates are *substantively related* — not just topically nearby.

Substantively related means: same project, same person, same decision, same problem,
same artifact. NOT just "both about software" or "both written on Tuesday".

Return STRICT JSON only:
  { "picks": [ {"atom_id": "<uuid>", "reason": "<one short clause, ≤80 chars>"}, ... ] }

Rules:
- Return [] if nothing is substantive. Empty is correct, not failure.
- Cite only atom_ids present in the CANDIDATES list. Never invent ids.
- Reasons must reference the SHARED entity/decision, not generic topics.
- No prose outside the JSON object. No markdown."""


def _format_candidates(candidates: list[AtomCandidate]) -> str:
    if not candidates:
        return "(no candidates)"
    lines = []
    for i, c in enumerate(candidates, start=1):
        body = c.content.strip().replace("\n", " ")
        if len(body) > 240:
            body = body[:240].rstrip() + "…"
        lines.append(f"[{i}] atom_id={c.atom_id} score={c.score:.3f}\n{body}")
    return "\n\n".join(lines)


async def run_suggest_links(
    *,
    user_id: UUID,
    source_atom_id: UUID,
    source_text: str,
    candidate_pool: int,
    max_picks: int,
    settings: Settings,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> tuple[list[LinkSuggestion], int]:
    """Returns (suggestions, candidate_count)."""

    # 1. Embed source.
    try:
        vec = await gemini.embed(
            source_text,
            task_type="RETRIEVAL_QUERY",
            output_dim=settings.embed_dim,
        )
    except ValueError:
        return [], 0

    # 2. Cosine top-K.
    rows = await supabase.semantic_search_full(
        user_id=user_id,
        query_vector=vec,
        query_text=None,
        match_count=candidate_pool + 1,  # +1 to absorb self-match
    )
    candidates = [AtomCandidate.model_validate(r) for r in rows]
    candidates = [c for c in candidates if c.atom_id != source_atom_id][:candidate_pool]
    if not candidates:
        return [], 0

    # 3. Ask Gemini to curate.
    if max_picks == 0:
        return [], len(candidates)

    user_prompt = (
        f"SOURCE atom_id={source_atom_id}\n\n"
        f"{source_text.strip()}\n\n"
        f"---\n\nCANDIDATES (top {len(candidates)} by cosine):\n\n"
        f"{_format_candidates(candidates)}\n\n"
        f"---\n\nMAX_PICKS = {max_picks}"
    )

    try:
        raw = await gemini.generate(
            system=SUGGEST_SYSTEM,
            user=user_prompt,
            max_tokens=400,
            temperature=0.2,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("suggest_links_gemini_failed", error=str(exc))
        return [], len(candidates)

    # 4. Parse + filter to candidate set.
    candidate_ids = {c.atom_id for c in candidates}
    candidate_score = {c.atom_id: c.raw_score for c in candidates}

    raw_clean = raw.strip()
    # Gemini sometimes wraps in ```json ... ```
    if raw_clean.startswith("```"):
        raw_clean = raw_clean.strip("`")
        if raw_clean.lower().startswith("json"):
            raw_clean = raw_clean[4:]
        raw_clean = raw_clean.strip()

    try:
        parsed = json.loads(raw_clean)
    except json.JSONDecodeError:
        log.warning("suggest_links_bad_json", raw=raw_clean[:200])
        return [], len(candidates)

    out: list[LinkSuggestion] = []
    for p in (parsed.get("picks") or [])[:max_picks]:
        try:
            aid = UUID(p["atom_id"])
        except (KeyError, ValueError):
            continue
        if aid not in candidate_ids:
            continue
        # Prompt says ≤80 chars; enforce server-side so chip UI stays single-line.
        reason = (p.get("reason") or "").strip()
        if len(reason) > 80:
            reason = reason[:77].rstrip() + "…"
        out.append(
            LinkSuggestion(
                atom_id=aid,
                reason=reason,
                score=float(candidate_score.get(aid, 0.0)),
            )
        )
    return out, len(candidates)
