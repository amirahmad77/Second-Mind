#!/usr/bin/env bash
# Deploy to GCP Cloud Run via Cloud Build.
#
# One-time setup:
#   gcloud config set project <PROJECT_ID>
#   gcloud services enable run.googleapis.com cloudbuild.googleapis.com artifactregistry.googleapis.com secretmanager.googleapis.com
#   gcloud artifacts repositories create nous --repository-format=docker --location=us-central1
#   echo -n "<value>" | gcloud secrets create nous-supabase-url      --data-file=-
#   echo -n "<value>" | gcloud secrets create nous-supabase-anon-key --data-file=-
#   echo -n "<value>" | gcloud secrets create nous-gemini-api-key    --data-file=-
#   gcloud secrets add-iam-policy-binding nous-supabase-url --member="serviceAccount:$(gcloud projects describe $(gcloud config get-value project) --format='value(projectNumber)')-compute@developer.gserviceaccount.com" --role=roles/secretmanager.secretAccessor
#   (repeat for each secret)
#
# Then:
#   ./scripts/deploy.sh
set -euo pipefail
cd "$(dirname "$0")/.."

REGION="${REGION:-us-central1}"
REPO="${REPO:-nous}"
SERVICE="${SERVICE:-nous-backend}"

gcloud builds submit \
    --config cloudbuild.yaml \
    --substitutions=_REGION="$REGION",_REPO="$REPO",_SERVICE="$SERVICE"

URL=$(gcloud run services describe "$SERVICE" --region "$REGION" --format='value(status.url)')
echo
echo "✓ deployed: $URL"
echo
echo "smoke test:"
echo "  curl $URL/health"
