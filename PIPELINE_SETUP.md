# CodeJourney CI/CD Pipeline — Complete Setup Guide

> **What this guide does:** Every time you push code to the `main` branch of CodeJourney, it automatically builds a Docker image, pushes it to your home-lab registry, and deploys it to your Kubernetes cluster — all for free, with zero manual steps.

---

## Table of Contents

1. [How It Works — The Big Picture](#1-how-it-works--the-big-picture)
2. [Architecture Diagram](#2-architecture-diagram)
3. [What You Need Before Starting](#3-what-you-need-before-starting)
4. [Your Cluster Layout](#4-your-cluster-layout)
5. [Step-by-Step Setup](#5-step-by-step-setup)
   - [Step 1 — Create the Ops Repo on GitHub](#step-1--create-the-ops-repo-on-github)
   - [Step 2 — Create a GitHub Personal Access Token (PAT)](#step-2--create-a-github-personal-access-token-pat)
   - [Step 3 — Apply Kubernetes Namespaces and RBAC](#step-3--apply-kubernetes-namespaces-and-rbac)
   - [Step 4 — Create Cluster Secrets](#step-4--create-cluster-secrets)
   - [Step 5 — Deploy the Self-Hosted Runner](#step-5--deploy-the-self-hosted-runner)
   - [Step 6 — Add GitHub Secrets to Both Repos](#step-6--add-github-secrets-to-both-repos)
   - [Step 7 — Apply One-Time Kubernetes Manifests](#step-7--apply-one-time-kubernetes-manifests)
   - [Step 8 — Push to Main and Watch It Deploy](#step-8--push-to-main-and-watch-it-deploy)
6. [All the Files — What Each One Does](#6-all-the-files--what-each-one-does)
7. [Troubleshooting](#7-troubleshooting)
8. [Maintenance — The Only Thing That Ever Needs Updating](#8-maintenance--the-only-thing-that-ever-needs-updating)

---

## 1. How It Works — The Big Picture

```
YOU                 GITHUB                    YOUR HOME-LAB CLUSTER
───                 ──────                    ─────────────────────

git push main  ──►  CodeJourney repo          ┌─────────────────────────────┐
                    (.github/workflows/        │  ci namespace               │
                     deploy.yml)              │                             │
                         │                   │  ┌──────────────────────┐   │
                         │  repository_      │  │  Runner Pod          │   │
                         │  dispatch event   │  │  ┌────────────────┐  │   │
                         ▼                   │  │  │  github-runner │  │   │
                    codejourney-ops repo  ──► │  │  └────────────────┘  │   │
                    (.github/workflows/    │  │  │  ┌────────────────┐  │   │
                     pipeline.yml)        └──┼──┼─►│  buildkitd     │  │   │
                                             │  │  └────────────────┘  │   │
                                             │  └──────────────────────┘   │
                                             │           │                  │
                                             │    ┌──────▼──────┐          │
                                             │    │  Zot Registry│          │
                                             │    │  :30080      │          │
                                             │    └──────┬───────┘          │
                                             │           │                  │
                                             │    ┌──────▼──────────────┐   │
                                             │    │  dev-testing ns      │   │
                                             │    │  codejourney pod     │   │
                                             │    └─────────────────────┘   │
                                             └─────────────────────────────┘
```

**In plain English:**
1. You push code to `main` in CodeJourney
2. GitHub runs a tiny 10-second job that sends a signal to `codejourney-ops`
3. Your self-hosted runner (a pod inside your cluster) picks up the job
4. It builds your Docker image using BuildKit and pushes it to your Zot registry
5. It tells Kubernetes to roll out the new image
6. Your app is live with the new code — usually in under 3 minutes

**Why two repos?** All CI/CD logic lives in `codejourney-ops`. CodeJourney only has a 10-line trigger file. This keeps your app repo clean and means you never need to touch pipeline code when changing the app.

---

## 2. Architecture Diagram

### Infrastructure Layout

```
┌─────────────────────────────────────────────────────────────────┐
│                      HOME-LAB NETWORK (192.168.0.x)             │
│                                                                 │
│  ┌─────────────────┐   ┌──────────────┐   ┌──────────────┐    │
│  │   rpi-master     │   │   oddnode    │   │    odnode    │    │
│  │  192.168.0.45   │   │ 192.168.0.46 │   │ 192.168.0.47 │    │
│  │                 │   │              │   │              │    │
│  │  k3s control    │   │  k3s worker  │   │  k3s worker  │    │
│  │  plane          │   │              │   │              │    │
│  │  Ubuntu 24.04   │   │  Ubuntu 24.04│   │  Ubuntu 24.04│    │
│  │  ARM64          │   │  ARM64       │   │  ARM64       │    │
│  └────────┬────────┘   └──────┬───────┘   └──────┬───────┘    │
│           │                   │                   │            │
│           └───────────────────┴───────────────────┘            │
│                               │                                 │
│                    ┌──────────▼──────────┐                     │
│                    │   k3s cluster        │                     │
│                    │                     │                     │
│          ┌─────────┴──────────────────────────────┐           │
│          │                                        │           │
│   ┌──────▼────────┐  ┌──────────────┐  ┌────────▼──────┐    │
│   │  ci namespace  │  │  registry ns │  │ dev-testing ns │    │
│   │               │  │              │  │                │    │
│   │ github-runner  │  │  Zot         │  │ codejourney   │    │
│   │ (pod)         │  │  :30080      │  │ (pod)         │    │
│   │ + buildkitd   │  │  (registry)  │  │               │    │
│   │ (sidecar)     │  │              │  │ tailscale-    │    │
│   └───────────────┘  └──────────────┘  │ proxy (pod)   │    │
│                                        └────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                               │
                        Tailscale VPN
                               │
                    ┌──────────▼──────────┐
                    │  codejourney.        │
                    │  tail9d71dd.ts.net  │
                    │  (accessible from   │
                    │  anywhere via       │
                    │  Tailscale)         │
                    └─────────────────────┘
```

### Pipeline Flow (Step by Step)

```
┌──────────────────────────────────────────────────────────────────┐
│                      PIPELINE FLOW                               │
│                                                                  │
│  1. git push origin main                                         │
│         │                                                        │
│         ▼                                                        │
│  2. GitHub Actions — CodeJourney repo                            │
│     deploy.yml runs on ubuntu-latest (free GitHub runner)        │
│     Sends repository_dispatch event → codejourney-ops            │
│     ⏱ ~10 seconds                                               │
│         │                                                        │
│         ▼                                                        │
│  3. GitHub Actions — codejourney-ops repo                        │
│     pipeline.yml triggered by repository_dispatch               │
│     Picked up by self-hosted runner (k3s pod)                    │
│         │                                                        │
│         ├──► Checkout CodeJourney source code                    │
│         │                                                        │
│         ├──► Install nerdctl + buildctl (ARM64 binaries)         │
│         │                                                        │
│         ├──► Wait for buildkitd socket to be ready              │
│         │                                                        │
│         ├──► nerdctl build --platform linux/arm64               │
│         │    Builds Next.js standalone Docker image              │
│         │    Uses BuildKit layer cache (fast after first run)    │
│         │    ⏱ ~90s (cached) / ~5min (cold)                     │
│         │                                                        │
│         ├──► nerdctl push → Zot registry (192.168.0.45:30080)   │
│         │    Pushes image:sha + image:latest                     │
│         │                                                        │
│         ├──► kubectl set image deployment/codejourney            │
│         │    OR kubectl apply -f deployment.yaml (first time)    │
│         │                                                        │
│         └──► kubectl rollout status --timeout=120s              │
│              Waits for new pod to be healthy                     │
│              ⏱ ~30s                                             │
│                                                                  │
│  TOTAL: ~2-3 minutes per deploy                                  │
└──────────────────────────────────────────────────────────────────┘
```

### Runner Pod Architecture

```
┌─────────────────────────────────────────────────────┐
│              Runner Pod (ci namespace)               │
│                                                     │
│  ┌─────────────────────┐  ┌──────────────────────┐ │
│  │   github-runner      │  │     buildkitd        │ │
│  │   container          │  │     container        │ │
│  │                     │  │   (privileged)       │ │
│  │  Runs GitHub Actions │  │                     │ │
│  │  workflow steps      │  │  Builds Docker       │ │
│  │                     │  │  images without      │ │
│  │  BUILDKIT_HOST ─────┼──┼─► a Docker daemon    │ │
│  │  unix:///run/        │  │                     │ │
│  │  buildkit/           │  │  Shared socket:     │ │
│  │  buildkitd.sock      │  │  /run/buildkit/     │ │
│  └──────────┬───────────┘  └─────────────────────┘ │
│             │                                       │
│   Shared volumes:                                   │
│   /run/buildkit/buildkitd.sock  (emptyDir)          │
│   /run/k3s/containerd/containerd.sock (hostPath)    │
│                                                     │
│   ServiceAccount: github-runner                     │
│   RBAC: Role "deployer" in dev-testing namespace    │
└─────────────────────────────────────────────────────┘
```

---

## 3. What You Need Before Starting

### Things you need to have already

| # | What | Why |
|---|------|-----|
| 1 | A GitHub account | Free at github.com |
| 2 | Two GitHub repos created | `CodeJourney` (app) and `codejourney-ops` (pipeline) |
| 3 | A k3s cluster running | At least 1 control plane + 1 worker node |
| 4 | SSH access to your cluster nodes | e.g. `ssh rpi-main` works from your Mac |
| 5 | Zot container registry running in your cluster | NodePort `30080`, no auth required |
| 6 | Bitnami Sealed Secrets operator installed | For encrypted secrets in git |
| 7 | Tailscale operator installed | For remote access to your app |
| 8 | `gh` CLI installed on your Mac | `brew install gh && gh auth login` |
| 9 | `kubectl` installed on your Mac | `brew install kubectl` |

### Cost: $0

Everything used is free:
- **GitHub Actions** — free tier (2,000 minutes/month for private repos; unlimited for public)
- **GitHub repository dispatch** — free, runs on GitHub-hosted runners
- **Self-hosted runner** — runs on your own hardware, free forever
- **Zot registry** — open source, already running in your cluster
- **BuildKit** — open source image builder

---

## 4. Your Cluster Layout

| Node | IP | Role | OS |
|------|-----|------|----|
| `rpi-master` | `192.168.0.45` | control-plane | Ubuntu 24.04 ARM64 |
| `oddnode` | `192.168.0.46` | worker | Ubuntu 24.04 ARM64 |
| `odnode` | `192.168.0.47` | worker | Ubuntu 24.04 ARM64 |

| Namespace | What lives there |
|-----------|-----------------|
| `ci` | GitHub Actions self-hosted runner pod |
| `registry` | Zot container registry (NodePort 30080) |
| `dev-testing` | CodeJourney app + Tailscale proxy |

**SSH aliases used in this guide:**

```
ssh rpi-main   → connects to 192.168.0.45 (control plane)
ssh mainod     → connects to 192.168.0.46 (worker)
ssh dev        → connects to 192.168.0.47 (worker)
```

> **Note:** The `rpi-master` node has a `CriticalAddonsOnly=true:NoSchedule` taint, which means regular pods won't be scheduled on it. Your runner pod will land on one of the worker nodes automatically.

---

## 5. Step-by-Step Setup

> Follow these steps in order. Each one builds on the previous.

---

### Step 1 — Create the Ops Repo on GitHub

The `codejourney-ops` repo holds all CI/CD logic. It must be **public** so GitHub Actions can call its reusable workflows.

**1a. Create the repo on GitHub:**

Go to [github.com/new](https://github.com/new) and create a repo named `codejourney-ops`. Set it to **Public**.

**1b. Clone this repo's files to your Mac and push:**

```bash
# Clone the ops repo locally (it was already created as part of setup)
cd ~/codejourney-ops
git remote add origin https://github.com/YOUR_GITHUB_USERNAME/codejourney-ops.git
git push -u origin main
```

> Replace `YOUR_GITHUB_USERNAME` with your actual GitHub username or org name.

---

### Step 2 — Create a GitHub Personal Access Token (PAT)

This token lets the pipeline:
- Check out your private `CodeJourney` repo during builds
- Trigger the dispatch event from CodeJourney to codejourney-ops

**How to create it:**

1. Go to **GitHub → Settings** (click your avatar, top right)
2. Scroll down to **Developer settings** → **Personal access tokens** → **Fine-grained tokens**
3. Click **Generate new token**
4. Set a name like `codejourney-pipeline`
5. Under **Repository access** → select **Only select repositories** → choose both `CodeJourney` and `codejourney-ops`
6. Under **Permissions**, set:
   - `Contents` → **Read**
   - `Actions` → **Read and Write**
   - `Metadata` → **Read** (required, auto-selected)
7. Click **Generate token**
8. **Copy the token now** — you won't see it again

> **Save it somewhere safe** — you'll use it in Steps 4 and 6.

---

### Step 3 — Apply Kubernetes Namespaces and RBAC

This creates:
- The `ci` namespace where your runner lives
- A `ServiceAccount` for the runner
- A scoped `Role` that only lets the runner deploy to `dev-testing`

**Run this from your Mac:**

```bash
# Copy and apply the namespace
ssh rpi-main "kubectl apply -f -" << 'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: ci
EOF

# Copy and apply RBAC
scp ~/codejourney-ops/runner/rbac.yaml rpi-main:/tmp/rbac.yaml
ssh rpi-main "kubectl apply -f /tmp/rbac.yaml"
```

**What you should see:**
```
namespace/ci created
serviceaccount/github-runner created
role.rbac.authorization.k8s.io/deployer created
rolebinding.rbac.authorization.k8s.io/github-runner-deployer created
```

---

### Step 4 — Create Cluster Secrets

The runner needs two secrets:
1. **`runner-secrets`** — the GitHub runner registration token + your PAT
2. ~~`runner-kubeconfig`~~ — not needed! The runner uses its Kubernetes ServiceAccount directly

#### 4a. Get a Runner Registration Token

1. Go to **GitHub → your `codejourney-ops` repo**
2. Click **Settings** → **Actions** → **Runners**
3. Click **New self-hosted runner**
4. You'll see a command like `./config.sh --url ... --token XXXXXXXXXXX`
5. **Copy just the token** (the part after `--token`)

> ⚠️ This token expires after **1 hour**. Create it right before you run Step 5.

#### 4b. Create the secret in your cluster

```bash
ssh rpi-main "kubectl create secret generic runner-secrets -n ci \
  --from-literal=RUNNER_TOKEN=<paste-runner-token-here> \
  --from-literal=GHCR_TOKEN=<paste-your-PAT-here>"
```

Replace `<paste-runner-token-here>` and `<paste-your-PAT-here>` with the actual values.

**Verify it was created:**
```bash
ssh rpi-main "kubectl get secret runner-secrets -n ci"
```

---

### Step 5 — Deploy the Self-Hosted Runner

The runner is a Kubernetes pod with two containers:
- **`github-runner`** — the GitHub Actions runner that executes workflow steps
- **`buildkitd`** — the image builder (runs in privileged mode, needed to build Docker images without Docker)

```bash
scp ~/codejourney-ops/runner/deployment.yaml rpi-main:/tmp/runner-deployment.yaml
ssh rpi-main "kubectl apply -f /tmp/runner-deployment.yaml"
```

**Wait for both containers to be ready (2/2):**

```bash
ssh rpi-main "kubectl rollout status deployment/github-runner -n ci --timeout=300s"
```

> First time takes 3-5 minutes to pull the images. Subsequent restarts are instant.

**Verify the runner registered with GitHub:**

```bash
ssh rpi-main "kubectl logs -n ci deployment/github-runner -c runner --tail=10"
```

You should see:
```
√ Runner successfully added
√ Settings Saved.
√ Connected to GitHub
Listening for Jobs
```

**Confirm in GitHub:** Go to `codejourney-ops` → Settings → Actions → Runners. You should see `k3s-homelab` with a green **Idle** dot.

---

### Step 6 — Add GitHub Secrets to Both Repos

The PAT you created in Step 2 needs to be set as a secret in **both** repos.

**For codejourney-ops:**
```bash
gh secret set GHCR_TOKEN \
  --body "<paste-your-PAT-here>" \
  --repo YOUR_GITHUB_USERNAME/codejourney-ops
```

**For CodeJourney:**
```bash
gh secret set GHCR_TOKEN \
  --body "<paste-your-PAT-here>" \
  --repo YOUR_GITHUB_USERNAME/CodeJourney
```

**Verify both were set:**
```bash
gh secret list --repo YOUR_GITHUB_USERNAME/CodeJourney
gh secret list --repo YOUR_GITHUB_USERNAME/codejourney-ops
```

Both should show `GHCR_TOKEN` with a recent timestamp.

---

### Step 7 — Apply One-Time Kubernetes Manifests

These manifests set up the app's namespace, secrets, service, and networking. You only run these **once**. After this, the pipeline handles all future deploys.

```bash
# Copy all manifests to the master node
for f in namespace sealed-secret service ingress-tailscale tailscale-proxy; do
  scp ~/codejourney-ops/k8s/${f}.yaml rpi-main:/tmp/k8s-${f}.yaml
done

# Apply them in order
ssh rpi-main "
  kubectl apply -f /tmp/k8s-namespace.yaml
  kubectl apply -f /tmp/k8s-sealed-secret.yaml
  kubectl apply -f /tmp/k8s-service.yaml
  kubectl apply -f /tmp/k8s-ingress-tailscale.yaml
  kubectl apply -f /tmp/k8s-tailscale-proxy.yaml
"
```

**Verify everything is running:**
```bash
ssh rpi-main "kubectl get all -n dev-testing"
```

---

### Step 8 — Push to Main and Watch It Deploy

Everything is set up. Now trigger your first automated deploy:

```bash
cd ~/CodeJourney
git commit --allow-empty -m "ci: trigger first automated deploy"
git push origin main
```

**Watch the pipeline:**

In GitHub, go to **CodeJourney → Actions**. You'll see the `Deploy` workflow running. It dispatches to codejourney-ops in about 10 seconds.

Then go to **codejourney-ops → Actions** to watch the full build pipeline.

**Or watch from the terminal:**
```bash
# Watch the ops pipeline
gh run list --repo YOUR_GITHUB_USERNAME/codejourney-ops --limit 5

# Watch the Kubernetes rollout
ssh rpi-main "kubectl rollout status deployment/codejourney -n dev-testing"

# Check the pod is healthy
ssh rpi-main "kubectl get pods -n dev-testing"
```

**What success looks like:**
```
✓ main  Deploy Pipeline  ·  codejourney-ops  (2m 0s)
  ✓ Set up job
  ✓ Checkout CodeJourney source
  ✓ Install nerdctl and buildctl
  ✓ Wait for buildkitd
  ✓ Build and push image to Zot
  ✓ Install kubectl
  ✓ Checkout ops repo (for k8s manifests)
  ✓ Substitute image and apply manifests
```

---

## 6. All the Files — What Each One Does

### `codejourney-ops` repo structure

```
codejourney-ops/
│
├── .github/
│   └── workflows/
│       └── pipeline.yml          ← THE main CI/CD pipeline
│                                    Triggered by repository_dispatch
│                                    Runs on self-hosted runner
│
├── k8s/                          ← Kubernetes manifests for the app
│   ├── namespace.yaml            ← Creates dev-testing namespace
│   ├── deployment.yaml           ← App deployment (IMAGE_PLACEHOLDER replaced at deploy)
│   ├── service.yaml              ← ClusterIP service on port 80
│   ├── ingress-tailscale.yaml    ← Tailscale ingress (VPN access)
│   ├── ingress.yaml              ← Traefik ingress (local network)
│   ├── sealed-secret.yaml        ← Encrypted app secrets (safe to commit)
│   └── tailscale-proxy.yaml      ← Tailscale proxy StatefulSet + RBAC
│
└── runner/
    ├── namespace.yaml            ← Creates ci namespace
    ├── rbac.yaml                 ← ServiceAccount + Role for the runner
    └── deployment.yaml           ← Runner pod (github-runner + buildkitd)
```

### `CodeJourney` repo — the only CI/CD file

```
CodeJourney/
└── .github/
    └── workflows/
        └── deploy.yml            ← 10-line trigger only
                                     Sends dispatch event on push to main
                                     Runs on free GitHub-hosted runner
```

### Key files explained

#### `.github/workflows/deploy.yml` (in CodeJourney)

```yaml
name: Deploy

on:
  push:
    branches: [main]          # Triggers on every push to main

jobs:
  trigger:
    runs-on: ubuntu-latest    # Free GitHub-hosted runner, 10 seconds
    steps:
      - name: Dispatch deploy to codejourney-ops
        uses: peter-evans/repository-dispatch@v3
        with:
          token: ${{ secrets.GHCR_TOKEN }}        # Your PAT
          repository: YOUR_ORG/codejourney-ops    # Ops repo
          event-type: deploy
          client-payload: '{"sha": "${{ github.sha }}"}'  # Sends the git SHA
```

#### `.github/workflows/pipeline.yml` (in codejourney-ops)

```yaml
on:
  repository_dispatch:
    types: [deploy]           # Triggered by CodeJourney's deploy.yml

env:
  REGISTRY: 192.168.0.45:30080   # Your Zot NodePort
  APP: codejourney

jobs:
  build-and-deploy:
    runs-on: [self-hosted, k3s]  # Must match runner labels

    steps:
      # 1. Get the source code at the exact commit that was pushed
      - uses: actions/checkout@v4
        with:
          repository: YOUR_ORG/CodeJourney
          ref: ${{ github.event.client_payload.sha }}
          token: ${{ secrets.GHCR_TOKEN }}

      # 2. Install build tools (ARM64 binaries, downloaded each run)
      - name: Install nerdctl and buildctl
        ...

      # 3. Wait for the buildkitd sidecar to be ready
      - name: Wait for buildkitd
        run: until buildctl --addr unix:///run/buildkit/buildkitd.sock debug workers; do sleep 2; done

      # 4. Build the Docker image and push to your Zot registry
      - name: Build and push image to Zot
        run: |
          nerdctl --insecure-registry build --platform linux/arm64 -t "${IMAGE}" -t "${LATEST}" .
          nerdctl --insecure-registry push "${IMAGE}"
          nerdctl --insecure-registry push "${LATEST}"

      # 5. Roll out the new image to the cluster
      - name: Substitute image and apply manifests
        run: |
          kubectl set image deployment/codejourney codejourney="${IMAGE}" -n dev-testing
          kubectl rollout status deployment/codejourney -n dev-testing --timeout=120s
```

---

## 7. Troubleshooting

### Problem: Runner shows "Unauthorized" and won't register

**Cause:** The runner registration token expired (they're valid for 1 hour, one-time use).

**Fix:**
```bash
# Get a new token from GitHub:
# codejourney-ops → Settings → Actions → Runners → New self-hosted runner
# Copy the --token value, then:

NEW_TOKEN="paste-new-token-here"

ssh rpi-main "kubectl create secret generic runner-secrets -n ci \
  --from-literal=RUNNER_TOKEN=${NEW_TOKEN} \
  --from-literal=GHCR_TOKEN=<your-PAT> \
  --dry-run=client -o yaml | kubectl apply -f -"

ssh rpi-main "kubectl rollout restart deployment/github-runner -n ci"
```

---

### Problem: Pipeline job is "queued" for more than 5 minutes

**Cause:** The runner lost its connection to GitHub after a job completed.

**Fix:**
```bash
# Generate a fresh token (see above) then restart the runner
ssh rpi-main "kubectl rollout restart deployment/github-runner -n ci"

# Wait for it to re-register
ssh rpi-main "kubectl logs -n ci deployment/github-runner -c runner -f"
# Look for: "Listening for Jobs"
```

---

### Problem: `ErrImagePull` — can't pull image from Zot

**Cause:** The image reference uses a hostname that the node can't resolve, or TLS is expected but Zot is HTTP-only.

**Fix:** Make sure `/etc/rancher/k3s/registries.yaml` exists on **every node** with this content:

```yaml
mirrors:
  "192.168.0.45:30080":
    endpoint:
      - "http://192.168.0.45:30080"
```

After creating or editing this file, restart k3s on that node:
```bash
ssh rpi-main "sudo systemctl restart k3s"
ssh mainod   "sudo systemctl restart k3s-agent"
ssh dev      "sudo systemctl restart k3s-agent"
```

---

### Problem: `kubectl rollout status` times out

**Cause:** The new pod isn't becoming Ready. Usually the app is failing its health check or can't start.

**Diagnose:**
```bash
# Check what's happening with the new pod
ssh rpi-main "kubectl describe pod -n dev-testing -l app=codejourney | tail -30"

# Check the app logs
ssh rpi-main "kubectl logs -n dev-testing -l app=codejourney --tail=50"
```

---

### Problem: `watch` permission denied on rollout status

**Cause:** The runner's RBAC Role is missing the `watch` verb.

**Fix:**
```bash
scp ~/codejourney-ops/runner/rbac.yaml rpi-main:/tmp/rbac.yaml
ssh rpi-main "kubectl apply -f /tmp/rbac.yaml"
```

---

### Problem: Kubernetes dashboard only shows `default` namespace

**Cause:** The dashboard is showing a limited view — your namespaces exist, it just defaults to `default`.

**Fix:** Click the namespace dropdown in the top-left of the dashboard and select **All namespaces**.

If it still can't see them, run:
```bash
ssh rpi-main "kubectl get clusterrolebinding dashboard-admin 2>/dev/null || \
  kubectl create clusterrolebinding dashboard-admin \
  --clusterrole=cluster-admin \
  --serviceaccount=kubernetes-dashboard:kubernetes-dashboard"
```

---

### Problem: nerdctl build fails — "buildkitd not running"

**Cause:** The buildkitd sidecar container hasn't started yet when the pipeline runs.

**Check:** The pipeline already has a `Wait for buildkitd` step that polls until it's ready. If this still fails, check the sidecar:

```bash
ssh rpi-main "kubectl logs -n ci \$(kubectl get pod -n ci -l app=github-runner -o name) -c buildkitd"
```

---

## 8. Maintenance — The Only Thing That Ever Needs Updating

Once set up, this pipeline is designed to be **maintenance-free**. The only thing that will ever need rotating is the **GitHub runner registration token**.

### When does this happen?

The runner pod will log `Unauthorized` and fail to pick up jobs. This happens when:
- The pod is restarted (token used at startup)
- The runner was re-registered

### How to rotate (takes 2 minutes)

```bash
# 1. Generate a new token:
#    codejourney-ops → Settings → Actions → Runners → New self-hosted runner
#    Copy the token shown after --token

# 2. Update the secret and restart:
NEW_TOKEN="paste-new-token-here"

ssh rpi-main "kubectl create secret generic runner-secrets -n ci \
  --from-literal=RUNNER_TOKEN=${NEW_TOKEN} \
  --from-literal=GHCR_TOKEN=<your-PAT> \
  --dry-run=client -o yaml | kubectl apply -f -"

ssh rpi-main "kubectl rollout restart deployment/github-runner -n ci"

# 3. Verify it's listening:
ssh rpi-main "kubectl logs -n ci deployment/github-runner -c runner --tail=5"
# Should show: "Listening for Jobs"
```

> **Tip:** Set a calendar reminder to do this every 90 days, or just do it whenever a deploy fails with "Unauthorized".

---

## Quick Reference

### Check pipeline status
```bash
gh run list --repo YOUR_ORG/codejourney-ops --limit 5
```

### Watch a deploy live
```bash
ssh rpi-main "kubectl rollout status deployment/codejourney -n dev-testing -w"
```

### Check runner is healthy
```bash
ssh rpi-main "kubectl get pods -n ci"
# Should show: github-runner-xxxxx   2/2   Running
```

### View app logs
```bash
ssh rpi-main "kubectl logs -n dev-testing -l app=codejourney -f --tail=50"
```

### Roll back a bad deploy
```bash
ssh rpi-main "kubectl rollout undo deployment/codejourney -n dev-testing"
```

### Force re-deploy without a code change
```bash
cd ~/CodeJourney
git commit --allow-empty -m "ci: force redeploy"
git push origin main
```
