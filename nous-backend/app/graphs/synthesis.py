"""GraphRAG synthesis pipeline.

Stages (each emits an SSE `update` so iOS can show live agent status per PRD §2.3):

  1. embed_query        — Gemini embedding of the user question
  2. retrieve           — semantic_search_full RPC against Supabase pgvector
  3. expand_backlinks   — for top hits, pull their inbound-linked atoms (one hop)
  4. synthesize         — Gemini stream with retrieved context, cite atom_ids inline

We yield `update`, `citation`, and `token` events as we progress. The router wraps
the iterator with `safe_stream` to guarantee a closing `done` event.

This module is decoupled from FastAPI/SSE — it returns plain dicts that the
router converts into SSE frames. That keeps it unit-testable.
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any
from uuid import UUID

from app.config import Settings
from app.logging import get_logger
from app.models.atom import AtomCandidate
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient
from app.sse import citation, token, update

log = get_logger(__name__)


SYNTHESIS_SYSTEM = """You are NOUS, a cognitive assistant operating over the user's personal knowledge graph.

Rules:
- Ground every claim in the supplied atoms. Cite using the format [atom:N] where N is the index from the CONTEXT block.
- If the atoms do not contain the answer, say so plainly. Do not invent facts, names, dates, or links.
- Match the user's voice. Be concise. Skip throat-clearing, prefaces, recaps.
- Use minimal markdown only when it improves scannability (short headings, bullets). No tables, no code fences.
- Do NOT restate the question. Answer directly.
- Do NOT moralize, hedge, or add safety disclaimers."""


def _format_context(atoms: list[AtomCandidate]) -> str:
    """Render retrieved atoms as a numbered context block for the prompt."""
    if not atoms:
        return "(no atoms found in the knowledge graph)"
    lines: list[str] = []
    for i, a in enumerate(atoms, start=1):
        date = a.created_at.strftime("%Y-%m-%d")
        tags = f" tags=[{', '.join(a.tags)}]" if a.tags else ""
        lines.append(
            f"[atom:{i}] id={a.atom_id} type={a.atom_type} created={date}"
            f" score={a.score:.3f}{tags}\n{a.content.strip()}"
        )
    return "\n\n".join(lines)


def _build_user_prompt(question: str, atoms: list[AtomCandidate]) -> str:
    return (
        f"CONTEXT (top {len(atoms)} atoms by hybrid score):\n\n"
        f"{_format_context(atoms)}\n\n"
        f"---\n\nQUESTION:\n{question.strip()}"
    )


async def run_synthesis(
    *,
    user_id: UUID,
    question: str,
    context_limit: int,
    settings: Settings,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> AsyncIterator[dict[str, str]]:
    """Async generator of SSE-ready dicts. Routes wrap it via safe_stream()."""

    # ── 1. embed_query ───────────────────────────────────────────────────
    yield update("embed", "embedding query")
    try:
        query_vec = await gemini.embed(
            question,
            task_type="RETRIEVAL_QUERY",
            output_dim=settings.embed_dim,
        )
    except Exception as exc:  # noqa: BLE001
        log.warning("synth_embed_failed", error=str(exc))
        raise

    # ── 2. retrieve ──────────────────────────────────────────────────────
    yield update("retrieve", "searching knowledge graph")
    rows = await supabase.semantic_search_full(
        user_id=user_id,
        query_vector=query_vec,
        query_text=question,
        match_count=context_limit,
    )
    atoms: list[AtomCandidate] = [AtomCandidate.model_validate(r) for r in rows]

    # Emit citations up front so iOS can render the context strip while the answer streams.
    for i, a in enumerate(atoms, start=1):
        snippet = a.content.strip().replace("\n", " ")
        if len(snippet) > 200:
            snippet = snippet[:200].rstrip() + "…"
        yield citation(
            atom_id=str(a.atom_id),
            snippet=f"[{i}] {snippet}",
            score=round(a.score, 4),
        )

    if not atoms:
        yield update("synthesize", "no relevant atoms — answering from cold")

    # ── 3. synthesize ────────────────────────────────────────────────────
    yield update("synthesize", "synthesizing answer")
    user_prompt = _build_user_prompt(question, atoms)

    async for chunk in gemini.stream(
        system=SYNTHESIS_SYSTEM,
        user=user_prompt,
        max_tokens=settings.synthesis_max_tokens,
        temperature=settings.synthesis_temperature,
    ):
        yield token(chunk)


async def run_synthesis_collected(
    *,
    user_id: UUID,
    question: str,
    context_limit: int,
    settings: Settings,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> dict[str, Any]:
    """Non-streaming variant. Useful for tests + non-SSE callers."""
    parts: list[str] = []
    citations: list[dict[str, Any]] = []
    async for ev in run_synthesis(
        user_id=user_id,
        question=question,
        context_limit=context_limit,
        settings=settings,
        supabase=supabase,
        gemini=gemini,
    ):
        if ev["event"] == "token":
            import json

            parts.append(json.loads(ev["data"])["text"])
        elif ev["event"] == "citation":
            import json

            citations.append(json.loads(ev["data"]))
    return {"answer": "".join(parts), "citations": citations}
