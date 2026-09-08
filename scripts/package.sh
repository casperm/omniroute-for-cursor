#!/usr/bin/env bash
# ==============================================================================
# OmniRoute Deployment Packager
# Builds the Docker image locally (with target architecture support), exports it,
# and packages all configuration files into a standalone deployment tarball.
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
BUILD_DIR="${ROOT_DIR}/dist"
IMAGE_TAG="omniroute:custom-alpine"
DOCKERFILE="omniroute/Dockerfile.v1.1"
TARGET_PLATFORM="${TARGET_PLATFORM:-linux/amd64}" # Change to linux/arm64 if remote is ARM

echo "=================================================="
echo "🚀 OmniRoute Deployment Packager"
echo "=================================================="
echo "• Root Directory:    ${ROOT_DIR}"
echo "• Target Platform:   ${TARGET_PLATFORM}"
echo "• Image Tag:         ${IMAGE_TAG}"
echo "• Output Directory:  ${BUILD_DIR}"
echo "=================================================="

# Create clean distribution directory
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}/package"

# 1. Ask or detect Dockerfile type
if [ "${1:-}" = "bun" ]; then
    DOCKERFILE="omniroute/Dockerfile.v1.1.bun"
    IMAGE_TAG="omniroute:bun-alpine"
    echo "📦 Using Bun Alpine Dockerfile: ${DOCKERFILE}"
else
    echo "📦 Using Node.js Alpine Dockerfile: ${DOCKERFILE}"
fi

# 2. Build Docker Image (with cross-platform target if using buildx)
echo "🔨 Building Docker image [${IMAGE_TAG}] for platform [${TARGET_PLATFORM}]..."
if docker buildx version >/dev/null 2>&1; then
    docker buildx build \
        --platform "${TARGET_PLATFORM}" \
        -f "${ROOT_DIR}/${DOCKERFILE}" \
        -t "${IMAGE_TAG}" \
        --load \
        "${ROOT_DIR}/omniroute"
else
    docker build \
        -f "${ROOT_DIR}/${DOCKERFILE}" \
        -t "${IMAGE_TAG}" \
        "${ROOT_DIR}/omniroute"
fi

# 3. Export Docker Image to tar.gz
echo "💾 Exporting Docker image to archive (this may take a minute)..."
docker save "${IMAGE_TAG}" | gzip > "${BUILD_DIR}/package/omniroute-image.tar.gz"

# 4. Copy required deployment files to package
echo "📋 Copying runtime configs..."
cp "${ROOT_DIR}/docker-compose.yaml" "${BUILD_DIR}/package/"
cp "${ROOT_DIR}/.env.example" "${BUILD_DIR}/package/"
cp -r "${ROOT_DIR}/nginx" "${BUILD_DIR}/package/"
cp -r "${ROOT_DIR}/omniroute" "${BUILD_DIR}/package/"

# Clean any local runtime data, databases, or logs from the distribution package
rm -rf "${BUILD_DIR}/package/omniroute/data"
mkdir -p "${BUILD_DIR}/package/omniroute/data"
rm -rf "${BUILD_DIR}/package/nginx/logs"
mkdir -p "${BUILD_DIR}/package/nginx/logs"
touch "${BUILD_DIR}/package/nginx/logs/.gitkeep"
rm -f "${BUILD_DIR}/package/.env" "${BUILD_DIR}/package/omniroute/.env"

# Adjust default image tag in package's .env.example
if [ "${IMAGE_TAG}" = "omniroute:bun-alpine" ]; then
    sed -i.bak 's/OMNIROUTE_DOCKERFILE=Dockerfile.v1.1/OMNIROUTE_DOCKERFILE=Dockerfile.v1.1.bun/' "${BUILD_DIR}/package/.env.example" 2>/dev/null || true
    sed -i.bak 's/OMNIROUTE_IMAGE=omniroute:custom-alpine/OMNIROUTE_IMAGE=omniroute:bun-alpine/' "${BUILD_DIR}/package/.env.example" 2>/dev/null || true
    rm -f "${BUILD_DIR}/package/.env.example.bak"
fi

# 5. Create remote start script inside the package
cat << 'EOF' > "${BUILD_DIR}/package/start.sh"
#!/usr/bin/env bash
set -euo pipefail

echo "=================================================="
echo "🚀 OmniRoute Remote Deployment Launcher"
echo "=================================================="

# Check if .env exists
if [ ! -f .env ]; then
    echo "⚠️  .env file not found. Creating from .env.example..."
    cp .env.example .env
    echo "❗ Please edit .env with your CLOUDFLARE_TUNNEL_TOKEN and passwords before running."
    exit 1
fi

# Load pre-compiled Docker image
if [ -f omniroute-image.tar.gz ]; then
    echo "📦 Loading pre-compiled OmniRoute Docker image..."
    docker load < omniroute-image.tar.gz
fi

# Launch Docker Compose stack
echo "▶️  Starting OmniRoute services..."
if docker compose version >/dev/null 2>&1; then
    docker compose up -d
else
    docker-compose up -d
fi

echo "✅ Deployment successful! Check logs with: docker-compose logs -f"
EOF
chmod +x "${BUILD_DIR}/package/start.sh"

# Create remote update/stop script
cat << 'EOF' > "${BUILD_DIR}/package/stop.sh"
#!/usr/bin/env bash
set -euo pipefail

echo "🛑 Stopping OmniRoute services..."
if docker compose version >/dev/null 2>&1; then
    docker compose down
else
    docker-compose down
fi
echo "✅ Stopped."
EOF
chmod +x "${BUILD_DIR}/package/stop.sh"

# 6. Archive the entire package
ARCHIVE_NAME="omniroute-deploy-$(date +%Y%m%d_%H%M%S).tar.gz"
echo "📦 Compressing final deployment bundle: ${ARCHIVE_NAME}..."
tar -czf "${BUILD_DIR}/${ARCHIVE_NAME}" -C "${BUILD_DIR}/package" .

echo "=================================================="
echo "🎉 Package created successfully!"
echo "📍 Location: ${BUILD_DIR}/${ARCHIVE_NAME}"
echo "=================================================="
echo "To deploy to your remote PC:"
echo "1. Copy bundle to remote PC:"
echo "   scp ${BUILD_DIR}/${ARCHIVE_NAME} user@remote-pc:/opt/omniroute/"
echo "2. On the remote PC, unpack and run:"
echo "   tar -xzf ${ARCHIVE_NAME}"
echo "   cp .env.example .env && nano .env"
echo "   ./start.sh"
echo "=================================================="
