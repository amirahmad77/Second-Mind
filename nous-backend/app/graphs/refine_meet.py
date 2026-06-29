"""Meet-session refinement.

Input: full transcript segments (speaker + text + at) from a Google Meet session,
plus session metadata (meet_id, participants, window, running-append flag).

Output: markdown atom body, structured for fast scanning later. The user's own
turns are written in their voice; others' turns are attributed in third person.
Action items owned by the user get `[[action-item]]` markers so the app can
highlight them in the atom view.

Live sessions are refined repeatedly as the transcript grows: each call receives
the full cumulative transcript and re-synthesizes the entire body, since the app's
`refined` reducer keeps only the latest result.
"""
from __future__ import annotations

from app.models.capture import TranscriptSegment
from app.services.gemini import GeminiClient

SYSTEM = """You synthesize a Google Meet transcript into the user's personal knowledge atom.

The atom is for the USER — write in their voice for turns they spoke, and use
third-person attribution for other participants ("Sara pushed back on …").

Structure (in this order, omit empty sections):

## summary
3–6 tight bullets. What the meeting was, what was decided, what's next.

## decisions
One bullet per concrete decision. No waffle.

## action items
Checklist. User's own items get a `[[action-item]]` marker at start, others get
"(→ name)". Example:
- [[action-item]] draft the migration plan by Friday
- ship the staging rollout (→ Sara)

## open questions
Unresolved threads, unknowns, things parked for next time.

## verbatim
Short blockquotes of sharp lines worth keeping — direct quotes only, attributed
with em-dash + speaker. Skip this section if nothing stands out.

Rules:
- First line of the body is a one-liner ≤90 chars capturing the meeting's point.
- No TL;DR header. No preamble. No closing remark.
- Do not fabricate. If a section has nothing solid, drop it.
- Compress ruthlessly. ≤400 words total across all sections.
- Always produce the full body with the one-liner first. The transcript may be a
  live session refined repeatedly as it grows — each pass re-synthesizes the
  whole thing, so never emit a heading-only or partial body."""


def _format_segments(segments: list[TranscriptSegment]) -> str:
    lines: list[str] = []
    for s in segments:
        speaker = s.speaker or "speaker"
        ts = s.at.isoformat() if s.at else ""
        prefix = f"[{ts}] " if ts else ""
        lines.append(f"{prefix}{speaker}: {s.text}")
    return "\n".join(lines)


async def refine_meet_session(
    *,
    segments: list[TranscriptSegment],
    user_display_name: str | None,
    participants: list[str],
    meet_id: str,
    is_append: bool,
    gemini: GeminiClient,
) -> str:
    transcript = _format_segments(segments) or "(no captured turns)"
    header_parts = [
        f"MEET_ID: {meet_id}",
        f"APPEND: {'true' if is_append else 'false'}",
        f"USER: {user_display_name or '(unknown)'}",
        f"PARTICIPANTS: {', '.join(participants) if participants else '(unknown)'}",
    ]
    user_prompt = (
        "\n".join(header_parts)
        + "\n\n---\n\nTRANSCRIPT:\n\n"
        + transcript
        + "\n\n---\n\nRefine into the user's atom body."
    )
    return await gemini.generate(
        system=SYSTEM,
        user=user_prompt,
        max_tokens=1400,
        temperature=0.3,
    )
