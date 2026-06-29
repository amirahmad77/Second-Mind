"""Liveness + readiness."""
from __future__ import annotations

from fastapi import APIRouter, Depends

from app import __version__
from app.config import Settings
from app.deps import settings_dep

router = APIRouter()


@router.get("/health", tags=["meta"])
async def health(settings: Settings = Depends(settings_dep)) -> dict[str, str]:
    return {
        "status": "ok",
        "service": settings.service_name,
        "version": __version__,
        "env": settings.environment,
    }
