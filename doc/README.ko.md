# OmniRoute + Nginx + Cloudflare Tunnel 배포 가이드

[English](../README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

---

본 프로젝트는 **OmniRoute**(최적화된 **Alpine / Bun** 고속 런타임 빌드 포함), **Nginx**, **Cloudflare Tunnel**을 기반으로 **Docker Compose**를 통해 구성된 안전하고 프로덕션 수준의 자체 호스팅 AI Gateway 배포 스택입니다.

이 구성을 통해 **Cursor IDE**, **Claude Code**, OpenAI SDK 기반 애플리케이션 등이 인바운드 방화벽 포트 개방이나 원본 서버 공인 IP 노출 없이, 공용 인터넷 환경에서 **초저지연 Server-Sent Events (SSE) 스트리밍**으로 OmniRoute 인스턴스에 안전하게 연결할 수 있으며 강력한 남용 방지 및 속도 제한(Rate Limiting)이 적용됩니다.

---

## 🏛 아키텍처 구성

![Architecture Overview](images/architecture_overview.png)

---

## ⚡ 런타임 및 이미지 옵션 (Alpine & Bun)

본 프로젝트는 고도로 최적화된 Alpine 멀티 스테이지 Docker 빌드를 제공합니다:

| 런타임 옵션 | Dockerfile | 이미지 크기 | 최적의 사용처 |
| :--- | :--- | :--- | :--- |
| **Node.js 22 Alpine** | `omniroute/Dockerfile.v1.1` | ~120 MB | 네이티브 C++ 모듈(`better-sqlite3`, `libsecret`) 안정성이 우수하며 메모리 사용량이 적음. |
| **Bun on Alpine** *(기본 권장)* | `omniroute/Dockerfile.v1.1.bun` | ~90 MB | 1초 미만의 초고속 콜드 스타트, 뛰어난 I/O 처리량 및 극도로 낮은 메모리 소비. |

`.env` 파일의 `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` 또는 `Dockerfile.v1.1` 설정을 통해 언제든지 자유롭게 전환할 수 있습니다.

---

## ✨ 핵심 기능 및 보안 보호

* **전용 Alpine / Bun 빌드**: 컴파일된 네이티브 모듈 포함, 볼륨 마운트 권한 자동 보정 후 `su-exec`를 통해 비루트 계정 `omniroute`(UID 10001)로 권한 강등 실행, `dumb-init` 프로세스 시그널 관리.
* **인바운드 포트 완전 차단**: Cloudflare Tunnel을 통한 아웃바운드 암호화 통신으로 공유기 포트포워딩 및 공인 IP 노출 불필요.
* **Cursor 전용 저지연 SSE 스트리밍**: `proxy_buffering off;`, `chunked_transfer_encoding on;`, 600초 프록시 타임아웃 설정을 통해 Cursor IDE에서 실시간 토큰 스트리밍 지원.
* **실제 클라이언트 IP 복원**: Nginx에서 `CF-Connecting-IP` 및 Cloudflare 공식 IP 대역을 완벽하게 파싱하여 실제 접속자 기준으로 속도 제한 적용.
* **다중 구역 속도 제한 (Rate Limiting)**:
  * `/v1/` API 구역: `40 requests/second` (버스트 50)으로 다중 파일 코드 완성 및 대규모 컨텍스트 요청 수용.
  * `/` 웹 대시보드 구역: `30 requests/second` (버스트 50)으로 부드러운 관리 환경 제공.
  * `/_next/static/`: 정적 리소스 및 미디어 파일 장기 캐싱(365일), 속도 제한 제외.
* **리소스 고갈 및 동시성 방어**: IP당 최대 동시 연결 수(`limit_conn 30`) 및 요청 본문 최대 크기 25MB 제한.
* **OWASP 보안 헤더 주입**: `X-Frame-Options`, `X-Content-Type-Options: nosniff`, `Referrer-Policy`, `Permissions-Policy` 적용.

---

## 🚀 빠른 시작 가이드

### 1. 사전 준비 사항
* [Docker](https://docs.docker.com/get-docker/) 및 Docker Compose 설치.
* Cloudflare에서 관리 중인 도메인 (무료 플랜 지원).

---

### 2. Cloudflare Tunnel 생성
1. [Cloudflare Zero Trust 대시보드](https://one.dash.cloudflare.com/)에 로그인합니다.
2. **Networks** > **Tunnels** 메뉴로 이동하여 **Add a Tunnel**을 클릭합니다.
3. 커넥터 유형으로 **Cloudflared**를 선택하고 터널 이름을 입력합니다 (예: `omniroute-tunnel`).
4. 설치 명령 영역에서 **Docker**를 선택하고 `--token` 뒤의 토큰 문자열을 복사합니다.
5. **Public Hostnames** 탭에서 라우팅을 추가합니다:
   * **Subdomain / Domain**: 서브도메인 및 도메인 입력 (예: `ai.yourdomain.com`).
   * **Service Type**: `HTTP`
   * **URL**: `nginx:80` (또는 `http://nginx:80`).
6. 터널 설정을 저장합니다.

---

### 3. 환경 변수 구성
환경 변수 예시 템플릿을 복사합니다:
```bash
cp .env.example .env
```

`.env` 파일을 열고 본인의 환경에 맞게 수정합니다:
```bash
# Cloudflare Tunnel 토큰 입력
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# OmniRoute 웹 대시보드 관리자 초기 비밀번호 설정
INITIAL_PASSWORD=YourSuperSecurePassword123!

# JWT 세션 서명용 64자리 Hex 무작위 비밀키 생성 (openssl rand -hex 32)
JWT_SECRET=$(openssl rand -hex 32)

# 런타임 Dockerfile 선택 (Dockerfile.v1.1.bun = Bun Alpine, Dockerfile.v1.1 = Node Alpine)
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun
OMNIROUTE_PKG_VERSION=latest
```

---

### 4. 빌드 및 서비스 실행
모든 컨테이너를 빌드하고 백그라운드에서 실행합니다:
```bash
docker compose up -d
```

컨테이너 상태 확인:
```bash
docker compose ps
```

실시간 로그 모니터링:
```bash
# 전체 로그 보기
docker compose logs -f

# 개별 서비스 로그 보기
docker compose logs -f nginx
docker compose logs -f omniroute
docker compose logs -f cloudflared
```

---

## 🛡️ Cloudflare Zero Trust Access: 경로별 우회(Bypass) 및 SSO 보호

웹 대시보드는 Cloudflare SSO로 안전하게 보호하면서, Cursor IDE나 외부 애플리케이션의 `/v1/*` API 호출은 로그인 화면 없이 통과시키기 위해서는 **경로(Path)별로 분리된 Access Application을 생성**해야 합니다. Cloudflare는 가장 구체적인 경로를 우선하여 평가합니다.

단계별 설정 방법은 다음과 같습니다:

### 단계 1: API 우회 애플리케이션 생성 (API Bypass Application)
1. **Zero Trust 대시보드** 접속 -> **Access** > **Applications** -> **Add an Application** 클릭.
2. **Self-Hosted** 선택.
3. **Application Configuration** 섹션 설정:
   * **Application Name**: `Bypass LLM API v1`
   * **Subdomain & Domain**: 프록시 도메인 입력 (예: `ai.yourdomain.com`).
   * **Path**: `v1/*` 입력.
4. **Policies** 섹션에서 접근 규칙 정의:
   * **Policy Name**: `Allow API Traffic`
   * **Action**: **Bypass** 선택
   * **Rule Type**:
     * **Include**: `Everyone` 선택 *(또는 특정 서버 IP로 제한하려면 `IP Ranges` 선택)*.
5. 애플리케이션을 저장합니다.

### 단계 2: 헬스 체크 우회 애플리케이션 생성 (Health Bypass Application)
상태 확인 엔드포인트용 애플리케이션을 동일한 방식으로 생성합니다:
1. 새로운 **Self-Hosted** 애플리케이션 생성.
2. **Application Name**: `Bypass LLM Health`
3. **Subdomain & Domain**: 도메인 입력 (예: `ai.yourdomain.com`).
4. **Path**: `health` 입력.
5. 정책을 **Action: Bypass**, **Include: Everyone**으로 설정.
6. 애플리케이션을 저장합니다.

### 단계 3: 루트 도메인 대시보드 보호 (Secure the Root Application)
기본 도메인에 SSO 인증을 적용합니다:
1. `ai.yourdomain.com`을 대상으로 하는 루트 **Self-Hosted** 애플리케이션을 생성하거나 편집하며, **Path 필드는 완전히 비워둡니다**.
2. 접근 정책을 엄격하게 설정합니다:
   * **Action**: **Allow** 선택
   * **Include / Require**: `Emails` *(예: `your-email@example.com`)* 또는 인증 제공업체 (Google, GitHub 등) 지정.

> **동작 원리**: Cloudflare는 가장 구체적인 경로를 먼저 처리합니다. 따라서 `/v1/*` 및 `/health` 요청은 SSO를 우회하여 API Key로 직접 통신하며, 웹 브라우저를 통한 `/` 및 `/dashboard` 접근 시에는 SSO 로그인 화면이 나타납니다.

---

## 💻 Cursor IDE 연동 설정

서비스 배포가 완료되면 다음과 같이 설정합니다:

1. Cursor 설정 열기 (`Cmd + ,` 또는 `Ctrl + ,`) -> **Models** -> **OpenAI API Key**.
2. **Override OpenAI Base URL** 클릭:
   * **Base URL**: `https://ai.yourdomain.com/v1` (실제 Cloudflare 도메인으로 입력).
3. **OpenAI API Key** 필드:
   * OmniRoute 웹 대시보드에서 생성한 API Key 입력.
4. Cursor Chat (`Cmd + L` 또는 `Ctrl + L`)에서 대화를 시작하면 실시간으로 토큰이 스트리밍됩니다.

---

## 🔒 웹 대시보드 접근 및 관리

1. 브라우저에서 접속:
   ```
   https://ai.yourdomain.com/
   ```
2. Cloudflare Access 인증 통과 (SSO 또는 이메일 OTP).
3. `.env`에 설정한 `INITIAL_PASSWORD`로 OmniRoute 대시보드 로그인.
4. 대시보드 제공 기능:
   * 상위 AI 모델 제공자 키 설정 (OpenAI, Anthropic, DeepSeek, Groq, Google Gemini, OpenRouter 등).
   * IDE 및 애플리케이션별 전용 게이트웨이 API Key 발급.
   * 실시간 토큰 사용량, 지연 시간 메트릭 및 컨텍스트 압축 통계 모니터링.
   * 무료 티어 제공업체의 할당량 추적 (`/dashboard/free-tiers`).

---

## 🧪 검증 및 테스트

### 1. 헬스 체크 확인
```bash
curl https://ai.yourdomain.com/health
# 예상 응답: {"status":"ok","service":"omniroute-proxy"}
```

### 2. 인증 누락 차단 테스트
```bash
curl -i https://ai.yourdomain.com/v1/chat/completions
# 예상 응답: HTTP/1.1 401 Unauthorized
```

### 3. 표준 추론 요청 테스트
```bash
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "messages": [{"role": "user", "content": "안녕하세요!"}]
  }'
```

### 4. 실시간 SSE 토큰 스트리밍 테스트
```bash
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{
    "model": "auto",
    "stream": true,
    "messages": [{"role": "user", "content": "1부터 10까지 천천히 세어주세요."}]
  }'
```

---

## 📦 원격 서버 오프라인 패키징 배포

원격 서버에 빌드 도구가 없거나 오프라인 환경인 경우, 로컬에서 전체 스택을 단일 아카이브로 패키징할 수 있습니다:

### 1. 로컬에서 패키징
```bash
# Bun on Alpine 기반 빌드 (기본):
./scripts/package.sh bun

# 또는 Node.js Alpine 기반 빌드:
./scripts/package.sh

# 대상 서버가 ARM64 아키텍처인 경우 (라즈베리파이, ARM 클라우드 등):
TARGET_PLATFORM=linux/arm64 ./scripts/package.sh
```

빌드가 완료되면 `dist/omniroute-deploy-YYYYMMDD_HHMMSS.tar.gz` 아카이브가 생성됩니다.

### 2. 원격 서버 전송 및 실행
```bash
# 1. 아카이브를 원격 서버로 전송
scp dist/omniroute-deploy-*.tar.gz user@remote-server:/opt/omniroute/

# 2. 원격 서버 접속 및 압축 해제
ssh user@remote-server
cd /opt/omniroute/
tar -xzf omniroute-deploy-*.tar.gz

# 3. 비밀키 설정
cp .env.example .env
nano .env

# 4. 서비스 시작 (자동으로 로컬 이미지를 로드하고 실행)
./start.sh
```

---

---

## 🚢 macOS (Colima)에서 x64 이미지 빌드 및 GitHub (GHCR) 푸시

Apple Silicon 또는 Intel Mac에서 **Colima**(Rosetta 하드웨어 가속 지원)를 사용하여 x64 (`linux/amd64`) OmniRoute 이미지를 직접 크로스 컴파일하고 **GitHub Container Registry (`ghcr.io`)**에 푸시할 수 있습니다. **버전 `1.0`부터 시작하는 자동 증가 태깅**을 지원합니다.

### 1. macOS에서 Colima 시작

Apple Silicon (M1/M2/M3/M4)에서는 Virtualization 프레임워크(`vz`)와 Rosetta 2를 활성화하여 Colima를 실행하면 네이티브에 가까운 속도로 x86_64 빌드를 수행할 수 있습니다:

```bash
colima start --arch aarch64 --vm-type vz --vz-rosetta
```

*(Intel Mac 사용자는 일반 실행: `colima start`)*

---

### 2. GitHub Container Registry (GHCR) 로그인

1. GitHub Personal Access Token (PAT) 생성:
   * **GitHub** -> **Settings** -> **Developer settings** -> **Personal access tokens** -> **Tokens (classic)** 이동.
   * 권한 체크: `write:packages`, `read:packages`, `delete:packages`.
2. Docker CLI로 GHCR 로그인:
   ```bash
   echo $CR_PAT | docker login ghcr.io -u <GitHub사용자명> --password-stdin
   ```

---

### 3. 원클릭 빌드 및 푸시 (버전 자동 증가)

```bash
# 버전 자동 증가 (1.0 -> 1.1 -> 1.2), x64 Bun 이미지 빌드 및 GHCR 푸시:
./scripts/build-and-push.sh

# Node.js Alpine 런타임으로 빌드:
./scripts/build-and-push.sh node

# 패치 버전 증가 (예: 1.0.1):
./scripts/build-and-push.sh --bump patch

# 특정 태그 지정:
./scripts/build-and-push.sh --tag 2.0.0

# 빌드 명령 미리보기 (dry-run):
./scripts/build-and-push.sh --dry-run
```

**스크립트 자동 처리 작업:**
1. Colima 및 Docker Buildx 상태 자동 검증.
2. `.image-version`에서 현재 버전(초기값 `1.0`)을 읽고 다음 버전(예: `1.1`) 계산.
3. Docker Buildx를 사용하여 `linux/amd64`용으로 크로스 빌드.
4. `ghcr.io/<사용자명>/omniroute:1.x` 및 `ghcr.io/<사용자명>/omniroute:latest` 푸시.
5. `.image-version`을 자동 갱신하고 로컬 `.env`의 `OMNIROUTE_IMAGE_TAG` 동기화.

---

### 4. 원격 서버에서 Docker Compose로 풀 및 실행

원격 서버:
1. `.env` 파일에 `GITHUB_USERNAME` 및 `OMNIROUTE_IMAGE`가 설정되어 있는지 확인합니다.
2. GHCR 패키지가 Private인 경우 최초 1회 `docker login ghcr.io` 실행 (GitHub에서 패키지를 Public으로 변경하면 로그인 불필요).
3. 이미지 풀 및 컨테이너 시작:
   ```bash
   docker compose pull omniroute
   docker compose up -d
   ```

---

## 📁 디렉터리 구조

```
OmniRoute/
├── docker-compose.yaml             # 멀티 컨테이너 오케스트레이션 정의 (GHCR 이미지 지원)
├── .env.example                    # 환경 변수 템플릿 (GHCR 설정 항목 포함)
├── .image-version                  # 이미지 버전 추적 파일 (초기값 1.0, 1.1...)
├── .gitignore                      # Git 제외 설정
├── README.md                       # 영문 메인 문서
├── doc/                            # 다국어 문서 폴더 (한/중/일)
├── scripts/
│   ├── build-and-push.sh           # Mac (Colima) x64 이미지 빌드 및 GHCR 푸시 스크립트
│   └── package.sh                  # 오프라인 배포 패키징 스크립트
├── omniroute/
│   ├── Dockerfile.v1.1             # Node.js 22 Alpine 프로덕션 빌드
│   ├── Dockerfile.v1.1.bun         # Bun Alpine 고성능 빌드
│   ├── docker-entrypoint.sh        # su-exec 권한 강등 및 볼륨 권한 보정
│   └── data/                       # SQLite 데이터베이스 영구 저장소
└── nginx/
    ├── nginx.conf                  # Nginx 코어 설정 및 다중 속도 제한 구역
    ├── conf.d/
    │   └── omniroute.conf          # 라우팅 프록시, 정적 캐싱 및 에러 처리
    ├── logs/                       # 접근 및 에러 로그
    └── includes/
        ├── cloudflare-real-ip.conf # Cloudflare 실제 IP 화이트리스트
        ├── security-headers.conf   # OWASP 보안 헤더 정의
        └── streaming-proxy.conf    # SSE, WebSocket 및 Cloudflare Access 헤더 전달
```

---

## 🛠 유지관리 명령어

* **이미지 다시 빌드 및 업데이트**:
  ```bash
  docker compose up -d --build
  ```
* **런타임 전환**:
  `.env` 파일에서 `OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun` 또는 `Dockerfile.v1.1`로 변경 후 실행:
  ```bash
  docker compose up -d
  ```
* **서비스 중지**:
  ```bash
  docker compose down
  ```
