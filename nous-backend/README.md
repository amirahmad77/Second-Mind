# NOUS Backend

FastAPI + LangGraph + Gemini service that powers NOUS's GraphRAG synthesis, epistemic pushback, and hybrid semantic search.

## Endpoints

| Method | Path             | Purpose                                                                 |
|--------|------------------|-------------------------------------------------------------------------|
| GET    | `/health`        | liveness/readiness                                                      |
| POST   | `/v1/search`     | hybrid semantic search → JSON response                                  |
| POST   | `/v1/synthesize` | GraphRAG answer over user's atoms → SSE (`update`, `citation`, `token`) |
| POST   | `/v1/pushback`   | epistemic pushback prompts → SSE (`token` carries JSONL items)          |

All POST bodies require `user_id` (UUID).

## SSE protocol

Every stream emits one of these events; iOS treats them as a tagged union:

- `update` — `{stage, detail?}` — agent state transition
- `citation` — `{atom_id, snippet, score}` — retrieved context (synthesize only)
- `token` — `{text}` — incremental output (model output)
- `done` — `{}` — terminal frame, always emitted
- `error` — `{code, message}` — fatal error, followed by `done`

## Local dev

```bash
cp .env.example .env   # fill SUPABASE_URL, SUPABASE_ANON_KEY, GEMINI_API_KEY
./scripts/dev.sh       # uvicorn --reload on :8080
```

Or via Docker:
```bash
docker compose up --build
```

## Smoke tests

```bash
# health
curl http://localhost:8080/health

# search
curl -X POST http://localhost:8080/v1/search \
  -H 'content-type: application/json' \
  -d '{"user_id":"<uuid>","query":"runway worry","limit":5}'

# synthesize (SSE)
curl -N -X POST http://localhost:8080/v1/synthesize \
  -H 'content-type: application/json' \
  -d '{"user_id":"<uuid>","question":"what was I thinking about Q3 runway?","context_limit":8}'
```

## Deploy → GCP Cloud Run

One-time setup of project + secrets, then:

```bash
./scripts/deploy.sh
```

See `scripts/deploy.sh` head comment for the prerequisite gcloud commands (Artifact Registry repo, Secret Manager entries, IAM bindings).

## Ranking

Hybrid score per PRD §4:

```
S_final = S_vec * exp(-λ_year * t_years)
```

Decay is **neutralized** when:
- query has an exact full-text hit on the atom, OR
- atom has more than `BACKLINK_THRESHOLD` (default 3) inbound `[[ ]]` links

Defaults are tuned for ~10% decay per 6 months (`λ ≈ 0.21072 / yr`); both are env-tunable for A/B testing.

## Design notes

- **No direct Postgres connection.** All DB access is via Supabase PostgREST (`semantic_search_full`, `recent_atoms` RPCs). Fewer moving parts; RLS still enforced when running with anon key.
- **SSE chosen over WebSockets** because the iOS client only needs server→client streaming, and SSE traverses Cloud Run / proxies trivially with no upgrade dance.
- **Single uvicorn worker per Cloud Run instance.** Cloud Run scales horizontally; in-process workers waste memory on a 512Mi instance and complicate logging.
- **Streams always close.** `safe_stream()` in `app/sse.py` wraps every generator so the client always sees a `done` event, even on Gemini failure.
