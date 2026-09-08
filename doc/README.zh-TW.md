# OmniRoute + Nginx + Cloudflare Tunnel 部署指南

[English](../README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

---

這是一個企業級、安全且支援自託管的 AI 閘道（AI Gateway）部署方案，基於 **OmniRoute**（提供最佳化的 **Alpine / Bun** 極速執行環境建置）、**Nginx** 反向代理與 **Cloudflare Tunnel**，並透過 **Docker Compose** 進行容器化編排。

此方案支援 **Cursor IDE**、**Claude Code** 以及各類基於 OpenAI SDK 開發的用戶端，透過公用網際網路以**超低延遲 Server-Sent Events (SSE) 串流傳輸**直連您的 OmniRoute 實例。無需在路由器開放任何輸入埠（Inbound Port），無需暴露來源伺服器的公網 IP，同時內建全方位防濫用與速率限制保護。

---

## 🏛 架構設計

![Architecture Overview](images/architecture_overview.png)

---

## ⚡ 執行環境與映像檔選項 (Alpine & Bun)

本專案包含專屬深度最佳化的 Alpine 多階段 Docker 建置檔：

| 執行環境選項 | Dockerfile | 映像檔大小 | 適用情境 |
| :--- | :--- | :--- | :--- |
| **Node.js 22 Alpine** | `omniroute/Dockerfile.v1.1` | ~120 MB | 原生 C++ 模組 (`better-sqlite3`, `libsecret`) 相容性極高，記憶體佔用小。 |
| **Bun on Alpine** *(預設推薦)* | `omniroute/Dockerfile.v1.1.bun` | ~90 MB | 次秒級冷啟動速度，極高的 I/O 吞吐量與極低記憶體消耗。 |

您可以在 `.env` 檔案中隨時透過 `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` 或 `Dockerfile.v1.1` 自由切換。

---

## ✨ 核心特性與安全防護

* **專屬 Alpine / Bun 極速建置**：內建預編譯原生模組，容器自動以 root 啟動修正掛載目錄權限後透過 `su-exec` 降權至一般使用者 `omniroute`（UID 10001），並由 `dumb-init` 負責訊號優雅管理。
* **零輸入埠暴露**：透過 Cloudflare Tunnel 建立出站加密通道直連 Cloudflare 邊緣節點，無需路由器連接埠轉發，無公網 IP 暴露風險。
* **Cursor 專屬低延遲 SSE 串流回應**：深度調校 `proxy_buffering off;`、`chunked_transfer_encoding on;` 以及 600 秒長連線逾時，保障 Cursor IDE 即時逐 Token 輸出無延遲。
* **真實用戶端 IP 還原**：Nginx 精確解析 `CF-Connecting-IP` 與 Cloudflare 官方 IP CIDR 白名單，確保限流精確作用於真實請求者。
* **多區域獨立限流體系**：
  * `/v1/` API 區域：`40 requests/second`（突發 burst 50），輕鬆應對多檔案程式碼補全及並行上下文請求。
  * `/` Web 儀表板區域：`30 requests/second`（突發 burst 50），保障網頁端管理流暢度。
  * `/_next/static/`：靜態資源與媒體檔案獨立快取（365天），免除限流干擾。
* **資源耗盡與並行防護**：限制單 IP 最大並行連線數（`limit_conn 30`），限制請求主體最大 25MB。
* **OWASP 安全回應標頭**：注入完整防護標頭（`X-Frame-Options`、`X-Content-Type-Options: nosniff`、`Referrer-Policy`、`Permissions-Policy`）。

---

## 🚀 快速上手指南

### 1. 前置條件
* 已安裝 [Docker](https://docs.docker.com/get-docker/) 與 Docker Compose。
* 擁有一個由 Cloudflare 解析管理的網域名稱（免費版即可）。

---

### 2. 建立 Cloudflare Tunnel 通道
1. 登入 [Cloudflare Zero Trust 控制台](https://one.dash.cloudflare.com/)。
2. 進入 **Networks** > **Tunnels** > 點擊 **Add a Tunnel**。
3. 選擇 **Cloudflared** 連線方式，並為通道命名（例如 `omniroute-tunnel`）。
4. 在安裝指令區域選擇 **Docker**，複製 Token 字串（即 `--token` 後方的完整字串）。
5. 在 **Public Hostnames** 標籤頁中新增路由：
   * **Subdomain / Domain**：填寫您的子網域與主網域（例如 `ai.yourdomain.com`）。
   * **Service Type**：`HTTP`
   * **URL**：`nginx:80`（或 `http://nginx:80`）。
6. 儲存通道設定。

---

### 3. 設定環境變數
複製環境設定範本：
```bash
cp .env.example .env
```

編輯 `.env` 檔案並填入您的密鑰資訊：
```bash
# 貼上您的 Cloudflare Tunnel Token
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# 設定 OmniRoute Web 儀表板的初始管理員密碼
INITIAL_PASSWORD=YourSuperSecurePassword123!

# 產生用於 JWT 工作階段簽章的 64 位元 Hex 隨機金鑰 (openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)

# 選擇執行環境建置檔 (Dockerfile.v1.1.bun = Bun Alpine, Dockerfile.v1.1 = Node Alpine)
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun
OMNIROUTE_PKG_VERSION=latest
```

---

### 4. 建置並啟動服務
一鍵啟動所有容器（Docker Compose 會依據設定自動建置映像檔）：
```bash
docker compose up -d
```

查看容器執行狀態：
```bash
docker compose ps
```

查看即時日誌：
```bash
# 查看所有容器日誌
docker compose logs -f

# 或查看個別容器日誌
docker compose logs -f nginx
docker compose logs -f omniroute
docker compose logs -f cloudflared
```

---

## 🛡️ Cloudflare Zero Trust Access：路徑級白名單與 SSO 認證保護

若您希望透過 Cloudflare Access 保護管理後台，同時允許外部開發工具（如 Cursor、Claude Code、Python SDK）免登入直接呼叫 `/v1/*` 介面，**最佳實踐是針對不同路徑建立獨立的 Access 應用程式**。Cloudflare 會自動優先比對最具體的路徑規則。

設定步驟如下：

### 步驟 1：建立 API 繞過應用程式（API Bypass Application）
1. 開啟 **Zero Trust 控制台** -> 導覽至 **Access** > **Applications** -> 點擊 **Add an Application**。
2. 選擇 **Self-Hosted**。
3. 在 **Application Configuration** 部分：
   * **Application Name**：`Bypass LLM API v1`
   * **Subdomain & Domain**：輸入您的網域（如 `ai.yourdomain.com`）。
   * **Path**：輸入 `v1/*`。
4. 捲動至 **Policies** 策略設定區域：
   * **Policy Name**：`Allow API Traffic`
   * **Action**：選擇 **Bypass**
   * **Rule Type**：
     * **Include**：選擇 `Everyone` *(或選擇 `IP Ranges` 僅限特定網段)*。
5. 點擊儲存應用程式。

### 步驟 2：建立健康檢查繞過應用程式（Health Bypass Application）
重複上述步驟，為健康檢查端點建立個別應用程式：
1. 新建 **Self-Hosted** 應用程式。
2. **Application Name**：`Bypass LLM Health`
3. **Subdomain & Domain**：輸入您的網域（如 `ai.yourdomain.com`）。
4. **Path**：輸入 `health`。
5. 策略設定為 **Action: Bypass**，**Include: Everyone**。
6. 點擊儲存。

### 步驟 3：保護根網域管理後台（Secure the Root Application）
設定主網域的 SSO 存取攔截：
1. 新建或編輯根 **Self-Hosted** 應用程式，網域填寫 `ai.yourdomain.com`，**Path 欄位保持完全留空**。
2. 設定嚴格策略：
   * **Action**：選擇 **Allow**
   * **Include / Require**：選擇 `Emails` *(例如 `your-email@example.com`)* 或身分識別提供者（Google、GitHub 等）。

> **運作機制**：Cloudflare 優先評估最具體的路徑。因此對 `/v1/*` 和 `/health` 的請求將完全繞過 SSO 驗證（允許外部工具使用 Bearer API Key 直接互動），而存取 `/` 與 `/dashboard` 時則會強制彈出 SSO 登入驗證。

---

## 💻 Cursor IDE 設定連線

服務部署上線後：

1. 開啟 Cursor 設定（`Cmd + ,` 或 `Ctrl + ,`）-> **Models** -> **OpenAI API Key**。
2. 點擊 **Override OpenAI Base URL**：
   * **Base URL**：`https://ai.yourdomain.com/v1`（替換為您的實際網域）。
3. 在 **OpenAI API Key** 中：
   * 輸入在 OmniRoute 儀表板中產生的 API Key。
4. 在 Cursor Chat（`Cmd + L` 或 `Ctrl + L`）中發起對話，Token 將即時串流輸出。

---

## 🔒 存取 Web 儀表板

1. 在瀏覽器中開啟：
   ```
   https://ai.yourdomain.com/
   ```
2. 透過 Cloudflare Access 完成身分驗證（SSO 或電子郵件一次性驗證碼）。
3. 輸入 `.env` 中設定的 `INITIAL_PASSWORD` 登入 OmniRoute。
4. 在儀表板中您可以：
   * 設定上游 AI 提供商密鑰（OpenAI、Anthropic、DeepSeek、Groq、Google Gemini、OpenRouter 等）。
   * 為不同的 IDE 與專案建立專屬閘道 API Key。
   * 查看即時 Token 用量、延遲統計與上下文壓縮效率。
   * 監控免費層提供商的配額狀態（`/dashboard/free-tiers`）。

---

## 🧪 驗證與測試

### 1. 測試健康檢查
```bash
curl https://ai.yourdomain.com/health
# 預期返回: {"status":"ok","service":"omniroute-proxy"}
```

### 2. 測試缺少鑑權攔截
```bash
curl -i https://ai.yourdomain.com/v1/chat/completions
# 預期返回: HTTP/1.1 401 Unauthorized
```

### 3. 測試標準推論請求
```bash
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

### 4. 測試即時 SSE 串流輸出
```bash
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "stream": true,
    "messages": [{"role": "user", "content": "請從 1 數到 10"}]
  }'
```

---

## 📦 遠端伺服器離線打包部署

如果您的生產伺服器無法連線編譯網路，可以在本機一鍵打包完整離線映像檔與設定檔：

### 1. 本機打包建置
```bash
# 預設使用 Bun on Alpine 建置：
./scripts/package.sh bun

# 或使用 Node.js Alpine 建置：
./scripts/package.sh

# 如目標主機為 ARM64 架構（如樹莓派、ARM 雲端伺服器）：
TARGET_PLATFORM=linux/arm64 ./scripts/package.sh
```

建置完成後將在 `dist/` 目錄下產生離線安裝包 `dist/omniroute-deploy-YYYYMMDD_HHMMSS.tar.gz`。

### 2. 傳輸並在遠端一鍵啟動
```bash
# 1. 複製安裝包至遠端伺服器
scp dist/omniroute-deploy-*.tar.gz user@remote-server:/opt/omniroute/

# 2. 登入遠端伺服器並解壓縮
ssh user@remote-server
cd /opt/omniroute/
tar -xzf omniroute-deploy-*.tar.gz

# 3. 設定密鑰
cp .env.example .env
nano .env

# 4. 啟動服務（指令稿將自動匯入本機映像檔並啟動容器）
./start.sh
```

---

---

## 🚢 在 Mac 本機使用 Colima 建置 x64 映像檔並推送到 GitHub (GHCR)

您可以在 Apple Silicon 或 Intel Mac 上直接使用 **Colima**（配合 Rosetta 硬體加速）交叉編譯 x64 (`linux/amd64`) OmniRoute 映像檔，並推送到 **GitHub Container Registry (`ghcr.io`)**，支援從 **`1.0` 開始的版本號自動遞增**。

### 1. 在 macOS 啟動 Colima

在 Apple Silicon (M1/M2/M3/M4) 上，使用 Virtualization 框架 (`vz`) 與 Rosetta 2 啟動 Colima，獲得近乎原生的 x86_64 編譯效能：

```bash
colima start --arch aarch64 --vm-type vz --vz-rosetta
```

*(Intel Mac 使用者直接執行：`colima start`)*

---

### 2. 登入 GitHub 容器映像檔倉庫 (GHCR)

1. 建立 GitHub Personal Access Token (PAT)：
   * 進入 **GitHub** -> **Settings** -> **Developer settings** -> **Personal access tokens** -> **Tokens (classic)**。
   * 勾選權限：`write:packages`、`read:packages`、`delete:packages`。
2. 登入 GHCR：
   ```bash
   echo $CR_PAT | docker login ghcr.io -u <你的GitHub使用者名稱> --password-stdin
   ```

---

### 3. 一鍵建置並推送（自動遞增版本號）

```bash
# 自動遞增版本 (1.0 -> 1.1 -> 1.2)，編譯 x64 Bun 映像檔並推送至 GHCR:
./scripts/build-and-push.sh

# 編譯 Node.js Alpine 映像檔：
./scripts/build-and-push.sh node

# 遞增 patch 版本號（例如 1.0.1）：
./scripts/build-and-push.sh --bump patch

# 指定固定 Tag：
./scripts/build-and-push.sh --tag 2.0.0

# 預覽建置指令（dry-run）：
./scripts/build-and-push.sh --dry-run
```

**指令稿自動完成：**
1. 檢查 Colima 與 Docker Buildx 執行狀態。
2. 從 `.image-version` 讀取目前版本（起始為 `1.0`），計算下次版本（如 `1.1`）。
3. 使用 Docker Buildx 交叉編譯 `linux/amd64` 映像檔。
4. 推送 `ghcr.io/<使用者名稱>/omniroute:1.x` 及 `ghcr.io/<使用者名稱>/omniroute:latest`。
5. 自動更新 `.image-version` 並同步 `.env` 中的 `OMNIROUTE_IMAGE_TAG`。

---

### 4. 遠端伺服器透過 Docker Compose 拉取執行

在遠端伺服器上：
1. 確保 `.env` 中已設定 `GITHUB_USERNAME` 與 `OMNIROUTE_IMAGE`。
2. 若 GHCR 套件設定為 Private，先執行一次 `docker login ghcr.io`（若在 GitHub 中將 Package 設为 Public 則無需登入）。
3. 拉取並啟動：
   ```bash
   docker compose pull omniroute
   docker compose up -d
   ```

---

## 📁 目錄結構說明

```
OmniRoute/
├── docker-compose.yaml             # 多容器編排設定（支援 GHCR 映像檔拉取）
├── .env.example                    # 環境變數設定範本（含 GHCR 設定項）
├── .image-version                  # 映像檔版本追蹤檔案 (起始 1.0, 1.1...)
├── .gitignore                      # Git 忽略規則
├── README.md                       # 英文主說明文件
├── doc/                            # 多語言說明文件目錄 (中/繁/韓/日)
├── scripts/
│   ├── build-and-push.sh           # Mac (Colima) x64 映像檔建置與 GHCR 推送指令稿
│   └── package.sh                  # 獨立部署離線打包指令稿
├── omniroute/
│   ├── Dockerfile.v1.1             # Node.js 22 Alpine 生產映像檔建置檔
│   ├── Dockerfile.v1.1.bun         # Bun Alpine 高效能映像檔建置檔
│   ├── docker-entrypoint.sh        # su-exec 權限降權與資料卷初始化指令稿
│   └── data/                       # SQLite 資料庫持久化儲存目錄
└── nginx/
    ├── nginx.conf                  # Nginx 核心設定與限流區域定義
    ├── conf.d/
    │   └── omniroute.conf          # 路由代理、靜態快取與錯誤處理
    ├── logs/                       # 存取日誌與錯誤日誌
    └── includes/
        ├── cloudflare-real-ip.conf # Cloudflare 真實 IP 白名單設定
        ├── security-headers.conf   # OWASP 安全標頭設定
        └── streaming-proxy.conf    # SSE、WebSocket 與 Cloudflare Access 標頭透傳
```

---

## 🛠 常用維護指令

* **重新建置並更新映像檔**：
  ```bash
  docker compose up -d --build
  ```
* **切換執行環境**：
  在 `.env` 中修改 `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` 或 `Dockerfile.v1.1`，執行：
  ```bash
  docker compose up -d
  ```
* **停止所有服務**：
  ```bash
  docker compose down
  ```
