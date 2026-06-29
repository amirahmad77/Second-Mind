# syntax=docker/dockerfile:1.7
# Multi-stage build for Cloud Run.
# Stage 1: build wheels with uv (fast resolver, deterministic).
# Stage 2: slim runtime, non-root user, single uvicorn worker (Cloud Run scales horizontally).

FROM python:3.11-slim AS builder

ENV PIP_NO_CACHE_DIR=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    UV_LINK_MODE=copy

RUN pip install --no-cache-dir uv==0.5.4

WORKDIR /build
COPY pyproject.toml ./
COPY app ./app

# Resolve + install into a relocatable venv at /opt/venv.
RUN uv venv /opt/venv && \
    uv pip install --python /opt/venv/bin/python --no-cache .

# ── Runtime ──────────────────────────────────────────────────────────────
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PORT=8080

# CA bundle + minimal libs for httpx
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

# Non-root user
RUN useradd --create-home --uid 10001 nous

WORKDIR /app
COPY --from=builder /opt/venv /opt/venv
COPY app ./app

USER nous

EXPOSE 8080

# Cloud Run: respect $PORT, single uvicorn worker (use Cloud Run --concurrency for parallelism)
CMD exec uvicorn app.main:app \
    --host 0.0.0.0 \
    --port "${PORT}" \
    --workers 1 \
    --proxy-headers \
    --forwarded-allow-ips="*" \
    --timeout-keep-alive 75
