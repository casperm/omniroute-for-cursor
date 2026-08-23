# OmniRoute AI Gateway for Cursor & 编程 IDE

[English](../README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

---

一个专为 **Cursor**、**Windsurf** 和 **Claude Code** 打造的自托管 AI 网关部署方案，基于 **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)**、**Nginx** 和 **Cloudflare Tunnel**，并使用 **Docker Compose** 打包。

它让您的编程 IDE 和 SDK 客户端能够通过公网安全连接到本地或私有 AI 网关，支持 **Server-Sent Events (SSE) 流式传输**，无需路由器开放入站端口，具备端到端的防滥用与预算保护能力。

---

### 💡 零 Token 焦虑：智能成本优化

AI 编程助手在项目索引和多步 Agent 循环中可能消耗海量 Token。OmniRoute 提供了智能路由策略以优化成本：

![Zero Token Anxiety](images/zero_token_anxiety.png)

---

## 🏛 架构概览

![Architecture Overview](images/architecture_overview.png)

### 4 层深度防御机制

1. **第 1 层：Cloudflare 边缘防护**：在边缘层过滤大流量 DDoS 攻击和恶意 Bot，并提供全球 SSL 证书。
2. **第 2 层：Zero Trust 访问控制（分流鉴权）**：管理后台（Web UI）受 SSO 严格保护，`/v1/*` API 路径则绕过 SSO 允许 Bearer API 密钥直接通信。
3. **第 3 层：Nginx 反向代理**：
   * 基于官方 Cloudflare CIDR 还原客户端真实 IP (`CF-Connecting-IP`)。
   * 实施多区域速率限制（API：1 req/s，突发 10；登录：5 req/min；UI：10 req/s）及 10 MiB 请求体限制。
   * 提供无缓冲的 SSE 实时流式响应 (`proxy_buffering off;`)，设置 600 秒超时。
4. **第 4 层：OmniRoute 应用引擎**：负责权威 API Key 校验、单 Key 消费与会话限制，并管理上游渠道的自动故障切换。

---

## 🚀 快速上手指南

### 1. 前置条件与 Cloudflare Tunnel 配置
1. 安装 [Docker](https://docs.docker.com/get-docker/) 和 Docker Compose。
2. 登录 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)（免费版即可）。
3. 前往 **Networks** > **Tunnels** > 点击 **Add a Tunnel** > 选择 **Cloudflared**。
4. 命名 Tunnel（例如 `omniroute-tunnel`），选择 **Docker**，复制 Token（`--token` 后的字符串）。
5. 在 **Public Hostnames** 标签页中：
   * **Subdomain / Domain**：例如 `ai` / `yourdomain.com`（完整域名为 `ai.yourdomain.com`）。
   * **Service Type**：`HTTP`
   * **URL**：`nginx:80`（或 `http://nginx:80`）。
6. 保存 Tunnel 配置。

---

### 2. 配置环境变量
复制示例配置文件：
```bash
cp .env.example .env
```

编辑 `.env`：
```bash
# 粘贴您的 Cloudflare Tunnel Token
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# 生成强管理员密码：openssl rand -base64 16
INITIAL_PASSWORD=<粘贴生成的密码>

# 生成 64 位 Hex 秘钥：openssl rand -hex 32
JWT_SECRET=<粘贴生成的密钥>

# 公网访问 URL（用于 OAuth 回调与 Secure Cookie）
NEXT_PUBLIC_BASE_URL=https://ai.yourdomain.com
BASE_URL=https://ai.yourdomain.com

# 默认 Node Alpine 构建
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1
OMNIROUTE_IMAGE=omniroute:3.8.49
```

限制权限：
```bash
chmod 600 .env
```

---

### 3. 构建并启动服务
```bash
docker compose up -d
```

查看容器状态：
```bash
docker compose ps
```

---

### 4. Cloudflare Zero Trust 访问配置：路径分流与 SSO 保护

为让 Cursor/SDK 能通过 Bearer 令牌直接访问 API，同时将 Web 管理后台置于 SSO 保护下，请在 **Zero Trust 控制台**（**Access** > **Applications**）中配置路径策略：

#### A. API 绕过应用 (`/v1/*`)
1. 添加 **Self-Hosted** 应用。
2. **Application Name**：`Bypass LLM API v1`
3. **Domain / Path**：`ai.yourdomain.com` / `v1/*`
4. **Policy**：名称 `Allow API Traffic`，Action 选择 `Bypass`，Include 选择 `Everyone`（或指定 IP 范围）。

#### B. 健康检查绕过应用 (`/health`)
1. 添加 **Self-Hosted** 应用。
2. **Domain / Path**：`ai.yourdomain.com` / `health`
3. **Policy**：Action 选择 `Bypass`，Include 选择 `Everyone`。

#### C. 根域名管理后台 SSO (`/`)
1. 添加覆盖根域名的 **Self-Hosted** 应用（**Path** 保持为空）。
2. **Policy**：Action 选择 `Allow`，Include 选择 `Emails`（您的邮箱）或 SSO 身份组（Google、GitHub）。

> **原理说明：** Cloudflare 优先匹配最具体的路径。访问 `/v1/*` 时将绕过 Cloudflare SSO，由 OmniRoute 验证 Bearer API 密钥；访问 `/` 和 `/dashboard` 时则强制触发 SSO 验证。

---

### 5. Cursor IDE 配置

1. 打开 **Cursor Settings** (`Cmd + ,` 或 `Ctrl + ,`) > **Models** > **OpenAI API Key**。
2. 勾选并启用 **Override OpenAI Base URL**：
   * **Base URL**：`https://ai.yourdomain.com/v1`
   > **⚠️ 重要：** 必须使用 `https://`。使用 `http://` 会触发重定向问题并导致 **`405 Method Not Allowed`** 错误。
3. 在 **OpenAI API Key** 中：
   * 输入在 OmniRoute 管理后台生成的 Gateway API Key。
4. 在 Cursor Chat (`Cmd + L` 或 `Ctrl + L`) 中测试，Token 将实时流式输出。

---

### 6. 访问 Web 管理后台

1. 在浏览器中打开 `https://ai.yourdomain.com/`。
2. 通过 Cloudflare Access 完成 SSO/邮箱验证码认证。
3. 输入 `.env` 中配置的 `INITIAL_PASSWORD` 登录。
4. 配置各大 AI 提供商的 API Key（Anthropic、OpenAI、DeepSeek、Google Gemini、Ollama 等），并为您的 IDE 创建网关密钥。

---

## 🧪 验证与测试

### 1. 测试健康检查与未鉴权拦截
```bash
# 健康检查（应返回 200 OK）
curl https://ai.yourdomain.com/health

# 未鉴权预拦截（无凭证应立即返回 401）
curl -i https://ai.yourdomain.com/v1/chat/completions
```

### 2. 测试模型推理与实时 SSE 流
```bash
# 普通请求测试
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "Hello!"}]}'

# 实时 SSE 流式测试
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "stream": true, "messages": [{"role": "user", "content": "Count 1 to 5"}]}'
```

---

## 💰 Cloudflare 费用说明：$0.00 / 月（完全免费）

本项目运行在 Cloudflare 永久免费的 **Zero Trust Free Tier** 上：

| Cloudflare 服务 | 本项目使用场景 | 免费额度 | 费用 |
| :--- | :--- | :--- | :--- |
| **Cloudflare Tunnel (`cloudflared`)** | 安全出站反向代理通道 | **无限制 Tunnel 与带宽** | **$0.00** |
| **Cloudflare Access (Zero Trust SSO)** | `/` 管理后台的 SSO / OTP 保护 | **最多 50 名活跃用户** | **$0.00** |
| **Edge SSL / TLS 证书** | 自定义域名的 Universal SSL 证书 | **无限自动续期 SSL** | **$0.00** |
| **Data Egress (出站流量)** | 将模型响应流回 IDE | **免流量费** | **$0.00** |

---

## 🔐 安全加固与控制

本方案采用多层纵深防御，保护私有提供商凭据并防止账单超支：

* **加固的容器运行时**：最小化 Alpine 镜像（`node:22-alpine` 或 `oven/bun:alpine`），使用 `su-exec` 降权以非 root 用户运行，采用 `dumb-init` 管理进程信号。
* **头部清洗与限制 CORS**：向上游转发前剥离未经校验的 `Cf-Access-*` 身份头；禁用通配符 CORS 防止跨站浏览器滥用。
* **Nginx 未鉴权预拦截**：预检 `/v1/*` 请求是否包含 API 凭据头（`Authorization`、`x-api-key`、`x-goog-api-key`），无凭证直接返回 401，减轻后端开销。
* **真实 IP 还原与受信任代理**：基于官方 Cloudflare CIDR 与静态 Tunnel 容器 IP，通过 `CF-Connecting-IP` 还原真实客户端 IP。

### 速率与额度限制

| 控制项 | 配置值 | 目的 |
| :--- | :--- | :--- |
| **API 请求速率** | 单 IP 1 req/s (突发 10) | 允许 IDE 正常工具突发调用，同时防止自动化批量抓取 |
| **活跃推理并发** | 单 IP 8 / 全局 12 | 防止连接耗尽攻击 |
| **单 Key 额度与限额** | 60 RPM、1,000 req/天、$10/天 | 降低单个客户端密钥泄露后的影响面 |
| **登录尝试** | 5 req/min (突发 5) | 防止针对管理后台的暴力破解 |
| **请求体 / 超时时间** | 10 MiB / 600s | 防止大请求体内存放大，保障超长 SSE 生成不中断 |

---

*Built with Antigravity • Security settings verified with GPT Sol 5.6*
