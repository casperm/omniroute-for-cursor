# OmniRoute + Nginx + Cloudflare Tunnel Deployment

[English](README.md) | [简体中文](doc/README.zh-CN.md) | [繁體中文](doc/README.zh-TW.md) | [한국어](doc/README.ko.md) | [日本語](doc/README.ja.md)

---

A production-grade, secure, and self-hosted AI Gateway deployment stack using **OmniRoute** (with custom **Alpine / Bun** runtime builds), **Nginx**, and **Cloudflare Tunnel** packaged in **Docker Compose**.

This setup allows tools like **Cursor IDE**, **Claude Code**, and custom OpenAI SDK clients to connect to your OmniRoute instance over the public internet with **low-latency Server-Sent Events (SSE) streaming**, without opening inbound firewall ports or exposing your origin server IP, all while protecting your endpoints against abuse.

---

## 🏛 Architecture

```mermaid
flowchart LR
    subgraph Clients["Clients"]
        Cursor[Cursor IDE / OpenAI SDK]
        AdminBrowser[Admin Browser]
    end

    subgraph Cloudflare["Cloudflare Edge Network"]
        CF_Edge["Cloudflare Edge (HTTPS/WAF/DDoS)"]
    end

    subgraph Host["Host Machine (Docker Compose)"]
        subgraph TunnelContainer["Cloudflare Tunnel"]
            Cloudflared["cloudflared\n(Outbound encrypted tunnel)"]
        end

        subgraph NginxContainer["Nginx Reverse Proxy"]
            Nginx["Nginx Engine"]
            RealIP["Real IP Extractor\n(CF-Connecting-IP)"]
            RateLimit["Rate Limiter & Anti-Abuse"]
            SSE["SSE Streaming (No Buffering)"]
        end

        subgraph OmniRouteContainer["OmniRoute (Alpine / Bun)"]
            Gateway["OmniRoute Engine (Port 20128)"]
            DB[(Persistent Data Volume)]
        end
    end

    subgraph Providers["AI Providers"]
        OpenAI[OpenAI / Anthropic / Groq / Google / DeepSeek]
    end

    Cursor -->|HTTPS /v1/...| CF_Edge
    AdminBrowser -->|HTTPS / or /dashboard| CF_Edge
    CF_Edge --> Cloudflared
    Cloudflared -->|http://nginx:80| Nginx
    Nginx --> RealIP --> RateLimit
    RateLimit -->|/v1/* (API Requests)| SSE --> Gateway
    RateLimit -->|/ (Dashboard Login)| Gateway
    Gateway --> DB
    Gateway --> Providers
```

---

## ⚡ Runtime & Image Options (Alpine & Bun)

This project includes custom, highly optimized Alpine multi-stage Dockerfiles:

| Runtime Option | Dockerfile | Image Size | Best For |
| :--- | :--- | :--- | :--- |
| **Node.js 22 Alpine** | `omniroute/Dockerfile.v1.1` | ~120 MB | 100% stable native modules (`better-sqlite3`, `libsecret`) with minimal memory footprint. |
| **Bun on Alpine** *(Default)* | `omniroute/Dockerfile.v1.1.bun` | ~90 MB | Sub-second cold starts, ultra-fast I/O throughput, and extreme low memory usage. |

You can switch runtimes in your `.env` file via `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` or `Dockerfile.v1.1`.

---

## ✨ Features & Security Protections

* **Custom Alpine / Bun Build**: Lightweight build with pre-installed native modules, non-root user privilege dropping (`su-exec`), and graceful signal handling (`dumb-init`).
* **Zero Inbound Port Exposure**: Cloudflare Tunnel creates an encrypted outbound-only tunnel to Cloudflare Edge. No router port forwarding or public static IP required.
* **Low-Latency SSE Streaming for Cursor**: Configured with `proxy_buffering off;`, `chunked_transfer_encoding on;`, and 600s proxy read timeouts to ensure real-time token streaming to Cursor without buffering lag.
* **Real Client IP Restoration**: Nginx uses `CF-Connecting-IP` and official Cloudflare IP ranges so rate limiting targets the actual client IP, not Cloudflare edge nodes.
* **Multi-Zone Rate Limiting**:
  * `/v1/` API Zone: `40 requests/second` (burst 50) for fast code completions and multi-file context requests.
  * `/` Web UI Zone: `30 requests/second` (burst 50) for smooth dashboard browsing.
  * `/_next/static/`: Static assets and media cached and exempted from rate limits.
* **Resource Exhaustion & Concurrency Limits**: Limits concurrent connections per IP (`limit_conn`) and enforces a 25MB body size limit.
* **Hardened Security Headers**: Injects OWASP security headers (`X-Frame-Options`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `Permissions-Policy`).

---

## 🚀 Quick Start Guide

### 1. Prerequisites
* [Docker](https://docs.docker.com/get-docker/) & Docker Compose installed.
* A domain managed on Cloudflare (free plan works).

---

### 2. Create a Cloudflare Tunnel
1. Log in to the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/).
2. Navigate to **Networks** > **Tunnels** > Click **Add a Tunnel**.
3. Select **Cloudflared** as the connector type and name your tunnel (e.g. `omniroute-tunnel`).
4. In the installation command section, select **Docker** and copy the tunnel token (the string following `--token`).
5. In the **Public Hostnames** tab:
   * **Subdomain / Domain**: e.g., `ai` / `yourdomain.com` (full URL: `ai.yourdomain.com`).
   * **Service Type**: `HTTP`
   * **URL**: `nginx:80` (or `http://nginx:80`).
6. Save the tunnel configuration.

---

### 3. Configure Environment Variables
Copy the example environment file:
```bash
cp .env.example .env
```

Edit `.env` and fill in your secrets:
```bash
# Paste your Cloudflare Tunnel Token
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# Set a strong admin password for the OmniRoute Web Dashboard
INITIAL_PASSWORD=YourSuperSecurePassword123!

# Generate a strong 64-character hex secret for JWT signing
JWT_SECRET=$(openssl rand -hex 32)

# Choose runtime (Dockerfile.v1.1.bun = Bun Alpine, Dockerfile.v1.1 = Node Alpine)
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun
OMNIROUTE_PKG_VERSION=latest
```

---

### 4. Build & Start the Stack
Start all services (Docker Compose will automatically build the image with your configured version):
```bash
docker compose up -d
```

Check the status of all containers:
```bash
docker compose ps
```

View live logs:
```bash
# View all logs
docker compose logs -f

# Or inspect specific services
docker compose logs -f nginx
docker compose logs -f omniroute
docker compose logs -f cloudflared
```

---

## 🛡️ Cloudflare Zero Trust Access: Path-Based Bypassing & SSO Protection

To bypass SSO interception for specific endpoints like `/v1/*` and `/health` while keeping your main LLM proxy UI secured, you must create separate Access Applications scoped to those specific paths. Cloudflare automatically prioritizes the most specific path when evaluating traffic.

Here is the accurate, step-by-step way to configure this:

### Step 1: Create the API Bypass Application
1. Go to your **Zero Trust Dashboard** -> navigate to **Access** > **Applications** -> click **Add an Application**.
2. Select **Self-Hosted**.
3. Under the **Application Configuration** section:
   * **Application Name**: `Bypass LLM API v1`
   * **Subdomain & Domain**: Enter your proxy's domain (e.g., `ai.yourdomain.com`).
   * **Path**: Enter `v1/*`.
4. Scroll to **Policies** and define the access rule:
   * **Policy Name**: `Allow API Traffic`
   * **Action**: `Bypass`
   * **Rule Type**:
     * **Include**: `Everyone` *(or select `IP Ranges` to restrict access to specific servers)*.
5. Save the application.

### Step 2: Create the Health Bypass Application
You will need to repeat the process to create a second, distinct application for the health check endpoint:
1. Create a new **Self-Hosted** application.
2. **Application Name**: `Bypass LLM Health`
3. **Subdomain & Domain**: Enter your proxy's domain (e.g., `ai.yourdomain.com`).
4. **Path**: Enter `health`.
5. Create an identical policy setting **Action**: `Bypass` and **Include**: `Everyone`.
6. Save the application.

### Step 3: Secure the Root Application
Ensure you have a main, root application covering the base domain:
1. Create or edit the root **Self-Hosted** application covering `ai.yourdomain.com` with the **Path field left completely empty**.
2. Define a strict policy:
   * **Action**: `Allow`
   * **Include / Require**: `Emails` *(e.g., `your-email@example.com`)* or identity groups (Google, GitHub SSO).

> **How it works:** Because Cloudflare processes the most specific path first, requests to your API (`/v1/*`) and health check (`/health`) will bypass authentication entirely (allowing Cursor IDE, Claude Code, and SDKs to connect via Bearer API keys), while standard web traffic (`/` and `/dashboard`) will hit the SSO prompt.

---

## 💻 Cursor IDE Setup

Once your stack is running and your domain is routed:

1. Open **Cursor Settings** (`Cmd + ,` or `Ctrl + ,`) -> **Models** -> **OpenAI API Key**.
2. Click **Override OpenAI Base URL**:
   * **Base URL**: `https://ai.yourdomain.com/v1` (replace with your Cloudflare hostname).
3. Under **OpenAI API Key**:
   * Enter the API Key generated in your OmniRoute Web Dashboard.
4. Test the connection in Cursor Chat (`Cmd + L` or `Ctrl + L`). Tokens will stream progressively in real time.

---

## 🔒 Accessing the Web Dashboard

1. Navigate in your browser to:
   ```
   https://ai.yourdomain.com/
   ```
2. Authenticate through Cloudflare Access (SSO/Email OTP).
3. Log in to the OmniRoute dashboard using your `INITIAL_PASSWORD` configured in `.env`.
4. Inside the Dashboard you can:
   * Configure AI Provider API Keys (OpenAI, Anthropic, DeepSeek, Groq, Google Gemini, OpenRouter, etc.).
   * Create Gateway API keys for your applications and IDEs.
   * View live usage logs, latency metrics, and token compression stats.
   * Monitor free-tier provider allocations (`/dashboard/free-tiers`).

---

## 🧪 Verification & Testing

### 1. Test Health Check
```bash
curl https://ai.yourdomain.com/health
# Response: {"status":"ok","service":"omniroute-proxy"}
```

### 2. Test Anti-Abuse Pre-Filter (Missing Auth)
```bash
curl -i https://ai.yourdomain.com/v1/chat/completions
# Response: HTTP/1.1 401 Unauthorized
```

### 3. Test OpenAI-Compatible Inference
```bash
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### 4. Test Real-Time SSE Token Streaming
```bash
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "stream": true,
    "messages": [{"role": "user", "content": "Count from 1 to 10 slowly"}]
  }'
```

---

## 📦 Remote PC Deployment (Build Locally, Deploy Standalone)

If your remote PC/server does not have build tools or you want a quick zero-dependency deployment, you can **compile and package the entire stack locally** into a single archive:

### 1. Build and Package Locally
```bash
# Package with Bun on Alpine (default):
./scripts/package.sh bun

# OR Package with Node.js Alpine:
./scripts/package.sh

# If your remote PC is ARM64 (e.g. Raspberry Pi, ARM cloud instance):
TARGET_PLATFORM=linux/arm64 ./scripts/package.sh
```

This generates a standalone deployment archive at `dist/omniroute-deploy-YYYYMMDD_HHMMSS.tar.gz` containing:
* The pre-compiled Docker image archive (`omniroute-image.tar.gz`).
* Nginx proxy configurations.
* Docker Compose file.
* Remote runner scripts (`start.sh` and `stop.sh`).

### 2. Copy and Launch on Remote PC
```bash
# 1. Copy the archive to your remote PC
scp dist/omniroute-deploy-*.tar.gz user@remote-server:/opt/omniroute/

# 2. On the remote PC:
ssh user@remote-server
cd /opt/omniroute/
tar -xzf omniroute-deploy-*.tar.gz

# 3. Configure secrets
cp .env.example .env
nano .env  # Add your CLOUDFLARE_TUNNEL_TOKEN & passwords

# 4. Start services (automatically loads the image and starts containers)
./start.sh
```

---

---

## 🚢 Build x64 Image on macOS (Colima) & Push to GitHub (GHCR)

You can cross-compile the x64 (`linux/amd64`) OmniRoute Docker image directly on your Mac (using **Colima** with Apple Silicon hardware-accelerated Rosetta emulation) and push it to **GitHub Container Registry (`ghcr.io`)** with **auto-incrementing version tags** starting from `1.0`.

### 1. Start Colima on macOS

On Apple Silicon (M1/M2/M3/M4), start Colima with Virtualization framework (`vz`) and Rosetta 2 enabled for near-native x86_64 compilation speed:

```bash
colima start --arch aarch64 --vm-type vz --vz-rosetta
```

*(Or standard start on Intel Mac: `colima start`)*

---

### 2. Authenticate with GitHub Container Registry

1. Generate a GitHub Personal Access Token (PAT):
   * Go to **GitHub** -> **Settings** -> **Developer settings** -> **Personal access tokens** -> **Tokens (classic)**.
   * Check scopes: `write:packages`, `read:packages`, `delete:packages`.
2. Log into GHCR via Docker CLI:
   ```bash
   echo $CR_PAT | docker login ghcr.io -u <your-github-username> --password-stdin
   ```

---

### 3. Build x64 Image & Publish with Auto-Incrementing Tags

Use the automated builder script:

```bash
# Auto-increments version (1.0 -> 1.1 -> 1.2), cross-compiles x64 Bun Alpine image, and pushes to GHCR:
./scripts/build-and-push.sh

# Or build Node.js Alpine runtime instead:
./scripts/build-and-push.sh node

# Or bump patch version instead of minor (e.g. 1.0.1):
./scripts/build-and-push.sh --bump patch

# Or pin an explicit tag:
./scripts/build-and-push.sh --tag 2.0.0

# Preview build command and tags without running (dry-run):
./scripts/build-and-push.sh --dry-run
```

**What the script does automatically:**
1. Validates Colima and Docker Buildx multi-platform capabilities.
2. Reads current version from `.image-version` (starts at `1.0`), and calculates next increment (e.g. `1.1`).
3. Cross-compiles the image for `linux/amd64` using Docker Buildx.
4. Pushes both `ghcr.io/<username>/omniroute:1.x` and `ghcr.io/<username>/omniroute:latest` to GHCR.
5. Advances `.image-version` and synchronizes `OMNIROUTE_IMAGE_TAG` into your local `.env`.

---

### 4. Deploy with Docker Compose using the GitHub Image

On your deployment server (or local machine):

1. Ensure your `.env` contains your GitHub username:
   ```ini
   GITHUB_USERNAME=your_github_username
   OMNIROUTE_IMAGE=ghcr.io/your_github_username/omniroute
   OMNIROUTE_IMAGE_TAG=1.0
   OMNIROUTE_PULL_POLICY=if_not_present
   ```

2. If your GHCR package is private, log into GHCR once on the server:
   ```bash
   echo $CR_PAT | docker login ghcr.io -u <your-github-username> --password-stdin
   ```
   *(Tip: You can make the package Public under GitHub: **Your Profile** -> **Packages** -> **omniroute** -> **Package Settings** -> **Change visibility** -> **Public**, removing the need for server authentication).*

3. Pull and run the stack:
   ```bash
   docker compose pull omniroute
   docker compose up -d
   ```

---

## 📁 Repository Structure

```
OmniRoute/
├── docker-compose.yaml             # Multi-container orchestration (GHCR image ready)
├── .env.example                    # Configuration template with GHCR settings
├── .image-version                  # Tracks current auto-incremented image version (1.0, 1.1...)
├── .gitignore                      # Git ignore rules for secrets, dist, and volumes
├── README.md                       # Deployment & usage documentation
├── scripts/
│   ├── build-and-push.sh           # Builds x64 image on Mac (Colima), tags & pushes to GHCR
│   └── package.sh                  # Builds & exports offline standalone deployment tarball
├── omniroute/
│   ├── Dockerfile.v1.1             # Production Node.js 22 on Alpine build
│   ├── Dockerfile.v1.1.bun         # High-performance Bun on Alpine build
│   ├── docker-entrypoint.sh        # Privilege dropping (su-exec) & volume permissions
│   └── data/                       # Persistent SQLite data directory
└── nginx/
    ├── nginx.conf                  # Core Nginx config & multi-zone rate limiting
    ├── conf.d/
    │   └── omniroute.conf          # Site routing, static asset caching, error handlers
    ├── logs/                       # Access and error logs
    └── includes/
        ├── cloudflare-real-ip.conf # Official Cloudflare IP CIDRs & CF-Connecting-IP
        ├── security-headers.conf   # OWASP security headers
        └── streaming-proxy.conf    # SSE, WebSocket & Cloudflare Access header forwarding
```

---

## 🛠 Maintenance & Commands

* **Update or Rebuild Image**:
  ```bash
  docker compose up -d --build
  ```
* **Switch Runtime**:
  Set `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` or `Dockerfile.v1.1` in `.env`, then run:
  ```bash
  docker compose up -d
  ```
* **Stop the Stack**:
  ```bash
  docker compose down
  ```

