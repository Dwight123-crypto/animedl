#!/usr/bin/env bash
# Start the AnimeDL server and keep the Mac awake while it runs.
# Optional env: ANIMEDL_DIR (downloads folder), ANIMEDL_PORT (default 8765), ANIMEDL_TOKEN
set -euo pipefail
cd "$(dirname "$0")"
exec caffeinate -i python3 server.py
