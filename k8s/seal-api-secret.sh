#!/usr/bin/env bash
# Generate and seal the API secrets.
# Run this once from a machine with kubectl + kubeseal access to the cluster.
# Output: api-sealed-secret.yaml (commit this; never commit the raw secret)
set -euo pipefail

# ── edit these values ──────────────────────────────────────────────────────────
DB_USER="codejourney"
DB_PASSWORD="$(openssl rand -base64 24)"  # or set a fixed value
DB_NAME="codejourney"
JWT_SECRET="$(openssl rand -base64 48)"
# ──────────────────────────────────────────────────────────────────────────────

DATABASE_URL="postgresql://${DB_USER}:${DB_PASSWORD}@postgres.dev-testing.svc.cluster.local:5432/${DB_NAME}"

echo "Generated credentials:"
echo "  DB_PASSWORD : ${DB_PASSWORD}"
echo "  JWT_SECRET  : ${JWT_SECRET}"
echo ""
echo "Save these somewhere safe — they cannot be recovered from the sealed secret."
echo ""

# Seal the API secret
kubectl create secret generic codejourney-api \
  --namespace dev-testing \
  --from-literal=DATABASE_URL="${DATABASE_URL}" \
  --from-literal=JWT_SECRET="${JWT_SECRET}" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > api-sealed-secret.yaml

# Seal the DB credentials secret (used by the postgres StatefulSet)
kubectl create secret generic codejourney-db \
  --namespace dev-testing \
  --from-literal=POSTGRES_USER="${DB_USER}" \
  --from-literal=POSTGRES_PASSWORD="${DB_PASSWORD}" \
  --dry-run=client -o yaml \
  | kubeseal --format yaml > db-sealed-secret.yaml

echo "Created api-sealed-secret.yaml and db-sealed-secret.yaml"
echo "Commit both files, then apply with: kubectl apply -f ."
