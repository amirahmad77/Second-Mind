#!/usr/bin/env bash
# Local dev runner. Hot-reloads on code changes.
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ ! -d .venv ]]; then
    echo "→ creating venv with uv"
    uv venv .venv
    uv pip install -e ".[dev]"
fi

# shellcheck disable=SC1091
source .venv/bin/activate

if [[ ! -f .env ]]; then
    echo "→ no .env found; copying .env.example"
    cp .env.example .env
    echo "  edit .env then re-run"
    exit 1
fi

exec uvicorn app.main:app --reload --host 0.0.0.0 --port 8080
