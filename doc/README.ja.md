# OmniRoute + Nginx + Cloudflare Tunnel デプロイガイド

[English](../README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

---

本プロジェクトは、**OmniRoute**（最適化された **Alpine / Bun** 高速ランタイムビルド対応）、**Nginx**、**Cloudflare Tunnel** を **Docker Compose** でパッケージ化した、安全で実用的なセルフホスト型 AI ゲートウェイ（AI Gateway）デプロイスタックです。

**Cursor IDE**、**Claude Code**、OpenAI SDK ベースのアプリケーションが、ルーターのインバウンドポート開放やオリジンサーバーのパブリック IP を公開することなく、**超低遅延 Server-Sent Events (SSE) ストリーミング**で OmniRoute インスタンスに接続できます。また、包括的な不正利用防止とレート制限（Rate Limiting）が組み込まれています。

---

## 🏛 アーキテクチャ

```mermaid
flowchart LR
    subgraph Clients["クライアント"]
        Cursor[Cursor IDE / OpenAI SDK]
        AdminBrowser[管理者ブラウザ]
    end

    subgraph Cloudflare["Cloudflare エッジネットワーク"]
        CF_Edge["Cloudflare Edge (HTTPS/WAF/DDoS)"]
    end

    subgraph Host["ホストマシン (Docker Compose)"]
        subgraph TunnelContainer["Cloudflare Tunnel"]
            Cloudflared["cloudflared\n(アウトバウンド暗号化トンネル)"]
        end

        subgraph NginxContainer["Nginx リバースプロキシ"]
            Nginx["Nginx エンジン"]
            RealIP["クライアント実 IP 復元\n(CF-Connecting-IP)"]
            RateLimit["多層レート制限・保護"]
            SSE["SSE ストリーミング (バッファ無効)"]
        end

        subgraph OmniRouteContainer["OmniRoute (Alpine / Bun)"]
            Gateway["OmniRoute コアエンジン (ポート 20128)"]
            DB[(永続化 SQLite データボリューム)]
        end
    end

    subgraph Providers["アップストリーム AI プロバイダー"]
        OpenAI[OpenAI / Anthropic / Groq / Google / DeepSeek]
    end

    Cursor -->|HTTPS /v1/...| CF_Edge
    AdminBrowser -->|HTTPS / または /dashboard| CF_Edge
    CF_Edge --> Cloudflared
    Cloudflared -->|http://nginx:80| Nginx
    Nginx --> RealIP --> RateLimit
    RateLimit -->|/v1/* (API リクエスト)| SSE --> Gateway
    RateLimit -->|/ (ダッシュボードログイン)| Gateway
    Gateway --> DB
    Gateway --> Providers
```

---

## ⚡ ランタイムおよびイメージ構成 (Alpine & Bun)

本プロジェクトには、高度に最適化された Alpine マルチステージ Dockerfile が含まれています：

| ランタイム | Dockerfile | イメージサイズ | 最適な用途 |
| :--- | :--- | :--- | :--- |
| **Node.js 22 Alpine** | `omniroute/Dockerfile.v1.1` | ~120 MB | ネイティブ C++ モジュール (`better-sqlite3`, `libsecret`) の互換性が高く、メモリフットプリントが最小限。 |
| **Bun on Alpine** *(デフォルト推奨)* | `omniroute/Dockerfile.v1.1.bun` | ~90 MB | サブセカンドの超高速コールドスタート、卓越した I/O スループット、極めて低いメモリ消費。 |

`.env` 内の `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` または `Dockerfile.v1.1` によりいつでも自由に切り替えられます。

---

## ✨ 主な機能とセキュリティ保護

* **専用 Alpine / Bun 高速ビルド**：ビルド済みネイティブモジュールを搭載し、起動時にボリューム権限を自動修復後、`su-exec` により非 root ユーザー `omniroute`（UID 10001）へ権限を降格。`dumb-init` でシグナルを安全に処理。
* **インバウンドポートの完全遮断**：Cloudflare Tunnel を通じたアウトバウンド暗号化通信により、ポート転送や静的グローバル IP は不要。
* **Cursor 向け超低遅延 SSE ストリーミング**：`proxy_buffering off;`、`chunked_transfer_encoding on;`、600秒のプロキシタイムアウト設定により、Cursor IDE でリアルタイムのトークン逐次出力を実現。
* **クライアント実 IP の復元**：Nginx が `CF-Connecting-IP` および公式 IP CIDR を解析し、リクエスト元の実 IP に基づいて正確にレート制限を適用。
* **マルチゾーン独立レート制限**：
  * `/v1/` API ゾーン：`40 requests/second`（バースト 50）。複数ファイルのコード補完や並列コンテキスト要求に対応。
  * `/` Web ダッシュボードゾーン：`30 requests/second`（バースト 50）。管理画面の快適な操作性を維持。
  * `/_next/static/`：静的アセット・メディアファイルを長期キャッシュ（365日）し、レート制限から除外。
* **リソース枯渇・同時接続保護**：IP ごとの最大同時接続数を制限（`limit_conn 30`）、リクエストボディの上限を 25MB に制限。
* **OWASP セキュリティヘッダー**：セキュリティヘッダーを注入（`X-Frame-Options`、`X-Content-Type-Options: nosniff`、`Referrer-Policy`、`Permissions-Policy`）。

---

## 🚀 クイックスタートガイド

### 1. 前提条件
* [Docker](https://docs.docker.com/get-docker/) および Docker Compose がインストールされていること。
* Cloudflare で管理されているドメイン（無料プランで利用可能）。

---

### 2. Cloudflare Tunnel の作成
1. [Cloudflare Zero Trust ダッシュボード](https://one.dash.cloudflare.com/) にログインします。
2. **Networks** > **Tunnels** に移動し、**Add a Tunnel** をクリックします。
3. コネクタタイプとして **Cloudflared** を選択し、トンネル名を入力します（例：`omniroute-tunnel`）。
4. インストールコマンドのセクションで **Docker** を選択し、`--token` 以降のトークン文字列をコピーします。
5. **Public Hostnames** タブでルーティングを追加します：
   * **Subdomain / Domain**：サブドメインとメインドメインを入力（例：`ai.yourdomain.com`）。
   * **Service Type**：`HTTP`
   * **URL**：`nginx:80`（または `http://nginx:80`）。
6. トンネル設定を保存します。

---

### 3. 環境変数の設定
設定ファイルテンプレートをコピーします：
```bash
cp .env.example .env
```

`.env` を編集してシークレット情報を設定します：
```bash
# Cloudflare Tunnel トークン
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# OmniRoute Web ダッシュボードの管理者初期パスワード
INITIAL_PASSWORD=YourSuperSecurePassword123!

# JWT セッション署名用 64文字 Hex ランダムシークレット (openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)

# ランタイム Dockerfile の選択 (Dockerfile.v1.1.bun = Bun Alpine, Dockerfile.v1.1 = Node Alpine)
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun
OMNIROUTE_PKG_VERSION=latest
```

---

### 4. ビルドとサービスの起動
すべてのサービスを起動します（Docker Compose が指定されたバージョンで自動ビルドします）：
```bash
docker compose up -d
```

コンテナの稼働状況を確認：
```bash
docker compose ps
```

リアルタイムログの確認：
```bash
# すべてのログを確認
docker compose logs -f

# 個別サービスのログを確認
docker compose logs -f nginx
docker compose logs -f omniroute
docker compose logs -f cloudflared
```

---

## 🛡️ Cloudflare Zero Trust Access: パス別バイパスと SSO 保護

Web 管理画面を Cloudflare SSO で保護しつつ、外部の開発ツール（Cursor、Claude Code、Python SDK など）が `/v1/*` API をログイン画面なしで直接呼び出せるようにするには、**パスごとに独立した Access Application を作成**します。Cloudflare は最も詳細なパスルールを自動的に優先します。

設定手順は以下のとおりです：

### ステップ 1: API バイパスアプリケーションの作成 (API Bypass Application)
1. **Zero Trust ダッシュボード** -> **Access** > **Applications** -> **Add an Application** をクリック。
2. **Self-Hosted** を選択。
3. **Application Configuration** セクション：
   * **Application Name**：`Bypass LLM API v1`
   * **Subdomain & Domain**：プロキシドメインを入力（例：`ai.yourdomain.com`）。
   * **Path**：`v1/*` と入力。
4. **Policies** セクションでアクセスルールを設定：
   * **Policy Name**：`Allow API Traffic`
   * **Action**：**Bypass** を選択
   * **Rule Type**：
     * **Include**：`Everyone` を選択 *(特定のサーバー IP に限定する場合は `IP Ranges` を選択)*。
5. アプリケーションを保存します。

### ステップ 2: ヘルスチェックバイパスアプリケーションの作成 (Health Bypass Application)
死活監視エンドポイント用にも同様にアプリケーションを作成します：
1. 新規 **Self-Hosted** アプリケーションを作成。
2. **Application Name**：`Bypass LLM Health`
3. **Subdomain & Domain**：ドメインを入力（例：`ai.yourdomain.com`）。
4. **Path**：`health` と入力。
5. ポリシーを **Action: Bypass**、**Include: Everyone** に設定。
6. 保存します。

### ステップ 3: ルートドメインの保護 (Secure the Root Application)
ベースドメインに SSO 認証を適用します：
1. `ai.yourdomain.com` を対象とするルート **Self-Hosted** アプリケーションを作成または編集し、**Path フィールドは完全に空欄**にします。
2. 厳格なポリシーを設定：
   * **Action**：**Allow** を選択
   * **Include / Require**：`Emails` *(例：`your-email@example.com`)* または IdP（Google、GitHub など）を指定。

> **仕組み**：Cloudflare は最も詳細なパスを優先して評価します。そのため、`/v1/*` および `/health` へのリクエストは SSO を完全にバイパスして Bearer API Key で直接通信でき、ブラウザから `/` や `/dashboard` にアクセスした際には SSO ログイン画面が表示されます。

---

## 💻 Cursor IDE の接続設定

サービスが起動したら、Cursor を設定します：

1. Cursor 設定を開く（`Cmd + ,` または `Ctrl + ,`）-> **Models** -> **OpenAI API Key**。
2. **Override OpenAI Base URL** をクリック：
   * **Base URL**：`https://ai.yourdomain.com/v1`（実際のドメインに置き換え）。
3. **OpenAI API Key**：
   * OmniRoute ダッシュボードで生成した API Key を入力。
4. Cursor Chat（`Cmd + L` または `Ctrl + L`）で会話を開始すると、トークンがリアルタイムでストリーミングされます。

---

## 🔒 Web ダッシュボードへのアクセス

1. ブラウザでアクセス：
   ```
   https://ai.yourdomain.com/
   ```
2. Cloudflare Access 認証を完了（SSO またはメール OTP）。
3. `.env` に設定した `INITIAL_PASSWORD` で OmniRoute ダッシュボードにログイン。
4. ダッシュボードで利用可能な機能：
   * 各種 AI プロバイダー API Key の登録（OpenAI、Anthropic、DeepSeek、Groq、Google Gemini、OpenRouter など）。
   * IDE やアプリごとのゲートウェイ API Key 発行。
   * リアルタイムのトークン消費量、レイテンシ統計、コンテキスト圧縮効率の確認。
   * 無料枠プロバイダーのクォータ監視（`/dashboard/free-tiers`）。

---

## 🧪 動作確認とテスト

### 1. ヘルスチェックのテスト
```bash
curl https://ai.yourdomain.com/health
# 期待されるレスポンス: {"status":"ok","service":"omniroute-proxy"}
```

### 2. 認証なしリクエストの遮断テスト
```bash
curl -i https://ai.yourdomain.com/v1/chat/completions
# 期待されるレスポンス: HTTP/1.1 401 Unauthorized
```

### 3. 標準推論リクエストのテスト
```bash
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "こんにちは！"}]
  }'
```

### 4. リアルタイム SSE トークンストリーミングのテスト
```bash
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "stream": true,
    "messages": [{"role": "user", "content": "1から10までゆっくり数えてください。"}]
  }'
```

---

## 📦 リモートサーバー向けオフラインパッケージング

リモートサーバーにビルド環境がない場合やオフラインデプロイを行いたい場合、ローカル環境で全体を単一アーカイブにパッケージ化できます：

### 1. ローカルでのパッケージング
```bash
# Bun on Alpine ベースでビルド（デフォルト）：
./scripts/package.sh bun

# または Node.js Alpine ベースでビルド：
./scripts/package.sh

# リモートマシンが ARM64 アーキテクチャの場合（Raspberry Pi、ARM クラウドなど）：
TARGET_PLATFORM=linux/arm64 ./scripts/package.sh
```

ビルド完了後、`dist/omniroute-deploy-YYYYMMDD_HHMMSS.tar.gz` が生成されます。

### 2. リモートサーバーへの転送と起動
```bash
# 1. アーカイブをリモートサーバーにコピー
scp dist/omniroute-deploy-*.tar.gz user@remote-server:/opt/omniroute/

# 2. リモートサーバーにログインして解凍
ssh user@remote-server
cd /opt/omniroute/
tar -xzf omniroute-deploy-*.tar.gz

# 3. シークレット設定
cp .env.example .env
nano .env

# 4. サービス起動（自動でローカルイメージをロードして起動）
./start.sh
```

---

---

## 🚢 macOS (Colima) での x64 イメージビルドと GitHub (GHCR) へのプッシュ

Apple Silicon または Intel Mac 上で **Colima**（Rosetta ハードウェアアクセラレーション対応）を使用し、x64 (`linux/amd64`) の OmniRoute イメージを直接クロスコンパイルして **GitHub Container Registry (`ghcr.io`)** にプッシュできます。**バージョン `1.0` からの自動インクリメント** にも対応しています。

### 1. macOS で Colima を起動

Apple Silicon (M1/M2/M3/M4) では、Virtualization フレームワーク (`vz`) と Rosetta 2 を有効にして Colima を起動し、ネイティブに近い速度で x86_64 の高速コンパイルを行います:

```bash
colima start --arch aarch64 --vm-type vz --vz-rosetta
```

*(Intel Mac の場合は通常起動: `colima start`)*

---

### 2. GitHub Container Registry (GHCR) へのログイン

1. GitHub Personal Access Token (PAT) を作成:
   * **GitHub** -> **Settings** -> **Developer settings** -> **Personal access tokens** -> **Tokens (classic)** に移動。
   * スコープを選択: `write:packages`、`read:packages`、`delete:packages`。
2. Docker CLI で GHCR にログイン:
   ```bash
   echo $CR_PAT | docker login ghcr.io -u <GitHubユーザー名> --password-stdin
   ```

---

### 3. ワンコマンドでビルド＆プッシュ（バージョン自動インクリメント）

```bash
# バージョンを自動インクリメント (1.0 -> 1.1 -> 1.2) し、x64 Bun イメージをビルドして GHCR にプッシュ:
./scripts/build-and-push.sh

# Node.js Alpine ランタイムでビルドする場合:
./scripts/build-and-push.sh node

# パッチバージョンをインクリメントする場合 (例: 1.0.1):
./scripts/build-and-push.sh --bump patch

# 特定のタグを指定する場合:
./scripts/build-and-push.sh --tag 2.0.0

# 実行内容の事前確認（ドライラン）:
./scripts/build-and-push.sh --dry-run
```

**スクリプトの自動処理内容:**
1. Colima および Docker Buildx の状態を自動検証。
2. `.image-version` から現在のバージョン（初期値 `1.0`）を取得し、次回バージョン（`1.1` など）を算出。
3. Docker Buildx で `linux/amd64` 向けにクロスビルド。
4. `ghcr.io/<ユーザー名>/omniroute:1.x` および `ghcr.io/<ユーザー名>/omniroute:latest` の両方を GHCR にプッシュ。
5. `.image-version` を自動更新し、ローカルの `.env` 内の `OMNIROUTE_IMAGE_TAG` を最新化。

---

### 4. リモートサーバーで Docker Compose からプルして起動

リモートサーバー側:
1. `.env` に `GITHUB_USERNAME` および `OMNIROUTE_IMAGE` が設定されていることを確認。
2. GHCR パッケージが Private の場合、初回のみ `docker login ghcr.io` を実行（GitHub 上で Package を Public に変更すればログイン不要）。
3. プルして起動:
   ```bash
   docker compose pull omniroute
   docker compose up -d
   ```

---

## 📁 ディレクトリ構造

```
OmniRoute/
├── docker-compose.yaml             # マルチコンテナ構成定義（GHCR イメージ対応）
├── .env.example                    # 環境変数テンプレート（GHCR 設定項目追加）
├── .image-version                  # イメージバージョン追跡ファイル (初期値 1.0, 1.1...)
├── .gitignore                      # Git 除外設定
├── README.md                       # 英語版メインドキュメント
├── doc/                            # 多言語ドキュメントディレクトリ (中/繁/韓/日)
├── scripts/
│   ├── build-and-push.sh           # Mac (Colima) x64 イメージビルド & GHCR プッシュスクリプト
│   └── package.sh                  # オフラインデプロイ用パッケージングスクリプト
├── omniroute/
│   ├── Dockerfile.v1.1             # Node.js 22 Alpine 本番用 Dockerfile
│   ├── Dockerfile.v1.1.bun         # Bun Alpine 高性能 Dockerfile
│   ├── docker-entrypoint.sh        # su-exec 権限降格・ボリューム権限自動修復スクリプト
│   └── data/                       # SQLite 永続化データディレクトリ
└── nginx/
    ├── nginx.conf                  # Nginx コア設定およびレート制限ゾーン定義
    ├── conf.d/
    │   └── omniroute.conf          # ルーティングプロキシ、静的キャッシュ、エラーハンドラ
    ├── logs/                       # アクセスログおよびエラーログ
    └── includes/
        ├── cloudflare-real-ip.conf # Cloudflare 実 IP ホワイトリスト設定
        ├── security-headers.conf   # OWASP セキュリティヘッダー
        └── streaming-proxy.conf    # SSE、WebSocket、Cloudflare Access ヘッダー転送
```

---

## 🛠 メンテナンスコマンド

* **イメージの再ビルドと更新**：
  ```bash
  docker compose up -d --build
  ```
* **ランタイムの切り替え**：
  `.env` 内の `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` または `Dockerfile.v1.1` に変更後、実行：
  ```bash
  docker compose up -d
  ```
* **スタックの停止**：
  ```bash
  docker compose down
  ```
