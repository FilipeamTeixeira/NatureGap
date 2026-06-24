#!/usr/bin/env bash
set -euo pipefail

# Next.js hangs when node_modules lives on iCloud Drive (CloudDocs file provider).
# Dependencies and the .next cache are kept in ~/.local/naturegap-dev instead.

LOCAL="$HOME/.local/naturegap-dev"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ ! -d "$LOCAL/node_modules/next" ]]; then
  echo "→ First run: installing dependencies outside iCloud (~/.local/naturegap-dev)…"
  mkdir -p "$LOCAL"
  cp "$ROOT/package.json" "$ROOT/package-lock.json" "$LOCAL/"
  (cd "$LOCAL" && npm ci --silent)
  echo "→ Done."
fi

mkdir -p "$LOCAL/.next"
cd "$ROOT"

exec env NEXT_CACHE_DIR="$LOCAL/.next" NODE_PATH="$LOCAL/node_modules" \
  node "$LOCAL/node_modules/.bin/next" dev --webpack "$@"
