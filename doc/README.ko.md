# OmniRoute AI Gateway for Cursor & 코딩 IDE

[English](../README.md) | [简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md) | [한국어](README.ko.md) | [日本語](README.ja.md)

---

**Cursor**, **Windsurf**, **Claude Code** 사용자를 위한 자체 호스팅 AI 게이트웨이 배포 스택으로, **[OmniRoute](https://github.com/diegosouzapw/OmniRoute)**, **Nginx**, **Cloudflare Tunnel**을 **Docker Compose**로 패키징했습니다.

라우터의 인바운드 포트를 열지 않고도 공용 인터넷을 통해 코딩 IDE 및 SDK 클라이언트를 안전하게 연결하며, **Server-Sent Events (SSE) 실시간 스트리밍**과 포괄적인 토큰 남용 방지 기능을 제공합니다.

---

### 💡 토큰 걱정 제로: 지능형 비용 최적화

AI 코딩 어시스턴트는 코드베이스 색인 및 에이전트 루프 실행 시 많은 토큰을 소모할 수 있습니다. OmniRoute는 스마트 라우팅을 통해 비용을 최적화합니다:

![Zero Token Anxiety](images/zero_token_anxiety.png)

---

## 🏛 아키텍처 개요

![Architecture Overview](images/architecture_overview.png)

### 4단계 심층 방어 체계

1. **계층 1: Cloudflare Edge**: 엣지에서 대규모 DDoS 공격 및 악성 봇을 차단하고 글로벌 SSL 인증서를 제공합니다.
2. **계층 2: Zero Trust Access (경로별 분리 인증)**: 웹 대시보드(UI)는 SSO로 철저히 보호하고, `/v1/*` API 경로는 Bearer API 키 통신을 위해 SSO를 우회(Bypass)합니다.
3. **계층 3: Nginx 리버스 프록시**:
   * 공식 Cloudflare CIDR 기반으로 실제 클라이언트 IP(`CF-Connecting-IP`)를 복원합니다.
   * 다중 영역 속도 제한(API: 1 req/s, 버스트 10; 로그인: 5 req/min; UI: 10 req/s) 및 10 MiB 요청 본문 크기를 제한합니다.
   * 버퍼링 없는 실시간 SSE 스트리밍(`proxy_buffering off;`)과 600초 타임아웃을 지원합니다.
4. **계층 4: OmniRoute 애플리케이션**: 권위 있는 API 키 검증, 키별 일일 사용량/세션 한도 적용 및 업스트림 제공자 자동 장애 조치(Failover)를 수행합니다.

---

## 🚀 빠른 시작 가이드

### 1. 사전 요구사항 및 Cloudflare Tunnel 설정
1. [Docker](https://docs.docker.com/get-docker/) 및 Docker Compose를 설치합니다.
2. [Cloudflare Zero Trust 대시보드](https://one.dash.cloudflare.com/)에 로그인합니다(무료 플랜 사용 가능).
3. **Networks** > **Tunnels** > **Add a Tunnel** 클릭 > **Cloudflared** 선택.
4. 터널 이름(예: `omniroute-tunnel`)을 지정하고 **Docker**를 선택한 후 터널 토큰(`--token` 뒤의 문자열)을 복사합니다.
5. **Public Hostnames** 탭에서:
   * **Subdomain / Domain**: 예: `ai` / `yourdomain.com` (전체 도메인: `ai.yourdomain.com`).
   * **Service Type**: `HTTP`
   * **URL**: `nginx:80` (또는 `http://nginx:80`).
6. 터널 설정을 저장합니다.

---

### 2. 환경 변수 설정
템플릿 파일을 복사합니다:
```bash
cp .env.example .env
```

`.env` 파일을 편집합니다:
```bash
# Cloudflare Tunnel Token 입력
CLOUDFLARE_TUNNEL_TOKEN=eyJhIjoi...YOUR_TOKEN...

# 강력한 관리자 비밀번호 생성: openssl rand -base64 16
INITIAL_PASSWORD=<생성된_비밀번호_입력>

# 64자리 Hex 보안 비밀키 생성: openssl rand -hex 32
JWT_SECRET=<생성된_시크릿_입력>

# 퍼블릭 접속 URL (OAuth 콜백 및 보안 쿠키용)
NEXT_PUBLIC_BASE_URL=https://ai.yourdomain.com
BASE_URL=https://ai.yourdomain.com

# 기본 Node Alpine 빌드
OMNIROUTE_DOCKERFILE=Dockerfile.v1.1
OMNIROUTE_IMAGE=omniroute:3.8.49
```

파일 권한 설정:
```bash
chmod 600 .env
```

---

### 3. 스택 빌드 및 실행
```bash
docker compose up -d
```

컨테이너 상태 확인:
```bash
docker compose ps
```

---

### 4. Cloudflare Zero Trust Access 설정: 경로 분기 및 SSO 보호

Cursor 및 SDK가 Bearer API 키로 원활하게 호출하도록 허용하면서, 웹 관리 대시보드는 SSO로 보호하려면 **Zero Trust 대시보드**(**Access** > **Applications**)에서 경로별 애플리케이션을 생성합니다:

#### A. API 우회 애플리케이션 (`/v1/*`)
1. **Self-Hosted** 애플리케이션 추가.
2. **Application Name**: `Bypass LLM API v1`
3. **Domain / Path**: `ai.yourdomain.com` / `v1/*`
4. **Policy**: Name `Allow API Traffic`, Action `Bypass`, Include `Everyone` (또는 특정 IP 대역).

#### B. 헬스체크 우회 애플리케이션 (`/health`)
1. **Self-Hosted** 애플리케이션 추가.
2. **Domain / Path**: `ai.yourdomain.com` / `health`
3. **Policy**: Action `Bypass`, Include `Everyone`.

#### C. 루트 관리자 SSO 애플리케이션 (`/`)
1. 루트 도메인을 포함하는 **Self-Hosted** 애플리케이션 추가 (**Path**는 비워둠).
2. **Policy**: Action `Allow`, Include `Emails` (사용자 이메일) 또는 SSO ID 그룹 (Google, GitHub).

> **작동 원리:** Cloudflare는 가장 구체적인 경로를 먼저 평가합니다. `/v1/*` 요청은 Cloudflare SSO를 우회하여 OmniRoute에서 API 키로 인증되며, 웹 대시보드(`/`, `/dashboard`) 접속 시에는 SSO 인증이 요구됩니다.

---

### 5. Cursor IDE 설정

1. **Cursor Settings** (`Cmd + ,` 또는 `Ctrl + ,`) > **Models** > **OpenAI API Key**로 이동합니다.
2. **Override OpenAI Base URL**을 활성화합니다:
   * **Base URL**: `https://ai.yourdomain.com/v1`
   > **⚠️ 중요:** 반드시 `https://`를 사용해야 합니다. `http://`를 사용하면 리디렉션 문제로 인해 **`405 Method Not Allowed`** 오류가 발생합니다.
3. **OpenAI API Key** 항목에:
   * OmniRoute 대시보드에서 생성한 Gateway API Key를 입력합니다.
4. Cursor Chat (`Cmd + L` 또는 `Ctrl + L`)에서 테스트하면 토큰이 실시간 스트리밍됩니다.

---

### 6. 웹 대시보드 접속

1. 브라우저에서 `https://ai.yourdomain.com/`에 접속합니다.
2. Cloudflare Access (SSO / 이메일 OTP) 인증을 진행합니다.
3. `.env`에 설정한 `INITIAL_PASSWORD`로 로그인합니다.
4. AI 제공자 API 키(Anthropic, OpenAI, DeepSeek, Google Gemini, Ollama 등)를 등록하고 IDE용 게이트웨이 키를 생성합니다.

---

## 🧪 검증 및 테스트

### 1. 헬스체크 및 무인증 차단 테스트
```bash
# 헬스체크 (200 OK 반환 확인)
curl https://ai.yourdomain.com/health

# 미인증 요청 즉시 차단 (401 반환 확인)
curl -i https://ai.yourdomain.com/v1/chat/completions
```

### 2. 모델 추론 및 실시간 SSE 스트리밍 테스트
```bash
# 일반 응답 테스트
curl https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "messages": [{"role": "user", "content": "Hello!"}]}'

# 실시간 SSE 스트리밍 테스트
curl -N https://ai.yourdomain.com/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer <YOUR_OMNIROUTE_API_KEY>" \
  -d '{"model": "auto", "stream": true, "messages": [{"role": "user", "content": "Count 1 to 5"}]}'
```

---

## 💰 Cloudflare 비용 안내: $0.00 / 월 (100% 무료)

이 배포 스택은 Cloudflare의 영구 무료 **Zero Trust Free Tier**를 활용합니다:

| Cloudflare 서비스 | 본 스택 사용 방식 | 무료 플랜 한도 | 비용 |
| :--- | :--- | :--- | :--- |
| **Cloudflare Tunnel (`cloudflared`)** | 보안 아웃바운드 역방향 프록시 | **터널 및 대역폭 무제한** | **$0.00** |
| **Cloudflare Access (Zero Trust SSO)** | `/` 관리 대시보드 SSO / OTP 보호 | **최대 50명 활성 사용자** | **$0.00** |
| **Edge SSL / TLS 인증서** | 커스텀 도메인 Universal SSL | **무제한 자동 갱신 SSL** | **$0.00** |
| **Data Egress (아웃바운드 트래픽)** | IDE로 모델 응답 스트리밍 | **데이터 전송료 무료** | **$0.00** |

---

## 🔐 구현된 보안 강화 조치

민감한 AI 제공자 키를 보호하고 비용 폭증을 방지하기 위한 다층 보안 체계:

* **강화된 컨테이너 런타임**: 최소화된 Alpine 이미지(`node:22-alpine` 또는 `oven/bun:alpine`), `su-exec`를 통한 비루트 실행 및 `dumb-init` 프로세스 신호 제어.
* **헤더 정제 및 엄격한 CORS**: 업스트림 전달 전 검증되지 않은 `Cf-Access-*` 헤더 제거 및 와일드카드 CORS 비활성화로 브라우저 교차 출처 남용 차단.
* **Nginx 사전 미인증 필터링**: `/v1/*` 요청의 인증 헤더(`Authorization`, `x-api-key`, `x-goog-api-key`) 유무를 사전 검사하여 무인증 요청을 즉시 401로 차단.
* **실제 IP 복원 및 신뢰할 수 있는 프록시**: 공식 Cloudflare CIDR 및 정적 터널 IP만 신뢰하여 `CF-Connecting-IP`로 실제 클라이언트 IP를 정확히 추출.

### 속도 및 한도 제어

| 제어 항목 | 설정값 | 목적 |
| :--- | :--- | :--- |
| **API 요청 속도** | IP당 1 req/s (버스트 10) | IDE 도구 호출 버스트를 허용하면서 고빈도 자동 스크래핑 방지 |
| **동시 추론 연결 수** | IP당 8 / 글로벌 12 | 연결 고갈 공격 방지 |
| **키별 일일 사용량 및 지출** | 60 RPM, 1,000 req/일, $10/일 | 단일 키 유출 시 피해 규모 제한 |
| **로그인 시도** | 5 req/min (버스트 5) | 관리자 대시보드 무차별 대입 공격 방어 |
| **요청 본문 크기 / 타임아웃** | 10 MiB / 600s | 메모리 증폭 방지 및 긴 SSE 생성 보장 |

---

*Built with Antigravity • Security settings verified with GPT Sol 5.6*
