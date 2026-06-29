"""Gemini client — embeddings + chat (streaming).

Uses google-genai SDK (the new unified SDK). Synchronous SDK methods are wrapped
in `asyncio.to_thread` so the FastAPI event loop is never blocked.

For streaming generation we drive the SDK's `generate_content_stream` from a
worker thread and bridge into an async iterator via `asyncio.Queue`.
"""
from __future__ import annotations

import asyncio
from collections.abc import AsyncIterator
from typing import Any

from google import genai
from google.genai import types as gtypes
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from app.config import Settings, get_settings
from app.logging import get_logger

log = get_logger(__name__)

_RETRYABLE: tuple[type[BaseException], ...] = (TimeoutError, ConnectionError)


class GeminiClient:
    def __init__(self, settings: Settings | None = None):
        self.s = settings or get_settings()
        self._client = genai.Client(api_key=self.s.gemini_api_key)

    # ── Embeddings ──────────────────────────────────────────────────────

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=0.5, max=4.0),
        retry=retry_if_exception_type(_RETRYABLE),
        reraise=True,
    )
    async def embed(
        self,
        text: str,
        *,
        task_type: str = "SEMANTIC_SIMILARITY",
        output_dim: int | None = None,
    ) -> list[float]:
        """Returns a (output_dim or settings.embed_dim)-length float vector."""
        dim = output_dim or self.s.embed_dim
        cleaned = text.strip()
        if len(cleaned) < 3:
            raise ValueError("text too short to embed")
        if len(cleaned) > 8000:
            cleaned = cleaned[:8000]

        def _call() -> list[float]:
            resp = self._client.models.embed_content(
                model=self.s.gemini_embed_model,
                contents=cleaned,
                config=gtypes.EmbedContentConfig(
                    task_type=task_type,
                    output_dimensionality=dim,
                ),
            )
            # google-genai returns ContentEmbedding(s) with `.values`
            embeddings = getattr(resp, "embeddings", None) or []
            if not embeddings:
                raise RuntimeError("gemini returned empty embeddings")
            values = getattr(embeddings[0], "values", None)
            if values is None:
                raise RuntimeError("gemini embedding missing values")
            return list(values)

        return await asyncio.to_thread(_call)

    # ── Streaming chat ──────────────────────────────────────────────────

    async def stream(
        self,
        *,
        system: str,
        user: str,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> AsyncIterator[str]:
        """Yields incremental text chunks from gemini-2.5-flash."""
        cfg = gtypes.GenerateContentConfig(
            system_instruction=system,
            temperature=temperature if temperature is not None else self.s.synthesis_temperature,
            max_output_tokens=max_tokens or self.s.synthesis_max_tokens,
        )

        queue: asyncio.Queue[str | None | BaseException] = asyncio.Queue()
        loop = asyncio.get_running_loop()

        def _producer() -> None:
            try:
                for chunk in self._client.models.generate_content_stream(
                    model=self.s.gemini_chat_model,
                    contents=user,
                    config=cfg,
                ):
                    text = getattr(chunk, "text", None)
                    if text:
                        loop.call_soon_threadsafe(queue.put_nowait, text)
            except BaseException as exc:  # noqa: BLE001 — bridge boundary
                loop.call_soon_threadsafe(queue.put_nowait, exc)
            finally:
                loop.call_soon_threadsafe(queue.put_nowait, None)

        # Run blocking SDK iteration off the event loop.
        asyncio.create_task(asyncio.to_thread(_producer))

        while True:
            item: Any = await queue.get()
            if item is None:
                break
            if isinstance(item, BaseException):
                raise item
            yield item

    async def transcribe_audio(
        self,
        *,
        audio_bytes: bytes,
        mime: str = "audio/webm",
    ) -> str:
        """Transcribe a short audio chunk. Returns raw text with speaker labels
        when they're audible; the caller is responsible for splitting into
        TranscriptSegments. Uses gemini-2.5-flash native audio input."""
        system = (
            "You transcribe meeting audio verbatim. Output plain text only. "
            "If multiple speakers are audible, prefix each turn with "
            "'Speaker N:' on its own line. Do not summarize. Do not translate."
        )
        cfg = gtypes.GenerateContentConfig(
            system_instruction=system,
            temperature=0.0,
            max_output_tokens=2048,
        )

        def _call() -> str:
            resp = self._client.models.generate_content(
                model=self.s.gemini_chat_model,
                contents=[
                    gtypes.Part.from_bytes(data=audio_bytes, mime_type=mime),
                ],
                config=cfg,
            )
            return (resp.text or "").strip()

        return await asyncio.to_thread(_call)

    async def generate(
        self,
        *,
        system: str,
        user: str,
        max_tokens: int | None = None,
        temperature: float | None = None,
    ) -> str:
        """Non-streaming convenience wrapper. Used by pushback synthesis."""
        cfg = gtypes.GenerateContentConfig(
            system_instruction=system,
            temperature=(
                temperature if temperature is not None else self.s.pushback_temperature
            ),
            max_output_tokens=max_tokens or self.s.pushback_max_tokens,
        )

        def _call() -> str:
            resp = self._client.models.generate_content(
                model=self.s.gemini_chat_model,
                contents=user,
                config=cfg,
            )
            return (resp.text or "").strip()

        return await asyncio.to_thread(_call)
