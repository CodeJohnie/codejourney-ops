# codejourney-ops

CI/CD pipeline and Kubernetes manifests for the [CodeJourney](https://github.com/CodeJohnie/CodeJourney) app running on a k3s home-lab cluster.

**Stack:** GitHub Actions (free) · GHCR (free) · Self-hosted runner (k8s pod) · Tailscale ingress · Bitnami Sealed Secrets

---

## How it works

```
push to main (CodeJourney repo)
  → .github/workflows/deploy.yml  (5-line caller)
    → this repo's pipeline.yml    (reusable workflow)
      → self-hosted runner pod in k3s cluster (ci namespace)
        → docker build + push → ghcr.io/codejohnie/codejourney:<sha>
        → kubectl apply k8s/ with image tag substituted
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
  - `Packages` → Read & Write (for GHCR)
  - `Actions` → Read & Write (for workflow calls)

Save the token — you'll use it in steps 4 and 5.

### 3. Apply runner namespace and RBAC to your cluster

```bash
kubectl apply -f runner/namespace.yaml
kubectl apply -f runner/rbac.yaml
```

### 4. Create runner secrets in the cluster

Get a runner registration token:
- Go to `https://github.com/CodeJohnie/codejourney-ops` → Settings → Actions → Runners → New self-hosted runner
- Copy the token shown in the `--token` flag of the registration command

```bash
# Runner registration token (from step above)
kubectl create secret generic runner-secrets -n ci \
  --from-literal=RUNNER_TOKEN=<paste-runner-token-here>

# Kubeconfig scoped to your cluster
# If k3s: the default kubeconfig is at /etc/rancher/k3s/k3s.yaml on the node
# Copy it locally, then:
kubectl create secret generic runner-kubeconfig -n ci \
  --from-file=config=/path/to/your/kubeconfig
```

### 5. Deploy the runner pod

```bash
kubectl apply -f runner/deployment.yaml
```

Verify it registered:
```bash
kubectl logs -n ci deployment/github-runner
# Should show: "Runner successfully added"
```

Confirm in GitHub: Settings → Actions → Runners → you should see `k3s-homelab` as **Idle**.

### 6. Add GHCR_TOKEN secret to codejourney-ops repo

In GitHub → `codejourney-ops` repo → Settings → Secrets and variables → Actions:

| Secret name | Value |
|---|---|
| `GHCR_TOKEN` | The PAT you created in step 2 |

### 7. Add GHCR_TOKEN secret to CodeJourney repo

Same as above, but in the `CodeJourney` repo settings. The caller workflow passes it through to this pipeline.

### 8. Apply existing k8s manifests (first deploy only)

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/sealed-secret.yaml
kubectl apply -f k8s/service.yaml
kubectl apply -f k8s/tailscale-proxy.yaml
kubectl apply -f k8s/ingress-tailscale.yaml
```

The deployment itself will be created by the pipeline on first push.

### 9. Trigger a deploy

Push any commit to `main` in the CodeJourney repo. Watch it in:
- GitHub → CodeJourney → Actions tab
- `kubectl rollout status deployment/codejourney -n dev-testing`

---

## Repo structure

```
.github/workflows/
  pipeline.yml        # reusable workflow (called by CodeJourney)
k8s/
  namespace.yaml
  deployment.yaml     # IMAGE_PLACEHOLDER is substituted at deploy time
  service.yaml
  ingress-tailscale.yaml
  ingress.yaml
  sealed-secret.yaml  # encrypted secrets — safe to commit
  tailscale-proxy.yaml
runner/
  namespace.yaml      # ci namespace
  rbac.yaml           # ServiceAccount + Role scoped to dev-testing
  deployment.yaml     # self-hosted runner pod
```

---

## Rotating the runner token

Runner tokens expire. When the runner pod shows `Unauthorized`:

1. Generate a new token (GitHub → codejourney-ops → Settings → Actions → Runners → New runner)
2. `kubectl delete secret runner-secrets -n ci`
3. Re-run step 4 above
4. `kubectl rollout restart deployment/github-runner -n ci`
