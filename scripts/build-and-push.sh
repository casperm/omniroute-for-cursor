#!/usr/bin/env bash
# ==============================================================================
# OmniRoute x64 Cross-Platform Build & Push to GitHub Container Registry (GHCR)
# Supports Colima on macOS (Apple Silicon / Intel), Docker Buildx, and
# Auto-Incrementing Version Tags starting from 1.0.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
VERSION_FILE="${ROOT_DIR}/.image-version"
ENV_FILE="${ROOT_DIR}/.env"

# Defaults
DEFAULT_PLATFORM="linux/amd64"
PLATFORM="${TARGET_PLATFORM:-${DEFAULT_PLATFORM}}"
RUNTIME_CHOICE="bun"
BUMP_TYPE="minor"
MANUAL_TAG=""
NO_BUMP=false
DO_PUSH=true
DRY_RUN=false
GH_USER=""
PKG_VERSION="latest"

# ------------------------------------------------------------------------------
# Helper Functions
# ------------------------------------------------------------------------------
print_banner() {
    echo "=================================================================="
    echo "🚀 OmniRoute x64 GHCR Builder & Publisher"
    echo "=================================================================="
}

log_info() {
    echo "ℹ️  $*"
}

log_success() {
    echo "✅ $*"
}

log_warn() {
    echo "⚠️  $*"
}

log_error() {
    echo "❌ $*" >&2
}

show_help() {
    cat << EOF
Usage: ./scripts/build-and-push.sh [RUNTIME] [OPTIONS]

Runtime:
  bun                    Use Bun on Alpine (Dockerfile.v1.1.bun - default, ultra-fast)
  node                   Use Node.js 22 on Alpine (Dockerfile.v1.1)

Options:
  -u, --user <username>  GitHub username or org (default: read from .env GITHUB_USERNAME)
  -t, --tag <tag>        Explicitly use this tag (bypasses auto-increment)
  -b, --bump <type>      Bump type: minor (default, 1.0->1.1), patch (1.0->1.0.1), major (1.0->2.0)
  --no-bump              Use version in .image-version without auto-incrementing next
  -p, --platform <plat>  Target platform (default: linux/amd64)
  --pkg-version <ver>    OmniRoute package version (default: latest)
  --no-push              Build and load image locally instead of pushing to GHCR
  --dry-run              Display the computed build plan without executing commands
  -h, --help             Show this help message

Examples:
  ./scripts/build-and-push.sh                      # Auto-increment (1.0 -> 1.1), build x64 Bun, push to GHCR
  ./scripts/build-and-push.sh node                 # Build Node.js runtime instead
  ./scripts/build-and-push.sh --bump patch         # Bump patch version (e.g. 1.0.1)
  ./scripts/build-and-push.sh --tag 2.0.0          # Pin specific tag
  ./scripts/build-and-push.sh --dry-run            # Preview tags and build arguments
EOF
}

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        bun)
            RUNTIME_CHOICE="bun"
            shift
            ;;
        node)
            RUNTIME_CHOICE="node"
            shift
            ;;
        -u|--user)
            GH_USER="$2"
            shift 2
            ;;
        -t|--tag)
            MANUAL_TAG="$2"
            shift 2
            ;;
        -b|--bump)
            BUMP_TYPE="$2"
            shift 2
            ;;
        --no-bump)
            NO_BUMP=true
            shift
            ;;
        -p|--platform)
            PLATFORM="$2"
            shift 2
            ;;
        --pkg-version)
            PKG_VERSION="$2"
            shift 2
            ;;
        --no-push)
            DO_PUSH=false
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
done

print_banner

# ------------------------------------------------------------------------------
# 1. Resolve GitHub Username
# ------------------------------------------------------------------------------
if [ -z "${GH_USER}" ] && [ -f "${ENV_FILE}" ]; then
    GH_USER=$(grep -E '^GITHUB_USERNAME=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ' || true)
fi

# Sanitize username: GHCR requires lowercase
GH_USER=$(echo "${GH_USER}" | tr '[:upper:]' '[:lower:]')

if [ -z "${GH_USER}" ] || [ "${GH_USER}" = "your_github_username" ]; then
    log_warn "GitHub username not configured in .env."
    if [ -t 0 ]; then
        read -r -p "Enter your GitHub username or organization: " input_user
        GH_USER=$(echo "${input_user}" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
    fi
fi

if [ -z "${GH_USER}" ] || [ "${GH_USER}" = "your_github_username" ]; then
    log_error "A valid GitHub username/organization is required for GHCR."
    log_error "Please set GITHUB_USERNAME in .env or pass --user <username>."
    exit 1
fi

IMAGE_NAME="ghcr.io/${GH_USER}/omniroute"

# ------------------------------------------------------------------------------
# 2. Version Management & Auto-Increment Logic (Starting from 1.0)
# ------------------------------------------------------------------------------
compute_next_version() {
    local curr="$1"
    local bump="$2"
    local major minor patch

    major=$(echo "${curr}" | cut -d. -f1)
    minor=$(echo "${curr}" | cut -d. -f2)
    patch=$(echo "${curr}" | cut -d. -f3)

    if [ -z "${major}" ]; then major=1; fi
    if [ -z "${minor}" ]; then minor=0; fi

    case "${bump}" in
        patch)
            if [ -z "${patch}" ]; then
                patch=1
            else
                patch=$((patch + 1))
            fi
            echo "${major}.${minor}.${patch}"
            ;;
        major)
            major=$((major + 1))
            echo "${major}.0"
            ;;
        minor|*)
            minor=$((minor + 1))
            echo "${major}.${minor}"
            ;;
    esac
}

# Initialize .image-version if missing
if [ ! -f "${VERSION_FILE}" ]; then
    echo "1.0" > "${VERSION_FILE}"
fi

CURRENT_VERSION=$(tr -d '[:space:]' < "${VERSION_FILE}")
if [ -z "${CURRENT_VERSION}" ]; then
    CURRENT_VERSION="1.0"
fi

if [ -n "${MANUAL_TAG}" ]; then
    BUILD_TAG="${MANUAL_TAG}"
    NEXT_VERSION="${CURRENT_VERSION}"
    log_info "Using manual tag: ${BUILD_TAG}"
else
    BUILD_TAG="${CURRENT_VERSION}"
    NEXT_VERSION=$(compute_next_version "${CURRENT_VERSION}" "${BUMP_TYPE}")
    log_info "Auto-incrementing tag version: Current = ${BUILD_TAG} (Next will be = ${NEXT_VERSION})"
fi

# ------------------------------------------------------------------------------
# 3. Select Dockerfile & Package Version
# ------------------------------------------------------------------------------
if [ "${RUNTIME_CHOICE}" = "bun" ]; then
    DOCKERFILE="omniroute/Dockerfile.v1.1.bun"
    log_info "Runtime: Bun on Alpine (${DOCKERFILE})"
else
    DOCKERFILE="omniroute/Dockerfile.v1.1"
    log_info "Runtime: Node.js 22 on Alpine (${DOCKERFILE})"
fi

if [ -f "${ENV_FILE}" ] && [ "${PKG_VERSION}" = "latest" ]; then
    ENV_PKG_VER=$(grep -E '^OMNIROUTE_PKG_VERSION=' "${ENV_FILE}" | cut -d= -f2- | tr -d '"' | tr -d "'" | tr -d ' ' || true)
    if [ -n "${ENV_PKG_VER}" ]; then
        PKG_VERSION="${ENV_PKG_VER}"
    fi
fi

TAG_VERSIONED="${IMAGE_NAME}:${BUILD_TAG}"
TAG_LATEST="${IMAGE_NAME}:latest"

log_info "Target Platform: ${PLATFORM}"
log_info "Target Tags:     ${TAG_VERSIONED} and ${TAG_LATEST}"
log_info "OmniRoute PKG:   ${PKG_VERSION}"

# ------------------------------------------------------------------------------
# 4. Dry Run Check
# ------------------------------------------------------------------------------
if [ "${DRY_RUN}" = true ]; then
    echo "------------------------------------------------------------------"
    echo "🔍 DRY RUN: Previewing Build Execution Plan"
    echo "------------------------------------------------------------------"
    echo "• Image Registry:   ${IMAGE_NAME}"
    echo "• Build Tag:        ${BUILD_TAG}"
    echo "• Latest Tag:       ${TAG_LATEST}"
    echo "• Next Tag Store:   ${NEXT_VERSION}"
    echo "• Dockerfile:       ${DOCKERFILE}"
    echo "• Target Platform:  ${PLATFORM}"
    echo "• Push Enabled:     ${DO_PUSH}"
    echo "• Build Command:"
    if [ "${DO_PUSH}" = true ]; then
        echo "    docker buildx build --platform ${PLATFORM} -f ${DOCKERFILE} --build-arg OMNIROUTE_PKG_VERSION=${PKG_VERSION} -t ${TAG_VERSIONED} -t ${TAG_LATEST} --push omniroute"
    else
        echo "    docker buildx build --platform ${PLATFORM} -f ${DOCKERFILE} --build-arg OMNIROUTE_PKG_VERSION=${PKG_VERSION} -t ${TAG_VERSIONED} -t ${TAG_LATEST} --load omniroute"
    fi
    echo "------------------------------------------------------------------"
    log_success "Dry run complete. No changes made."
    exit 0
fi

# ------------------------------------------------------------------------------
# 5. Colima & Docker Daemon Health Checks
# ------------------------------------------------------------------------------
check_docker_daemon() {
    if ! docker info >/dev/null 2>&1; then
        log_warn "Docker daemon is not reachable on current context ($(docker context show 2>/dev/null || echo 'default'))."
        
        if command -v colima >/dev/null 2>&1; then
            log_info "Colima is installed. Checking status..."
            if ! colima status >/dev/null 2>&1; then
                log_warn "Colima VM is stopped."
                echo ""
                echo "To start Colima with hardware-accelerated Rosetta x86_64 emulation on Apple Silicon, run:"
                echo "   colima start --arch aarch64 --vm-type vz --vz-rosetta"
                echo ""
                echo "Or standard start:"
                echo "   colima start"
                echo ""
                if [ -t 0 ]; then
                    read -r -p "Do you want to start Colima now with Rosetta? [y/N]: " start_colima
                    if [[ "${start_colima}" =~ ^[Yy]$ ]]; then
                        log_info "Starting Colima..."
                        colima start --arch aarch64 --vm-type vz --vz-rosetta || colima start
                    else
                        log_error "Cannot continue without an active Docker daemon."
                        exit 1
                    fi
                else
                    log_error "Please start Colima or Docker daemon and try again."
                    exit 1
                fi
            fi
        else
            log_error "Docker is not running. Please start your Docker daemon and retry."
            exit 1
        fi
    fi
    log_success "Docker daemon is active."
}

check_docker_daemon

# ------------------------------------------------------------------------------
# 6. Verify or Setup Buildx Builder
# ------------------------------------------------------------------------------
setup_builder() {
    log_info "Checking Docker Buildx multi-platform builder..."
    if ! docker buildx version >/dev/null 2>&1; then
        log_error "docker buildx is required for cross-compiling x64 images."
        exit 1
    fi

    # Check current builder; ensure a dedicated container builder exists for multi-arch
    local current_builder
    current_builder=$(docker buildx inspect 2>/dev/null | grep -E '^Name:' | head -n 1 | awk '{print $2}' || true)
    
    if [ -z "${current_builder}" ] || [ "${current_builder}" = "default" ] || [ "${current_builder}" = "colima" ]; then
        if ! docker buildx inspect omniroute-builder >/dev/null 2>&1; then
            log_info "Creating dedicated multi-platform builder instance (omniroute-builder)..."
            docker buildx create --name omniroute-builder --driver docker-container --use
        else
            docker buildx use omniroute-builder
        fi
        docker buildx inspect --bootstrap >/dev/null 2>&1 || true
    fi
    log_success "Buildx builder ready: $(docker buildx inspect 2>/dev/null | grep -E '^Name:' | head -n 1 | awk '{print $2}')"
}

setup_builder

# ------------------------------------------------------------------------------
# 7. Check GHCR Authentication
# ------------------------------------------------------------------------------
if [ "${DO_PUSH}" = true ]; then
    log_info "Verifying GitHub Container Registry authentication for ${GH_USER}..."
    # Check if ghcr.io exists in docker config
    local_config="${DOCKER_CONFIG:-${HOME}/.docker}/config.json"
    if [ ! -f "${local_config}" ] || ! grep -q "ghcr.io" "${local_config}" 2>/dev/null; then
        log_warn "Authentication token for ghcr.io not detected in ${local_config}."
        echo ""
        echo "To push images to GitHub Container Registry:"
        echo "1. Create a GitHub Personal Access Token (classic) with 'write:packages', 'read:packages', 'delete:packages'."
        echo "2. Log in with:"
        echo "   echo \$GITHUB_TOKEN | docker login ghcr.io -u ${GH_USER} --password-stdin"
        echo ""
        if [ -t 0 ]; then
            read -r -p "Have you logged into ghcr.io or would you like to attempt push anyway? [y/N]: " proceed_auth
            if [[ ! "${proceed_auth}" =~ ^[Yy]$ ]]; then
                log_error "Push aborted. Please log into ghcr.io first."
                exit 1
            fi
        fi
    fi
fi

# ------------------------------------------------------------------------------
# 8. Build and Push x64 Docker Image
# ------------------------------------------------------------------------------
echo "------------------------------------------------------------------"
echo "🔨 Building [${PLATFORM}] image: ${TAG_VERSIONED}..."
echo "------------------------------------------------------------------"

BUILD_ARGS=(
    --platform "${PLATFORM}"
    -f "${ROOT_DIR}/${DOCKERFILE}"
    --build-arg "OMNIROUTE_PKG_VERSION=${PKG_VERSION}"
    -t "${TAG_VERSIONED}"
    -t "${TAG_LATEST}"
)

if [ "${DO_PUSH}" = true ]; then
    BUILD_ARGS+=(--push)
else
    BUILD_ARGS+=(--load)
fi

BUILD_ARGS+=("${ROOT_DIR}/omniroute")

docker buildx build "${BUILD_ARGS[@]}"

log_success "Build completed successfully!"

# ------------------------------------------------------------------------------
# 9. Post-Build: Advance Version & Sync with .env
# ------------------------------------------------------------------------------
if [ "${NO_BUMP}" = false ] && [ -z "${MANUAL_TAG}" ]; then
    echo "${NEXT_VERSION}" > "${VERSION_FILE}"
    log_info "Updated .image-version to next version: ${NEXT_VERSION}"
fi

# Update .env if it exists
if [ -f "${ENV_FILE}" ]; then
    log_info "Synchronizing .env with newly built image tag [${BUILD_TAG}]..."
    
    # Update GITHUB_USERNAME
    if grep -q "^GITHUB_USERNAME=" "${ENV_FILE}"; then
        sed -i.bak "s|^GITHUB_USERNAME=.*|GITHUB_USERNAME=${GH_USER}|" "${ENV_FILE}" 2>/dev/null || true
    else
        echo "GITHUB_USERNAME=${GH_USER}" >> "${ENV_FILE}"
    fi

    # Update OMNIROUTE_IMAGE
    if grep -q "^OMNIROUTE_IMAGE=" "${ENV_FILE}"; then
        sed -i.bak "s|^OMNIROUTE_IMAGE=.*|OMNIROUTE_IMAGE=${IMAGE_NAME}|" "${ENV_FILE}" 2>/dev/null || true
    else
        echo "OMNIROUTE_IMAGE=${IMAGE_NAME}" >> "${ENV_FILE}"
    fi

    # Update OMNIROUTE_IMAGE_TAG
    if grep -q "^OMNIROUTE_IMAGE_TAG=" "${ENV_FILE}"; then
        sed -i.bak "s|^OMNIROUTE_IMAGE_TAG=.*|OMNIROUTE_IMAGE_TAG=${BUILD_TAG}|" "${ENV_FILE}" 2>/dev/null || true
    else
        echo "OMNIROUTE_IMAGE_TAG=${BUILD_TAG}" >> "${ENV_FILE}"
    fi

    rm -f "${ENV_FILE}.bak"
    log_success ".env updated with OMNIROUTE_IMAGE_TAG=${BUILD_TAG} and OMNIROUTE_IMAGE=${IMAGE_NAME}"
fi

echo "=================================================================="
echo "🎉 Deployment Image Ready!"
echo "=================================================================="
if [ "${DO_PUSH}" = true ]; then
    echo "• Published:  ${TAG_VERSIONED}"
    echo "• Latest:     ${TAG_LATEST}"
    echo ""
    echo "To deploy or update on your server:"
    echo "  1. Copy docker-compose.yaml and .env to your server (if not already there)."
    echo "  2. Pull and start with Docker Compose:"
    echo "     docker compose pull omniroute"
    echo "     docker compose up -d"
else
    echo "• Local Image: ${TAG_VERSIONED}"
    echo "• (Image was loaded locally and not pushed)"
fi
echo "=================================================================="
