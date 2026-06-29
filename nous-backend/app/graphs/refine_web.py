"""Web-clip refinement.

Input: user's highlighted selection (or page summary fallback) + page context
(URL, title, meta description, domain).

Output: markdown atom body. First line = one-liner; body preserves key quotes
from selection; page context mentioned naturally; no walls of prose.
"""
from __future__ import annotations

from app.services.gemini import GeminiClient

SYSTEM = """You refine web clips into the user's personal knowledge atom.

FORMAT (always):
1. TITLE LINE — the very first line must be a descriptive title (≤80 chars) that
   captures the overall context: what this page/resource IS and why it matters.
   Write it as a noun phrase or tight statement. No "This article…" lead-ins.
   No prefix, no label. This is the primary handle the user will scan later.

2. BODY — compact markdown below the title:
   - For a sole-link save (selection starts with [link] or [page]):
     2–3 lines from the page title + meta that explain what the resource covers.
     Keep it minimal — the title did the heavy lifting.
   - For a text selection:
     Preserve meaningful quotes verbatim in blockquotes (> text).
     1–3 lines of compressed context around the quote.
     Mention source once at the end: "— from <domain>".

RULES:
- Technical/reference material: use bullets. Opinion/essay: prose + blockquotes.
- Write in the user's voice (stashing for themselves, not summarising for others).
- ≤150 words total across title + body.
- Never invent content not in the clip or page metadata.
- No TL;DR header, no preamble, no closing remark.
- Output only the markdown body."""


async def refine_web_clip(
    *,
    selection: str,
    title: str | None,
    url: str | None,
    domain: str | None,
    meta_description: str | None,
    crawled_markdown: str | None = None,
    gemini: GeminiClient,
) -> str:
    context_parts: list[str] = []
    if title:
        context_parts.append(f"PAGE TITLE: {title}")
    if domain:
        context_parts.append(f"DOMAIN: {domain}")
    if url:
        context_parts.append(f"URL: {url}")
    if meta_description:
        context_parts.append(f"META DESCRIPTION: {meta_description}")
    context = "\n".join(context_parts) if context_parts else "(no page context)"

    # When we have full crawled content, include it so the refiner can produce
    # a rich title and meaningful context even for bare-link saves.
    if crawled_markdown:
        content_block = (
            f"---\n\nPAGE CONTENT (markdown, truncated):\n\n{crawled_markdown}\n\n"
        )
    else:
        content_block = ""

    user_prompt = (
        f"{context}\n\n"
        f"{content_block}"
        f"---\n\nUSER SELECTION:\n\n{selection.strip()}\n\n"
        f"---\n\nRefine into the user's atom body."
    )
    return await gemini.generate(
        system=SYSTEM,
        user=user_prompt,
        max_tokens=500,
        temperature=0.25,
    )
