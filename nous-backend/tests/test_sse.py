from __future__ import annotations

import json

import pytest

from app.sse import citation, done, error, safe_stream, token, update


def test_update_event() -> None:
    e = update("retrieve", "searching")
    assert e["event"] == "update"
    payload = json.loads(e["data"])
    assert payload == {"stage": "retrieve", "detail": "searching"}


def test_token_event() -> None:
    e = token("hello world")
    assert e["event"] == "token"
    assert json.loads(e["data"]) == {"text": "hello world"}


def test_citation_event() -> None:
    e = citation("00000000-0000-0000-0000-000000000001", "snippet body", 0.872)
    payload = json.loads(e["data"])
    assert payload["score"] == 0.872
    assert payload["atom_id"] == "00000000-0000-0000-0000-000000000001"


def test_done_and_error() -> None:
    assert done()["event"] == "done"
    err = error("boom", code="upstream")
    assert err["event"] == "error"
    assert json.loads(err["data"]) == {"code": "upstream", "message": "boom"}


@pytest.mark.asyncio
async def test_safe_stream_appends_done_on_success() -> None:
    async def producer():
        yield update("a")
        yield token("hi")

    out = [ev async for ev in safe_stream(producer())]
    assert out[-1]["event"] == "done"
    assert any(ev["event"] == "token" for ev in out)


@pytest.mark.asyncio
async def test_safe_stream_converts_exception_to_error_then_done() -> None:
    async def producer():
        yield update("start")
        raise RuntimeError("kaboom")

    out = [ev async for ev in safe_stream(producer())]
    assert out[-2]["event"] == "error"
    assert out[-1]["event"] == "done"
    assert "kaboom" in json.loads(out[-2]["data"])["message"]
