from __future__ import annotations

from fastapi.testclient import TestClient


def test_health_ok() -> None:
    from app.main import app

    with TestClient(app) as client:
        r = client.get("/health")
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["service"] == "nous-backend"
