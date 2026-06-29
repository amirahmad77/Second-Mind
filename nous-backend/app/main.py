"""FastAPI app factory + lifespan for client lifecycles."""
from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app import __version__
from app.config import get_settings
from app.logging import configure_logging, get_logger
from app.routers import capture, compose, health, links, search, synthesis
from app.services.gemini import GeminiClient
from app.services.supabase import SupabaseClient

log = get_logger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    settings = get_settings()
    configure_logging(settings.log_level)
    log.info("startup", env=settings.environment, version=__version__)

    app.state.supabase = SupabaseClient(settings)
    app.state.gemini = GeminiClient(settings)

    try:
        yield
    finally:
        await app.state.supabase.aclose()
        log.info("shutdown")


def create_app() -> FastAPI:
    settings = get_settings()
    app = FastAPI(
        title="NOUS Backend",
        version=__version__,
        description="Cognitive synthesis, epistemic pushback, and hybrid search over the user's knowledge graph.",
        lifespan=lifespan,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_allow_origins,
        allow_credentials=False,
        allow_methods=["GET", "POST"],
        allow_headers=["*"],
    )

    app.include_router(health.router)
    app.include_router(search.router)
    app.include_router(synthesis.router)
    app.include_router(links.router)
    app.include_router(capture.router)
    app.include_router(compose.router)
    return app


app = create_app()
