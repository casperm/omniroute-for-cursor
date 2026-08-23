# OmniRoute AI Gateway for Cursor & 程式設計 IDE

[English](../README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

---

專為 **Cursor**、**Windsurf** 與 **Claude Code** 設計的自託管 AI 閘道部屬方案，基於 **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)**、**Nginx** 與 **Cloudflare Tunnel**，並透過 **Docker Compose** 打包。

讓您的程式設計 IDE 與 SDK 客戶端能透過公網安全連接至本地或私有 AI 閘道，支援 **Server-Sent Events (SSE) 串流傳輸**，無須在路由器上開啟任何入站連接埠，具備端到端的防濫用與預算防護機制。

---

### 💡 零 Token 焦慮：智慧成本最佳化

AI 程式設計助手在專案索引與多步驟 Agent 迴圈中可能消耗龐大 Token。OmniRoute 提供智慧路由策略以大幅降低成本：

![Zero Token Anxiety](images/zero_token_anxiety.png)

---

## 🏛 架構概觀

![Architecture Overview](images/architecture_overview.png)

### 4 層縱深防禦機制

1. **第 1 層：Cloudflare 邊緣防護**：在邊緣過濾大流量 DDoS 攻擊與惡意 Bot，並提供全球信任的 SSL 憑證。
2. **第 2 層：Zero Trust 存取控制（分流驗證）**：管理後台（Web UI）受 SSO 嚴密保護，`/v1/*` API 路徑則繞過 SSO 允許 Bearer API 金鑰直接通訊。
3. **第 3 層：Nginx 反向代理**：
   * 根據官方 Cloudflare CIDR 還原用戶端真實 IP (`CF-Connecting-IP`)。
   * 實施多區域速率限制（API：1 req/s，突發 10；登入：5 req/min；UI：10 req/s）及 10 MiB 請求本文上限。
   * 提供無緩衝的 SSE 即時串流回應 (`proxy_buffering off;`)，逾時設為 600 秒。
4. **第 4 層：OmniRoute 應用引擎**：負責權威 API Key 驗證、個別金鑰用量與工作階段限制，並管理上游模型渠道的自動容錯移轉。

---

## 🚀 快速入門指南

### 1. 前置需求與 Cloudflare Tunnel 設定
1. 安裝 [Docker](https://docs.docker.com/get-docker/) 與 Docker Compose。
2. 登入 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)（免費方案即可）。
3. 前往 **Networks** > **Tunnels** > 點擊 **Add a Tunnel** > 選擇 **Cloudflared**。
4. 為 Tunnel 命名（例如 `omniroute-tunnel`），選擇 **Docker**，複製 Token（`--token` 後方的字串）。
5. 在 **Public Hostnames** 索引標籤中：
   * **Subdomain / Domain**：例如 `ai` / `yourdomain.com`（完整網址為 `ai.yourdomain.com`）。
   * **Service Type**：`HTTP`
   * **URL**：`nginx:80`（或 `http://nginx:80`）。
6. 儲存 Tunnel 設定。

---

### 2. 設定環境變數
複製範本設定檔：
```bash
cp .env.example .env
```

編輯 `.env`：
```bash
# 貼上您的 Cloudflare Tunnel Token
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# 產生高強度管理員密碼：openssl rand -base64 16
INITIAL_PASSWORD=<貼上產生的密碼>

# 產生 64 位元 Hex 密鑰：openssl rand -hex 32
JWT_SECRET=<貼上產生的密鑰>

# 公網存取 URL（用於 OAuth 回呼與 Secure Cookie）
NEXT_PUBLIC_BASE_URL=https://ai.yourdomain.com
BASE_URL=https://ai.yourdomain.com

# 預設 Node Alpine 建置
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1
OMNIROUTE_IMAGE=omniroute:3.8.49
```

限制檔案權限：
```bash
chmod 600 .env
```

---

### 3. 建置並啟動服務
```bash
docker compose up -d
```

檢查容器運作狀態：
```bash
docker compose ps
```

---

### 4. Cloudflare Zero Trust 存取設定：路徑分流與 SSO 防護

為了讓 Cursor/SDK 能透過 Bearer 權杖直接呼叫 API，同時讓 Web 管理後台受到 SSO 保護，請於 **Zero Trust 控制台**（**Access** > **Applications**）中配置路徑規則：

#### A. API 略過應用 (`/v1/*`)
1. 新增 **Self-Hosted** 應用程式。
2. **Application Name**：`Bypass LLM API v1`
3. **Domain / Path**：`ai.yourdomain.com` / `v1/*`
4. **Policy**：名稱 `Allow API Traffic`，Action 選擇 `Bypass`，Include 選擇 `Everyone`（或指定 IP 範圍）。

#### B. 健康檢查略過應用 (`/health`)
1. 新增 **Self-Hosted** 應用程式。
2. **Domain / Path**：`ai.yourdomain.com` / `health`
3. **Policy**：Action 選擇 `Bypass`，Include 選擇 `Everyone`。

#### C. 根網域管理後台 SSO (`/`)
1. 新增涵蓋根網域的 **Self-Hosted** 應用程式（**Path** 保持為空）。
2. **Policy**：Action 選擇 `Allow`，Include 選擇 `Emails`（您的電子郵件）或 SSO 身分群組（Google、GitHub）。

> **運作機制：** Cloudflare 優先比對最明確的路徑。存取 `/v1/*` 時會略過 Cloudflare SSO，由 OmniRoute 驗證 Bearer API 金鑰；存取 `/` 與 `/dashboard` 時則強制觸發 SSO 登入驗證。

---

### 5. Cursor IDE 設定

1. 開啟 **Cursor Settings** (`Cmd + ,` 或 `Ctrl + ,`) > **Models** > **OpenAI API Key**。
2. 勾選並啟用 **Override OpenAI Base URL**：
   * **Base URL**：`https://ai.yourdomain.com/v1`
   > **⚠️ 重要提醒：** 必須使用 `https://`。使用 `http://` 會引發重新導向問題並產生 **`405 Method Not Allowed`** 錯誤。
3. 在 **OpenAI API Key** 欄位中：
   * 輸入在 OmniRoute 後台產生的 Gateway API Key。
4. 在 Cursor Chat (`Cmd + L` 或 `Ctrl + L`) 中測試，Token 將即時串流輸出。

---

### 6. 登入 Web 管理後台

1. 於瀏覽器開啟 `https://ai.yourdomain.com/`。
2. 透過 Cloudflare Access 完成 SSO/電子郵件驗證碼登入。
3. 輸入 `.env` 中設定的 `INITIAL_PASSWORD` 登入。
4. 設定各 AI 提供商的 API Key（Anthropic、OpenAI、DeepSeek、Google Gemini、Ollama 等），並為您的 IDE 建立網關金鑰。

---

## 🧪 驗證與測試

### 1. 測試健康檢查與未授權攔截
```bash
# 健康檢查（應回傳 200 OK）
curl https://ai.yourdomain.com/health

# 未授權預先攔截（無憑證應立即回傳 401）
curl -i https://ai.yourdomain.com/v1/chat/completions
```

### 2. 測試模型推論與即時 SSE 串流
```bash
# 一般請求測試
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "Hello!"}]}'

# 即時 SSE 串流測試
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "stream": true, "messages": [{"role": "user", "content": "Count 1 to 5"}]}'
```

---

## 💰 Cloudflare 費用說明：$0.00 / 月（完全免費）

本架構完全運行於 Cloudflare 永久免費的 **Zero Trust Free Tier**：

| Cloudflare 服務 | 本專案使用方式 | 免費方案額度 | 費用 |
| :--- | :--- | :--- | :--- |
| **Cloudflare Tunnel (`cloudflared`)** | 安全出站反向代理通道 | **無限制 Tunnel 與頻寬** | **$0.00** |
| **Cloudflare Access (Zero Trust SSO)** | `/` 管理後台的 SSO / OTP 保護 | **最多 50 位活躍使用者** | **$0.00** |
| **Edge SSL / TLS 憑證** | 自訂網域的 Universal SSL 憑證 | **無限自動續期 SSL** | **$0.00** |
| **Data Egress (出站流量)** | 將模型回應串流回傳至 IDE | **零傳輸費用** | **$0.00** |

---

## 🔐 安全強化與控制

本架構實施多層縱深防禦，以保護私有提供商憑證並避免帳單爆表：

* **強化的容器執行環境**：最小化 Alpine 映像檔（`node:22-alpine` 或 `oven/bun:alpine`），透過 `su-exec` 降權以非 root 使用者執行，並使用 `dumb-init` 妥善處理行程訊號。
* **標頭清理與嚴格 CORS**：向上游轉發前清除未經驗證的 `Cf-Access-*` 身分標頭；停用萬用字元 CORS 以防範跨來源瀏覽器濫用。
* **Nginx 未授權預先過濾**：預先檢查 `/v1/*` 請求是否帶有 API 憑證標頭（`Authorization`、`x-api-key`、`x-goog-api-key`），無憑證直接拒絕並回傳 401，減輕後端負擔。
* **真實 IP 還原與信任代理**：依據官方 Cloudflare CIDR 與靜態 Tunnel 容器 IP，透過 `CF-Connecting-IP` 精準還原真實用戶端 IP。

### 速率與額度限制

| 控制項目 | 設定值 | 目的 |
| :--- | :--- | :--- |
| **API 請求速率** | 每 IP 1 req/s (突發 10) | 允許 IDE 正常的工具短暫突發呼叫，同時防範自動化惡意抓取 |
| **活躍推論連線數** | 每 IP 8 / 全域 12 | 防範連線耗盡攻擊 |
| **個別金鑰用量與花費** | 60 RPM、1,000 req/天、$10/天 | 降低單一金鑰外洩時的損害範圍 |
| **登入嘗試** | 5 req/min (突發 5) | 防範針對管理後台的暴力密碼破解 |
| **請求本文 / 逾時** | 10 MiB / 600s | 限制大本文記憶體擴大風險，確保長文字 SSE 串流順暢 |

---

*Built with Antigravity • Security settings verified with GPT Sol 5.6*
