# docker-cicd-sandbox

A beginner-friendly PoC that wires together **Go → Docker → GitHub Actions → EC2**.  
Every push to `main` automatically tests, builds, and redeploys the app — no manual steps.

---

## Table of Contents

1. [What is CI/CD?](#1-what-is-cicd)
2. [Architecture overview](#2-architecture-overview)
3. [How each piece works](#3-how-each-piece-works)
   - [The Go app](#31-the-go-app)
   - [Docker & the Dockerfile](#32-docker--the-dockerfile)
   - [Docker Hub](#33-docker-hub)
   - [GitHub Actions pipeline](#34-github-actions-pipeline)
   - [EC2 — the server](#35-ec2--the-server)
4. [The full deploy flow, step by step](#4-the-full-deploy-flow-step-by-step)
5. [Project layout](#5-project-layout)
6. [Prerequisites](#6-prerequisites)
7. [One-time setup](#7-one-time-setup)
8. [Local development](#8-local-development)
9. [Making a change and watching it deploy](#9-making-a-change-and-watching-it-deploy)
10. [Security notes](#10-security-notes)

---

## 1. What is CI/CD?

**CI/CD** stands for **Continuous Integration / Continuous Deployment**.

| Term | Plain English |
|---|---|
| **Continuous Integration (CI)** | Every time a developer pushes code, it is automatically tested. If tests fail, the push is rejected before it can break anything. |
| **Continuous Deployment (CD)** | If tests pass, the code is automatically packaged and shipped to a live server — no human has to manually copy files or restart anything. |

> **Why does this matter?**  
> Without CI/CD, deployments are manual, error-prone, and stressful ("who forgot to restart the server?").  
> With CI/CD, deploying is as simple as `git push` — the pipeline handles everything else consistently every single time.

---

## 2. Architecture overview

```
 Your Laptop
 ┌──────────────────┐
 │  Edit  main.go   │
 │  git push main   │
 └────────┬─────────┘
          │  push event (webhook)
          ▼
 GitHub (source of truth)
 ┌──────────────────┐
 │  kshitijshettyyy │
 │  /docker-cicd-   │
 │   sandbox        │
 └────────┬─────────┘
          │  triggers workflow
          ▼
 GitHub Actions (CI/CD runner — a temporary Linux VM in the cloud)
 ┌─────────────────────────────────────────┐
 │                                         │
 │  Job 1: test                            │
 │  └─ go test ./...                       │
 │       │ pass                            │
 │  Job 2: build                           │
 │  └─ docker build  (multi-stage)         │
 │  └─ docker push ──────────────────────────────────┐
 │       │ success                         │          │
 │  Job 3: deploy                          │          ▼
 │  └─ SSH into EC2                        │   Docker Hub
 │  └─ docker pull  ◀──────────────────────────────────┘
 │  └─ docker stop  (old container)        │
 │  └─ docker run   (new container)        │
 │                                         │
 └────────────────────────┬────────────────┘
                          │  new container running
                          ▼
                 EC2 Instance (Ubuntu, t4g.nano)
                 ┌──────────────────────────────┐
                 │  Docker container: go-app     │
                 │  port 80 → 8080 inside        │
                 └──────────────────────────────┘
                          │
                          ▼
                 http://<EC2-IP>/         ← your live app
                 http://<EC2-IP>/health   ← health check
```

---

## 3. How each piece works

### 3.1 The Go app

[`main.go`](main.go) is a tiny HTTP server with two endpoints:

| Endpoint | What it returns |
|---|---|
| `GET /` | HTML page showing the app version and container hostname |
| `GET /health` | `{"status":"ok","version":"1.x.x"}` — used to verify the container is alive |

The `version` variable in `main.go` is the single string you change to prove a new deployment happened.

```
Browser → http://<EC2-IP>/ → Go server → HTML response
```

### 3.2 Docker & the Dockerfile

Docker solves the classic *"works on my machine"* problem.  
It packages your app and everything it needs (runtime, dependencies) into a single portable **image**.  
That image runs identically on your laptop, in GitHub Actions, and on EC2.

**This project uses a multi-stage build** — a best practice that keeps images small and secure:

```dockerfile
# Stage 1: builder  (golang:1.23-alpine, ~300 MB)
#   - Has the Go compiler
#   - Compiles main.go into a single static binary called "server"
#   - This stage is DISCARDED after building

# Stage 2: runtime  (scratch — completely empty, 0 MB base)
#   - Only copies the compiled "server" binary from Stage 1
#   - Final image size: ~7 MB  (just the binary, nothing else)
```

> **Why does image size matter?**  
> Smaller images pull faster (faster deploys), have fewer installed packages (smaller attack surface), and cost less to store.

```
Source code  →  docker build  →  Image (~7 MB)  →  docker run  →  Running container
```

A **container** is just a running instance of an image — like a process spawned from an executable.  
You can run many containers from the same image, stop them, and replace them without touching the host machine.

### 3.3 Docker Hub

Docker Hub is a **registry** — a place to store and share Docker images.  
It acts as the middleman between GitHub Actions (which builds the image) and EC2 (which runs it).

```
GitHub Actions  →  docker push  →  Docker Hub  →  docker pull  →  EC2
```

Each image is tagged with two identifiers:
- `:latest` — always points to the most recent build
- `:<git-sha>` — e.g. `:e7470a3f...` — an immutable tag tied to the exact commit that produced it

Using the git SHA tag means you can always trace exactly which commit is running in production.

### 3.4 GitHub Actions pipeline

[`.github/workflows/deploy.yml`](.github/workflows/deploy.yml) defines an automated pipeline with **three sequential jobs**.  
If any job fails, the next one does not run — protecting production from broken code.

```
┌──────────┐     ┌───────────┐     ┌──────────┐
│   test   │────▶│   build   │────▶│  deploy  │
└──────────┘     └───────────┘     └──────────┘
 go test ./...   docker build      SSH → EC2
                 docker push       docker pull
                 → Docker Hub      swap container
```

**Job 1 — `test`**  
Runs `go test ./...` on every push. Acts as a safety gate — catches broken code before wasting time on a build or risking a bad deploy.

**Job 2 — `build`**  
- Logs into Docker Hub using secrets stored in GitHub (never in code)
- Runs `docker build` using the multi-stage [`Dockerfile`](Dockerfile)
- Pushes the image to Docker Hub with both tags (`:latest` and `:<git-sha>`)

**Job 3 — `deploy`**  
- SSHs into the EC2 instance using the private key stored as a GitHub secret
- Runs a shell script on the EC2:
  1. `docker pull` — downloads the new image from Docker Hub
  2. `docker stop` + `docker rm` — gracefully stops and removes the old container
  3. `docker run` — starts the new container on port 80
  4. `docker image prune` — cleans up old unused images to save disk space

**Secrets** — sensitive values (Docker Hub token, SSH key, EC2 IP) are stored encrypted in GitHub's secret store. The pipeline reads them at runtime as `${{ secrets.NAME }}` — they are never written into code or log output.

### 3.5 EC2 — the server

An **EC2 instance** is a virtual machine rented from AWS that runs 24/7.  
This PoC uses a `t4g.nano` (ARM, 512 MB RAM) — the smallest and cheapest option, enough for a Go server.

The EC2 only needs two things installed:
1. **Docker** — to pull and run container images
2. **SSH access** — so GitHub Actions can connect and run the deploy script

The Security Group (AWS firewall) is configured to allow:
- Port `22` (SSH) — used by GitHub Actions runner to deploy
- Port `80` (HTTP) — used by browsers to access the app

---

## 4. The full deploy flow, step by step

Here is exactly what happens from the moment you type `git push` to your browser showing the new version:

```
Step 1  git push origin main
        └─ Your local git sends the new commit to GitHub

Step 2  GitHub receives the push
        └─ Detects .github/workflows/deploy.yml has trigger: push → branches: [main]
        └─ Spins up a fresh Ubuntu VM (the "runner") in GitHub's cloud

Step 3  Runner: Job "test" starts
        └─ Checks out your code
        └─ Installs Go 1.23
        └─ Runs: go test ./...
        └─ All tests pass → job succeeds

Step 4  Runner: Job "build" starts (only because "test" passed)
        └─ Logs into Docker Hub with DOCKERHUB_USERNAME + DOCKERHUB_TOKEN secrets
        └─ Runs: docker build -t username/go-cicd-app:<sha> .
           ├─ Stage 1: golang:1.23-alpine compiles main.go → binary "server"
           └─ Stage 2: scratch image copies only the binary
        └─ Runs: docker push username/go-cicd-app:<sha>
        └─ Runs: docker push username/go-cicd-app:latest
        └─ Image is now stored on Docker Hub

Step 5  Runner: Job "deploy" starts (only because "build" passed)
        └─ Opens an SSH connection to EC2 using EC2_SSH_KEY secret
        └─ Runs on EC2:
           ├─ docker pull username/go-cicd-app:<sha>
           │    (downloads new image from Docker Hub to EC2)
           ├─ docker stop go-app   (stops old container, gracefully)
           ├─ docker rm   go-app   (removes old container)
           ├─ docker run -d --name go-app -p 80:8080 username/go-cicd-app:<sha>
           │    (starts new container, -d means detached/background)
           └─ docker image prune -f  (removes old unused images)

Step 6  Browser hits http://<EC2-IP>/
        └─ EC2's port 80 forwards to port 8080 inside the container
        └─ Go server responds with the HTML page
        └─ Page shows the new version number ✅
```

Total time from `git push` to live: **~60–90 seconds**.

---

## 5. Project layout

```
.
├── main.go                        # Go HTTP server (the app)
├── main_test.go                   # Unit tests for the handlers
├── go.mod                         # Go module definition
├── Dockerfile                     # Multi-stage Docker build
├── scripts/
│   └── ec2-bootstrap.sh           # One-time Docker install script for EC2
└── .github/
    └── workflows/
        └── deploy.yml             # GitHub Actions CI/CD pipeline
```

---

## 6. Prerequisites

| What | Where |
|---|---|
| Docker Hub account | https://hub.docker.com |
| AWS EC2 instance (Ubuntu 22.04 or 24.04) | AWS Console |
| EC2 Security Group: inbound TCP 22 + 80 | AWS Console |
| EC2 key pair `.pem` file | Downloaded when creating the instance |

---

## 7. One-time setup

### Step 1 — Bootstrap Docker on EC2

```bash
# Upload the script from your laptop
scp -i your-key.pem scripts/ec2-bootstrap.sh ubuntu@<EC2-IP>:~

# SSH in and run it
ssh -i your-key.pem ubuntu@<EC2-IP>
sudo bash ~/ec2-bootstrap.sh

# Apply docker group without re-login
newgrp docker

# Verify
docker run --rm hello-world
```

### Step 2 — Add GitHub Actions secrets

Go to your repo → **Settings → Secrets and variables → Actions → New repository secret**:

| Secret name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | A Docker Hub [access token](https://hub.docker.com/settings/security) (not your password) |
| `EC2_HOST` | Public IP of your EC2 instance |
| `EC2_USER` | `ubuntu` |
| `EC2_SSH_KEY` | Full contents of your `.pem` file (including the `-----BEGIN...` lines) |

### Step 3 — Push to main

```bash
git add .
git commit -m "initial commit"
git push origin main
```

Watch the pipeline at **Actions** tab → three green checkmarks → app live at `http://<EC2-IP>`.

---

## 8. Local development

```bash
# Run directly with Go
go run .

# Run tests
go test ./...

# Build and run with Docker
docker build -t go-cicd-app .
docker run -p 8080:8080 go-cicd-app
```

- App: http://localhost:8080
- Health check: http://localhost:8080/health → `{"status":"ok","version":"1.1.0"}`

---

## 9. Making a change and watching it deploy

1. Open [`main.go`](main.go) and change `version = "1.1.0"` to `"1.2.0"`
2. Commit and push:
   ```bash
   git add main.go
   git commit -m "bump: version 1.2.0"
   git push origin main
   ```
3. Go to the **Actions** tab — watch `test → build → deploy` turn green
4. Refresh `http://<EC2-IP>` — the page now shows **Version: 1.2.0**

That's the entire CI/CD loop.

---

## 10. Security notes

- **Secrets in code = bad.** All sensitive values (tokens, keys, IPs) live in GitHub's encrypted secret store, never in files.
- **Docker Hub token** is a scoped access token, not your account password — revoke it any time from Docker Hub settings.
- **SSH key** never leaves GitHub's secret store — the runner uses it in memory only.
- **Image tags with git SHA** mean every running container is traceable to an exact commit.
- **For production**, consider: AWS ECR instead of Docker Hub, IAM roles + SSM instead of SSH keys, an Application Load Balancer in front of EC2, and a fixed Elastic IP so the address doesn't change on reboot.
