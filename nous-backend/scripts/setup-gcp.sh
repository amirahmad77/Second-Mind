#!/usr/bin/env bash
# One-shot GCP setup for NOUS backend.
# Idempotent — safe to re-run.
#
# Prereqs (do these manually first):
#   1. gcloud auth login --update-adc   (personal Google account)
#   2. gcloud projects create <PROJECT_ID> --name="NOUS"
#   3. Link billing in console:
#      https://console.cloud.google.com/billing/linkedaccount?project=<PROJECT_ID>
#
# Usage:
#   PROJECT_ID=nous-prod-042 ./scripts/setup-gcp.sh
#
# Optional env:
#   REGION=us-central1
#   REPO=nous
#   SUPABASE_URL, SUPABASE_ANON_KEY, GEMINI_API_KEY  (else read from local .env)

set -euo pipefail
cd "$(dirname "$0")/.."

: "${PROJECT_ID:?set PROJECT_ID env var (your GCP project id)}"
REGION="${REGION:-us-central1}"
REPO="${REPO:-nous}"

# ── Pull secret values from .env if not in env ──────────────────────────
if [[ -f .env ]]; then
    # shellcheck disable=SC1091
    set -a; source .env; set +a
fi

: "${SUPABASE_URL:?SUPABASE_URL missing — set via env or .env}"
: "${SUPABASE_ANON_KEY:?SUPABASE_ANON_KEY missing — set via env or .env}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY missing — set via env or .env}"

echo "→ project: $PROJECT_ID"
echo "→ region:  $REGION"
echo "→ repo:    $REPO"

gcloud config set project "$PROJECT_ID" >/dev/null

# ── 1. Verify billing linked ────────────────────────────────────────────
BILLING_ENABLED=$(gcloud beta billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null || echo "false")
if [[ "$BILLING_ENABLED" != "True" && "$BILLING_ENABLED" != "true" ]]; then
    echo "✗ billing not linked to $PROJECT_ID"
    echo "  open: https://console.cloud.google.com/billing/linkedaccount?project=$PROJECT_ID"
    exit 1
fi
echo "✓ billing linked"

# ── 2. Enable APIs ──────────────────────────────────────────────────────
echo "→ enabling APIs (one-time, ~30s)…"
gcloud services enable \
    run.googleapis.com \
    cloudbuild.googleapis.com \
    artifactregistry.googleapis.com \
    secretmanager.googleapis.com \
    --quiet
echo "✓ APIs enabled"

# ── 3. Artifact Registry repo ───────────────────────────────────────────
if gcloud artifacts repositories describe "$REPO" --location="$REGION" >/dev/null 2>&1; then
    echo "✓ artifact registry repo exists"
else
    gcloud artifacts repositories create "$REPO" \
        --repository-format=docker \
        --location="$REGION" \
        --description="NOUS container images"
    echo "✓ artifact registry repo created"
fi

# ── 4. Secrets ──────────────────────────────────────────────────────────
upsert_secret() {
    local name="$1" value="$2"
    if gcloud secrets describe "$name" >/dev/null 2>&1; then
        printf '%s' "$value" | gcloud secrets versions add "$name" --data-file=- >/dev/null
        echo "✓ secret updated: $name"
    else
        printf '%s' "$value" | gcloud secrets create "$name" \
            --replication-policy=automatic \
            --data-file=- >/dev/null
        echo "✓ secret created: $name"
    fi
}
upsert_secret nous-supabase-url      "$SUPABASE_URL"
upsert_secret nous-supabase-anon-key "$SUPABASE_ANON_KEY"
upsert_secret nous-gemini-api-key    "$GEMINI_API_KEY"

# ── 5. Grant Cloud Run runtime SA access to secrets ─────────────────────
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT_ID" --format='value(projectNumber)')
RUNTIME_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

for secret in nous-supabase-url nous-supabase-anon-key nous-gemini-api-key; do
    gcloud secrets add-iam-policy-binding "$secret" \
        --member="serviceAccount:${RUNTIME_SA}" \
        --role="roles/secretmanager.secretAccessor" \
        --quiet >/dev/null
done
echo "✓ runtime SA granted secret access"

# ── 6. Grant Cloud Build SA permission to deploy + impersonate runtime SA
CLOUDBUILD_SA="${PROJECT_NUMBER}@cloudbuild.gserviceaccount.com"
gcloud projects add-iam-policy-binding "$PROJECT_ID" \
    --member="serviceAccount:${CLOUDBUILD_SA}" \
    --role="roles/run.admin" \
    --quiet >/dev/null
gcloud iam service-accounts add-iam-policy-binding "$RUNTIME_SA" \
    --member="serviceAccount:${CLOUDBUILD_SA}" \
    --role="roles/iam.serviceAccountUser" \
    --quiet >/dev/null
echo "✓ cloud build SA granted deploy + actAs"

echo
echo "──────────────────────────────────────────"
echo "✓ GCP setup complete"
echo "──────────────────────────────────────────"
echo
echo "next: deploy with"
echo "  REGION=$REGION REPO=$REPO ./scripts/deploy.sh"
