#!/bin/sh
set -e

DATA_PATH="${DATA_DIR:-/app/data}"
mkdir -p "$DATA_PATH"

# If running as root, fix volume permissions and drop privileges to omniroute user
if [ "$(id -u)" = "0" ]; then
    chown -R omniroute:omniroute "$DATA_PATH" 2>/dev/null || true
    chmod -R 775 "$DATA_PATH" 2>/dev/null || true
    exec su-exec omniroute "$@"
fi

# Execute the main application command
exec "$@"
