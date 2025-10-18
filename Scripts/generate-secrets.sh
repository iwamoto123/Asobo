#!/usr/bin/env bash
set -euo pipefail
: "${OPENAI_API_KEY:?set OPENAI_API_KEY}"
cat > Config/Secrets.xcconfig <<CONFIG
OPENAI_API_KEY = ${OPENAI_API_KEY}
CONFIG
