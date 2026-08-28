# docker-cicd-sandbox

A beginner-friendly PoC that wires together **Go → Docker → GitHub Actions → EC2** so that every push to `main` automatically rebuilds the container image and redeploys it on your EC2 instance.

---

## Project layout

```
.
├── main.go                        # Go HTTP server
├── go.mod
├── Dockerfile                     # Multi-stage build → scratch image
├── scripts/
│   └── ec2-bootstrap.sh           # One-time EC2 Docker install script
└── .github/
    └── workflows/
        └── deploy.yml             # GitHub Actions: test → build → deploy
```

---

## How it works

```
git push main
      │
      ▼
┌─────────────┐     ┌──────────────────┐     ┌──────────────────────┐
│  GitHub     │────▶│  GitHub Actions  │────▶│  EC2 Instance        │
│  (main)     │     │                  │     │                      │
└─────────────┘     │  1. go test      │     │  docker pull <sha>   │
                    │  2. docker build │     │  docker stop go-app  │
                    │  3. docker push  │     │  docker run  go-app  │
                    └──────────────────┘     └──────────────────────┘
                           Docker Hub
```

---

## Prerequisites

| What | Where |
|---|---|
| Docker Hub account | https://hub.docker.com |
| AWS EC2 instance (Amazon Linux 2 or Ubuntu 22.04) | AWS Console |
| EC2 Security Group: inbound TCP 22 (SSH) + 80 (HTTP) | AWS Console |
| EC2 key pair `.pem` file | Downloaded when creating the instance |

---

## One-time setup

### 1 — Bootstrap Docker on EC2

SSH into your EC2 instance and run:

```bash
# Upload the script
scp -i your-key.pem scripts/ec2-bootstrap.sh ec2-user@<EC2-IP>:~

# SSH in and run it
ssh -i your-key.pem ec2-user@<EC2-IP>
sudo bash ~/ec2-bootstrap.sh
```

The script detects whether you're on Amazon Linux 2 or Ubuntu and installs Docker accordingly.

### 2 — Add GitHub Actions secrets

In your GitHub repo go to **Settings → Secrets and variables → Actions → New repository secret** and add:

| Secret name | Value |
|---|---|
| `DOCKERHUB_USERNAME` | Your Docker Hub username |
| `DOCKERHUB_TOKEN` | A Docker Hub [access token](https://hub.docker.com/settings/security) |
| `EC2_HOST` | Public IP or DNS of your EC2 instance |
| `EC2_USER` | `ec2-user` (Amazon Linux) or `ubuntu` (Ubuntu) |
| `EC2_SSH_KEY` | Full contents of your `.pem` private key |

### 3 — Push to main

```bash
git add .
git commit -m "initial commit"
git push origin main
```

GitHub Actions will:
1. Run `go test ./...`
2. Build the Docker image and push two tags to Docker Hub: `:latest` and `:<git-sha>`
3. SSH into EC2, pull the new image, stop the old container, and start the new one

---

## Local development

```bash
# Run directly
go run .

# Build & run with Docker
docker build -t go-cicd-app .
docker run -p 8080:8080 go-cicd-app
```

Open http://localhost:8080 — you should see the app page.  
Health check: http://localhost:8080/health → `{"status":"ok","version":"1.0.0"}`

---

## Making a change and watching it deploy

1. Edit [`main.go`](main.go) — for example change `version = "1.0.0"` to `"1.1.0"` or update the HTML in `homeHandler`.
2. Commit and push to `main`.
3. Watch the **Actions** tab in GitHub — the pipeline runs automatically.
4. Once the *Deploy to EC2* step turns green, refresh `http://<EC2-IP>` and see the updated version live.

---

## Pipeline stages

```
test  ──▶  build  ──▶  deploy
```

| Stage | What it does |
|---|---|
| `test` | `go test ./...` — fast gate, fails fast before wasting a build |
| `build` | `docker build` + `docker push` to Docker Hub (tagged with git SHA and `latest`) |
| `deploy` | SSH into EC2, `docker pull`, replace running container |

---

## Security notes

- The EC2 instance **only needs port 80 open** to the internet; port 22 is used by GitHub's runner IPs (or lock it to `0.0.0.0/0` for the PoC and tighten later).
- The Docker Hub token is a **read/write access token**, not your account password — you can revoke it any time.
- The SSH key secret never leaves GitHub's encrypted secret store.
- For production, consider: ECR instead of Docker Hub, IAM roles instead of SSH keys, and a load balancer in front of EC2.
