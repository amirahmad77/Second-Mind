"""Epistemic Pushback (PRD §2.2 Core Capability 2).

Scans the user's recent atoms (default last 14 days), asks Gemini to surface:
  • contradictions between notes
  • obvious gaps in reasoning
  • unanswered questions implied by captured thoughts
  • assumptions worth challenging

Output is a list of structured "prompts" — never auto-edits anything.

Stream protocol identical to synthesis: update → token (JSON-line items) → done.
"""
from __future__ import annotations

from collections.abc import AsyncIterator
from typing import Any
from uuid import UUID

from app.config import Settings
from app.logging import get_logger
from app.models.atom import AtomSummary
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient
from app.sse import token, update

log = get_logger(__name__)


PUSHBACK_SYSTEM = """You are NOUS in epistemic-pushback mode.

You are given a window of the user's recent captured thoughts. Your job is to surface
high-signal *prompts* that help them think better — never instructions, never edits.

Look for:
  • direct contradictions between two atoms
  • unstated assumptions that load-bear important conclusions
  • questions the user implicitly raised but never resolved
  • dropped threads (started reasoning, then stopped)

Output STRICT JSONL (one object per line, no surrounding array, no commentary).

Each line must match:
  {"kind": "<contradiction|gap|question|assumption|thread>",
   "prompt": "<one-sentence pushback in second person, ≤140 chars>",
   "atom_ids": ["<uuid>", ...],
   "confidence": <0.0..1.0>}

Rules:
- Maximum 5 lines. Skip rather than pad.
- Reference real atom_ids from the input. Never invent ids.
- Be specific. "Have you considered alternatives?" is useless. Cite what's actually in the notes.
- Confidence ≥ 0.65 only. If you're guessing, omit the line.
- No preface, no trailing notes. JSONL only."""


def _format_atoms(atoms: list[AtomSummary]) -> str:
    if not atoms:
        return "(no recent atoms)"
    lines: list[str] = []
    for a in atoms:
        date = a.created_at.strftime("%Y-%m-%d %H:%M")
        tags = f" tags=[{', '.join(a.tags)}]" if a.tags else ""
        body = a.content.strip().replace("\n", " ")
        if len(body) > 600:
            body = body[:600].rstrip() + "…"
        lines.append(f"[{a.atom_id}] {date} type={a.atom_type}{tags}\n{body}")
    return "\n\n".join(lines)


async def run_pushback(
    *,
    user_id: UUID,
    since_days: int,
    max_atoms: int,
    settings: Settings,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> AsyncIterator[dict[str, str]]:
    yield update("scan", f"scanning last {since_days} days")
    rows = await supabase.recent_atoms(
        user_id=user_id, limit_count=max_atoms, since_days=since_days
    )
    atoms = [AtomSummary.model_validate(r) for r in rows]

    if len(atoms) < 3:
        yield update("done", "not enough recent atoms to push back on")
        return

    yield update("analyze", f"analyzing {len(atoms)} atoms")

    user_prompt = (
        f"RECENT ATOMS ({len(atoms)} total, last {since_days}d):\n\n"
        f"{_format_atoms(atoms)}"
    )

    # Stream tokens through — iOS can parse JSONL incrementally line-by-line.
    async for chunk in gemini.stream(
        system=PUSHBACK_SYSTEM,
        user=user_prompt,
        max_tokens=settings.pushback_max_tokens,
        temperature=settings.pushback_temperature,
    ):
        yield token(chunk)


async def run_pushback_collected(
    *,
    user_id: UUID,
    since_days: int,
    max_atoms: int,
    settings: Settings,
    supabase: SupabaseClient,
    gemini: GeminiClient,
) -> dict[str, Any]:
    """Non-streaming variant — collects JSONL into a parsed list."""
    import json

    parts: list[str] = []
    async for ev in run_pushback(
        user_id=user_id,
        since_days=since_days,
        max_atoms=max_atoms,
        settings=settings,
        supabase=supabase,
        gemini=gemini,
    ):
        if ev["event"] == "token":
            parts.append(json.loads(ev["data"])["text"])

    raw = "".join(parts)
    items: list[dict[str, Any]] = []
    for line in raw.splitlines():
        line = line.strip()
        if not line or not line.startswith("{"):
            continue
        try:
            items.append(json.loads(line))
        except json.JSONDecodeError:
            log.warning("pushback_bad_jsonl", line=line[:200])
    return {"items": items, "count": len(items)}
