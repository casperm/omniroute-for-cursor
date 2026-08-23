# OmniRoute AI Gateway for Cursor & Coding IDEs

[English](README.md) | [简体中文](doc/README.zh-CN.md) | [繁體中文](doc/README.zh-TW.md) | [한국어](doc/README.ko.md) | [日本語](doc/README.ja.md)

---

A self-hosted AI Gateway stack for **Cursor**, **Windsurf**, and **Claude Code** using **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)**, **Nginx**, and **Cloudflare Tunnel** packaged in **Docker Compose**.

It connects your coding IDEs and SDK clients to your self-hosted AI gateway over the public internet with **Server-Sent Events (SSE) streaming**, zero open router ports, and end-to-end abuse protection.

---

### 💡 Zero Token Anxiety: Intelligent Cost Optimization

![Zero Token Anxiety](doc/images/zero_token_anxiety.png)

---

## 🏛 Architecture Overview

![Architecture Overview](doc/images/architecture_overview.png)

### 4-Layer Defense-in-Depth

1. **Layer 1: Cloudflare Edge**: Drops volumetric DDoS attacks and malicious bots at the edge while terminating SSL.
2. **Layer 2: Zero Trust Access (Split-Path)**: Restricts Web UI to authorized SSO users while bypassing `/v1/*` for Bearer API keys.
3. **Layer 3: Nginx Reverse Proxy**:
   * Restores real client IP (`CF-Connecting-IP`) from official Cloudflare CIDRs.
   * Enforces multi-zone rate limits (API: 1 req/s, burst 10; Login: 5 req/min; UI: 10 req/s) and a 10 MiB body cap.
   * Provides unbuffered SSE streaming (`proxy_buffering off;`) with 600s timeouts.
4. **Layer 4: OmniRoute Application**: Validates API keys, enforces per-key spending limits, and manages provider failovers.

---

## 🚀 Quick Start Guide

### 1. Prerequisites & Cloudflare Tunnel Setup
1. Have [Docker](https://docs.docker.com/get-docker/) & Docker Compose installed.
2. Log in to the [Cloudflare Zero Trust Dashboard](https://one.dash.cloudflare.com/) (free tier).
3. Navigate to **Networks** > **Tunnels** > Click **Add a Tunnel** > Select **Cloudflared**.
4. Name your tunnel (e.g. `omniroute-tunnel`), select **Docker**, and copy the tunnel token (the value after `--token`).
5. In the **Public Hostnames** tab:
   * **Subdomain / Domain**: e.g., `ai` / `yourdomain.com` (`ai.yourdomain.com`).
   * **Service Type**: `HTTP`
   * **URL**: `nginx:80` (or `http://nginx:80`).
6. Save the tunnel configuration.

---

### 2. Configure Environment Variables
Copy the template and configure your secrets:
```bash
cp .env.example .env
```

Edit `.env`:
```bash
# Paste your Cloudflare Tunnel Token
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# Generate a strong admin password: openssl rand -base64 16
INITIAL_PASSWORD=<paste-generated-password-here>

# Generate a strong 64-character hex secret: openssl rand -hex 32
JWT_SECRET=<paste-generated-hex-here>

# Public URL for OAuth callbacks and secure cookies
NEXT_PUBLIC_BASE_URL=https://ai.yourdomain.com
BASE_URL=https://ai.yourdomain.com

# Default reproducible Node Alpine build
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1
OMNIROUTE_IMAGE=omniroute:3.8.49
```

Restrict file permissions:
```bash
chmod 600 .env
```

---

### 3. Build & Start the Stack
```bash
docker compose up -d
```

Verify service status:
```bash
docker compose ps
```

---

### 4. Cloudflare Zero Trust Access: Path-Based Bypassing & SSO Protection

To allow Cursor and SDKs to connect via Bearer API keys while keeping your Web Management UI secured behind SSO, configure path-based applications in the **Zero Trust Dashboard** (**Access** > **Applications**):

#### A. API Bypass (`/v1/*`)
1. Add a **Self-Hosted** application.
2. **Application Name**: `Bypass LLM API v1`
3. **Domain / Path**: `ai.yourdomain.com` / `v1/*`
4. **Policy**: Name `Allow API Traffic`, Action `Bypass`, Include `Everyone` (or specific IP ranges).

#### B. Health Check Bypass (`/health`)
1. Add a **Self-Hosted** application.
2. **Domain / Path**: `ai.yourdomain.com` / `health`
3. **Policy**: Action `Bypass`, Include `Everyone`.

#### C. Root Management SSO (`/`)
1. Add a **Self-Hosted** application covering the root domain (leave **Path** empty).
2. **Policy**: Action `Allow`, Include `Emails` (your email) or SSO identity groups (Google, GitHub).

> **How it works:** Cloudflare evaluates the most specific path first. API traffic (`/v1/*`) bypasses Cloudflare Access to authenticate directly against OmniRoute with Bearer tokens, while the Web UI (`/`, `/dashboard`) requires SSO authentication.

---

### 5. Cursor IDE Setup

1. Open **Cursor Settings** (`Cmd + ,` or `Ctrl + ,`) > **Models** > **OpenAI API Key**.
2. Enable **Override OpenAI Base URL**:
   * **Base URL**: `https://ai.yourdomain.com/v1`
   > **⚠️ Important:** You **must** use `https://`. Using `http://` causes Cloudflare/Nginx redirect issues and results in a **`405 Method Not Allowed`** error.
3. Under **OpenAI API Key**:
   * Enter the Gateway API Key generated in your OmniRoute Dashboard.
4. Test in Cursor Chat (`Cmd + L` or `Ctrl + L`). Tokens will stream progressively in real time.

---

### 6. Accessing the Web Dashboard

1. Navigate to `https://ai.yourdomain.com/`.
2. Authenticate through Cloudflare Access (SSO/Email OTP).
3. Log in with your `INITIAL_PASSWORD`.
4. Configure AI Provider API Keys (Anthropic, OpenAI, DeepSeek, Google Gemini, Ollama, etc.) and generate Gateway API Keys for your IDEs.

---

## 🧪 Verification & Testing

### 1. Test Health & Missing-Auth Rejection
```bash
# Health check (should return 200 OK)
curl https://ai.yourdomain.com/health

# Pre-filter check (missing auth should return 401 immediately)
curl -i https://ai.yourdomain.com/v1/chat/completions
```

### 2. Test Model Inference & Real-Time SSE Streaming
```bash
# Standard completion test
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "Hello!"}]}'

# Real-time SSE streaming test
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "stream": true, "messages": [{"role": "user", "content": "Count 1 to 5"}]}'
```

---

## 💰 Cloudflare Pricing: $0.00 / month (100% Free)

This deployment runs entirely within Cloudflare's permanent **Zero Trust Free Tier**:

| Cloudflare Service | What This Stack Uses | Free Tier Limits | Cost |
| :--- | :--- | :--- | :--- |
| **Cloudflare Tunnel (`cloudflared`)** | Encrypted outbound reverse proxy | **Unlimited tunnels & bandwidth** | **$0.00** |
| **Cloudflare Access (Zero Trust SSO)** | SSO / OTP protection for `/` dashboard | **Up to 50 active users** | **$0.00** |
| **Edge SSL / TLS Certificates** | Universal SSL on custom domain | **Unlimited auto-renewing SSL** | **$0.00** |
| **Data Egress** | Streaming model tokens to IDEs | **Zero egress fees** | **$0.00** |

---


## 🔐 Implemented Security Hardening

This stack implements defense-in-depth controls to safeguard private LLM provider credentials and prevent wallet exhaustion:

* **Hardened Container Runtime**: Minimal Alpine images (`node:22-alpine` or `oven/bun:alpine`), non-root system user execution with privilege dropping via `su-exec`, and signal handling with `dumb-init`.
* **Header Sanitization & Restricted CORS**: Unvalidated `Cf-Access-*` identity headers are stripped before proxying to OmniRoute; wildcard CORS is disabled to protect against cross-origin browser abuse.
* **Nginx Missing-Auth Pre-Filter**: Validates the presence of API credential headers (`Authorization`, `x-api-key`, `x-goog-api-key`) and immediately returns HTTP 401 for uncredentialed `/v1/*` requests before upstream processing.
* **Real IP Extraction & Trusted Proxy**: Restores original client IP via `CF-Connecting-IP` trusting only official Cloudflare CIDRs and the static tunnel container IP.

### Volumetric & Cost Limits

| Control | Value | Purpose |
| :--- | :--- | :--- |
| **API Request Rate** | 1 req/s (burst 10) per IP | Allows tool bursts while preventing high-rate automated scraping |
| **Active Inference Streams** | 8 per IP / 12 Global | Protects against connection exhaustion |
| **Per-Key Spend & Rate** | 60 RPM, 1,000 req/day, $10/day | Bounds blast radius if a client key is leaked |
| **Login Attempts** | 5 req/min (burst 5) | Mitigates brute-force attacks on Web UI |
| **Body Size / Stream Timeout** | 10 MiB / 600s | Blocks large memory amplification; supports long SSE generations |

---

*Built with Antigravity • Security settings verified with GPT Sol 5.6*

