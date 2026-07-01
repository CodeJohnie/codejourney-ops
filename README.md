# codejourney-ops

CI/CD pipeline and Kubernetes manifests for the [CodeJourney](https://github.com/CodeJohnie/CodeJourney) app running on a k3s home-lab cluster.

**Stack:** GitHub Actions · Zot OCI registry (NodePort) · Self-hosted runner (k8s pod) · Tailscale ingress · Bitnami Sealed Secrets · Longhorn distributed storage

---

## How it works

```
push to main (CodeJourney repo)
  → .github/workflows/deploy.yml  (dispatch trigger)
    → this repo's pipeline.yml    (runs on self-hosted runner)
      → nerdctl + buildkitd build web image  → Zot registry
      → nerdctl + buildkitd build API image  → Zot registry
      → kubectl apply postgres, redis         (idempotent)
      → kubectl set image deployment/codejourney
      → kubectl set image deployment/codejourney-api
```

---

## One-time setup

### 1. Create this repo on GitHub

```bash
cd ~/codejourney-ops
git init
git remote add origin https://github.com/CodeJohnie/codejourney-ops.git
git add .
git commit -m "init: ops repo"
git push -u origin main
```

### 2. Create a GitHub Personal Access Token (PAT)

In GitHub → Settings → Developer settings → Personal access tokens → Fine-grained tokens:

- **Repository access:** both `CodeJourney` and `codejourney-ops`
- **Permissions:**
  - `Contents` → Read
  - `Actions` → Read & Write
  - `Metadata` → Read (auto-selected)

Save the token — you'll use it in steps 4 and 6.

### 3. Apply runner namespace and RBAC to your cluster

```bash
kubectl apply -f runner/namespace.yaml
kubectl apply -f runner/rbac.yaml
```

### 4. Create runner secrets in the cluster

The runner uses a **PAT** (`ACCESS_TOKEN`) for permanent authentication — no expiring registration tokens.

```bash
kubectl create secret generic runner-secrets -n ci \
  --from-literal=ACCESS_TOKEN=<paste-your-PAT-here>
```

### 5. Deploy the runner pod

```bash
kubectl apply -f runner/deployment.yaml
```

Verify it registered:
```bash
kubectl logs -n ci deployment/github-runner -c runner --tail=10
# Should show: "Listening for Jobs"
```

Confirm in GitHub: Settings → Actions → Runners → you should see `k3s-homelab` as **Idle**.

### 6. Add GHCR_TOKEN secret to both repos

In GitHub → each repo → Settings → Secrets and variables → Actions:

| Secret name | Value |
|---|---|
| `GHCR_TOKEN` | The PAT you created in step 2 |

Set it in **both** `CodeJourney` and `codejourney-ops`.

### 7. Seal and apply app secrets

Create sealed secrets for the database and API using kubeseal. The sealing script is at `k8s/seal-api-secret.sh`.

```bash
# On a machine with kubeseal and access to the cluster:
bash k8s/seal-api-secret.sh
kubectl apply -f k8s/sealed-secrets/
```

Two SealedSecrets are required:

| Secret name | Keys |
|---|---|
| `codejourney-db` | `POSTGRES_USER`, `POSTGRES_PASSWORD` |
| `codejourney-api` | `DATABASE_URL`, `JWT_SECRET` |

### 8. Apply one-time k8s manifests

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/tailscale-proxy.yaml
kubectl apply -f k8s/postgres.yaml
kubectl apply -f k8s/redis.yaml
```

The web and API deployments are created by the pipeline on the first push.

### 9. Trigger a deploy

Push any commit to `main` in the CodeJourney repo. Watch it in:
- GitHub → CodeJourney → Actions tab
- `kubectl rollout status deployment/codejourney -n dev-testing`
- `kubectl rollout status deployment/codejourney-api -n dev-testing`

---

## Repo structure

```
.github/workflows/
  pipeline.yml        # CI/CD pipeline (triggered by CodeJourney's deploy.yml)
k8s/
  namespace.yaml
  deployment.yaml       # Web app — IMAGE_PLACEHOLDER substituted at deploy time
  api-deployment.yaml   # NestJS API — API_IMAGE_PLACEHOLDER substituted at deploy time
  postgres.yaml         # PostgreSQL StatefulSet + headless service (Longhorn PVC)
  redis.yaml            # Redis StatefulSet + headless service (Longhorn PVC)
  tailscale-proxy.yaml  # Tailscale proxy StatefulSet + RBAC (Longhorn PVC)
  ingress-tailscale.yaml
  sealed-secret.yaml    # Encrypted web-app secrets (safe to commit)
  seal-api-secret.sh    # Script to generate and seal DB + API secrets
runner/
  namespace.yaml        # ci namespace
  rbac.yaml             # ServiceAccount + Role scoped to dev-testing
  deployment.yaml       # Runner pod (github-runner + buildkitd sidecar)
```

---

## Runner authentication

The runner uses **PAT-based authentication** (`ACCESS_TOKEN`). Unlike the one-time registration tokens, the PAT auto-refreshes on every restart — no token rotation needed. If you ever revoke and regenerate the PAT:

```bash
kubectl create secret generic runner-secrets -n ci \
  --from-literal=ACCESS_TOKEN=<new-PAT> \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment/github-runner -n ci
```

---

## What's running in `dev-testing`

| Workload | Type | Storage |
|---|---|---|
| `codejourney` | Deployment (Next.js) | — |
| `codejourney-api` | Deployment (NestJS/GraphQL) | — |
| `postgres` | StatefulSet | 5Gi Longhorn PVC |
| `redis` | StatefulSet | 1Gi Longhorn PVC |
| `tailscale-proxy` | StatefulSet | 100Mi Longhorn PVC |

**Tailscale hostnames:**
- Web: `codejourney.tail9d71dd.ts.net`
- API: `codejourney-api.tail9d71dd.ts.net`
