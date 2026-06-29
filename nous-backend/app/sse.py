"""SSE event helpers — typed wrappers over sse_starlette.

We expose two channels per stream, matching PRD §2.3:
  • `messages` — token deltas, progressive text rendering on iOS
  • `updates`  — agent state transitions (e.g., "retrieving", "synthesizing")

Each event ships as JSON in the data field so the iOS client can decode uniformly.
"""
from __future__ import annotations

import json
from collections.abc import AsyncIterator, AsyncGenerator
from typing import Any, Literal

from pydantic import BaseModel, Field

EventChannel = Literal["update", "token", "citation", "done", "error"]


class SSEEvent(BaseModel):
    """Wire format. Sent as `event: <channel>\\ndata: <json>\\n\\n`."""

    channel: EventChannel
    payload: dict[str, Any] = Field(default_factory=dict)

    def to_sse(self) -> dict[str, str]:
        return {
            "event": self.channel,
            "data": json.dumps(self.payload, ensure_ascii=False, separators=(",", ":")),
        }


def update(stage: str, detail: str | None = None) -> dict[str, str]:
    return SSEEvent(
        channel="update",
        payload={"stage": stage, **({"detail": detail} if detail else {})},
    ).to_sse()


def token(text: str) -> dict[str, str]:
    return SSEEvent(channel="token", payload={"text": text}).to_sse()


def citation(atom_id: str, snippet: str, score: float) -> dict[str, str]:
    return SSEEvent(
        channel="citation",
        payload={"atom_id": atom_id, "snippet": snippet, "score": score},
    ).to_sse()


def done(extra: dict[str, Any] | None = None) -> dict[str, str]:
    return SSEEvent(channel="done", payload=extra or {}).to_sse()


def error(message: str, code: str = "internal") -> dict[str, str]:
    return SSEEvent(channel="error", payload={"code": code, "message": message}).to_sse()


async def safe_stream(
    inner: AsyncIterator[dict[str, str]],
) -> AsyncGenerator[dict[str, str], None]:
    """Wrap a stream, converting unhandled exceptions into a single `error` event
    followed by `done`. iOS clients can therefore treat the stream as always
    well-formed."""
    try:
        async for ev in inner:
            yield ev
    except Exception as exc:  # noqa: BLE001 — boundary handler
        yield error(str(exc) or exc.__class__.__name__)
    finally:
        yield done()
