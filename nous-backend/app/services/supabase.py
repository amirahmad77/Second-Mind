"""Supabase REST + RPC client. PostgREST only — no direct Postgres connection."""
from __future__ import annotations

import secrets
import uuid as _uuid
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID

import httpx
from tenacity import retry, retry_if_exception_type, stop_after_attempt, wait_exponential

from app.config import Settings, get_settings
from app.logging import get_logger

log = get_logger(__name__)


class SupabaseClient:
    """Thin async PostgREST wrapper. Reuses one HTTP client across the process."""

    def __init__(self, settings: Settings | None = None, client: httpx.AsyncClient | None = None):
        self.s = settings or get_settings()
        # Backend prefers service_role key (bypasses RLS) when present, else anon.
        self.key = self.s.supabase_service_role_key or self.s.supabase_anon_key
        self._owns_client = client is None
        self._client = client or httpx.AsyncClient(
            base_url=self.s.supabase_url.rstrip("/"),
            timeout=self.s.request_timeout_seconds,
            headers={
                "apikey": self.key,
                "Authorization": f"Bearer {self.key}",
                "Content-Type": "application/json",
            },
        )

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    # ── RPCs ────────────────────────────────────────────────────────────

    @retry(
        stop=stop_after_attempt(3),
        wait=wait_exponential(multiplier=0.4, max=4.0),
        retry=retry_if_exception_type((httpx.TransportError, httpx.RemoteProtocolError)),
        reraise=True,
    )
    async def rpc(self, name: str, args: dict[str, Any]) -> Any:
        r = await self._client.post(f"/rest/v1/rpc/{name}", json=args)
        if r.status_code >= 400:
            log.error("supabase_rpc_error", rpc=name, status=r.status_code, body=r.text[:500])
            r.raise_for_status()
        return r.json()

    async def semantic_search_full(
        self,
        *,
        user_id: UUID,
        query_vector: list[float],
        query_text: str | None = None,
        match_count: int | None = None,
        decay_lambda_year: float | None = None,
        backlink_threshold: int | None = None,
    ) -> list[dict[str, Any]]:
        """Returns full content for retrieval-augmented generation."""
        payload = {
            "user_id": str(user_id),
            "query_vector": query_vector,
            "query_text": query_text,
            "match_count": match_count or self.s.semantic_search_default_limit,
            "decay_lambda_year": (
                decay_lambda_year if decay_lambda_year is not None else self.s.decay_lambda_year
            ),
            "backlink_threshold": backlink_threshold or self.s.backlink_threshold,
        }
        return await self.rpc("semantic_search_full", payload)

    async def semantic_search(
        self,
        *,
        user_id: UUID,
        query_vector: list[float],
        query_text: str | None = None,
        match_count: int | None = None,
        decay_lambda_year: float | None = None,
        backlink_threshold: int | None = None,
    ) -> list[dict[str, Any]]:
        """Returns snippets only — proxy used by mobile clients (iOS goes direct to Supabase
        normally; this exists for backend admin / debugging)."""
        payload = {
            "user_id": str(user_id),
            "query_vector": query_vector,
            "query_text": query_text,
            "match_count": match_count or self.s.semantic_search_default_limit,
            "decay_lambda_year": (
                decay_lambda_year if decay_lambda_year is not None else self.s.decay_lambda_year
            ),
            "backlink_threshold": backlink_threshold or self.s.backlink_threshold,
        }
        return await self.rpc("semantic_search", payload)

    # ── REST table helpers (capture / pairing / tokens) ─────────────────

    async def _rest(
        self,
        method: str,
        path: str,
        *,
        params: dict[str, Any] | None = None,
        json: Any = None,
        prefer: str | None = None,
    ) -> httpx.Response:
        headers = {"Prefer": prefer} if prefer else None
        r = await self._client.request(
            method, f"/rest/v1/{path}", params=params, json=json, headers=headers
        )
        if r.status_code >= 400:
            log.error("supabase_rest_error", path=path, status=r.status_code, body=r.text[:500])
            r.raise_for_status()
        return r

    async def insert_event(
        self,
        *,
        atom_id: UUID,
        user_id: UUID,
        kind: str,
        payload: dict[str, Any],
    ) -> None:
        body = {
            "id": str(_uuid.uuid4()),
            "atom_id": str(atom_id),
            "user_id": str(user_id),
            "kind": kind,
            "payload": payload,
        }
        await self._rest("POST", "events", json=body, prefer="return=minimal")

    async def find_meet_atom(self, *, user_id: UUID, meet_id: str) -> UUID | None:
        """Return the atom_id of an existing `created` event for this (user, meetID),
        or None if no such meet atom exists."""
        params = {
            "select": "atom_id",
            "user_id": f"eq.{user_id}",
            "kind": "eq.created",
            "payload->source->>meetID": f"eq.{meet_id}",
            "limit": "1",
        }
        r = await self._rest("GET", "events", params=params)
        rows = r.json()
        if not rows:
            return None
        return UUID(rows[0]["atom_id"])

    async def fetch_meet_segments(self, *, atom_id: UUID, user_id: UUID) -> list[dict[str, Any]]:
        """Return every transcript segment captured for a meet atom so far, in
        capture order. Reads `segments` from all `created`/`updatedRaw` events for
        the atom — this is the cumulative transcript the refiner re-synthesizes."""
        params = {
            "select": "payload",
            "atom_id": f"eq.{atom_id}",
            "user_id": f"eq.{user_id}",
            "kind": "in.(created,updatedRaw)",
            "order": "created_at.asc",
        }
        r = await self._rest("GET", "events", params=params)
        segments: list[dict[str, Any]] = []
        for row in r.json():
            payload = row.get("payload") or {}
            batch = payload.get("segments")
            if isinstance(batch, list):
                segments.extend(batch)
        return segments

    async def mint_pairing_code(self, *, user_id: UUID, ttl_seconds: int = 600) -> tuple[str, datetime]:
        # 6-digit zero-padded. Collisions retried up to 5x.
        expires = datetime.now(timezone.utc) + timedelta(seconds=ttl_seconds)
        for _ in range(5):
            code = f"{secrets.randbelow(1_000_000):06d}"
            body = {
                "code": code,
                "user_id": str(user_id),
                "expires_at": expires.isoformat(),
                "consumed": False,
            }
            try:
                await self._rest("POST", "pairing_codes", json=body, prefer="return=minimal")
                return code, expires
            except httpx.HTTPStatusError as e:
                if e.response.status_code == 409:
                    continue
                raise
        raise RuntimeError("could not mint unique pairing code")

    async def consume_pairing_code(self, *, code: str) -> UUID | None:
        """Atomically consume a valid pairing code, returning the user_id bound to it.
        Returns None if the code is missing, expired, or already consumed."""
        now_iso = datetime.now(timezone.utc).isoformat()
        params = {
            "code": f"eq.{code}",
            "consumed": "eq.false",
            "expires_at": f"gt.{now_iso}",
        }
        r = await self._rest(
            "PATCH",
            "pairing_codes",
            params=params,
            json={"consumed": True},
            prefer="return=representation",
        )
        rows = r.json()
        if not rows:
            return None
        return UUID(rows[0]["user_id"])

    async def create_extension_token(self, *, user_id: UUID, label: str | None) -> str:
        token = secrets.token_urlsafe(32)
        body = {"token": token, "user_id": str(user_id), "label": label}
        await self._rest("POST", "extension_tokens", json=body, prefer="return=minimal")
        return token

    async def validate_extension_token(self, *, token: str) -> UUID | None:
        params = {
            "select": "user_id,revoked_at",
            "token": f"eq.{token}",
            "limit": "1",
        }
        r = await self._rest("GET", "extension_tokens", params=params)
        rows = r.json()
        if not rows:
            return None
        if rows[0].get("revoked_at"):
            return None
        # Fire-and-forget last_used_at bump.
        try:
            await self._rest(
                "PATCH",
                "extension_tokens",
                params={"token": f"eq.{token}"},
                json={"last_used_at": datetime.now(timezone.utc).isoformat()},
                prefer="return=minimal",
            )
        except Exception:
            pass
        return UUID(rows[0]["user_id"])

    async def upsert_embedding(
        self,
        *,
        atom_id: UUID,
        user_id: UUID,
        vector: list[float],
    ) -> None:
        body = {
            "atom_id": str(atom_id),
            "user_id": str(user_id),
            "dim": len(vector),
            "vector": vector,
            "updated_at": datetime.now(timezone.utc).isoformat(),
        }
        await self._rest(
            "POST",
            "embeddings",
            json=body,
            prefer="resolution=merge-duplicates,return=minimal",
        )

    async def recent_atoms(
        self, *, user_id: UUID, limit_count: int, since_days: int
    ) -> list[dict[str, Any]]:
        return await self.rpc(
            "recent_atoms",
            {
                "user_id": str(user_id),
                "limit_count": limit_count,
                "since_days": since_days,
            },
        )
