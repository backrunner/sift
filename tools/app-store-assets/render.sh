#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PWCLI="${CODEX_HOME:-$HOME/.codex}/skills/playwright/scripts/playwright_cli.sh"
PORT="8765"
PAGE="http://127.0.0.1:${PORT}/tools/app-store-assets/index.html"
OUTPUT="${ROOT}/output/app-store/1.0/final-v3.0"
SESSION="sift-app-store-assets"

mkdir -p "$OUTPUT"

python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT" \
  >"${TMPDIR:-/tmp}/sift-app-store-assets-server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" >/dev/null 2>&1 || true' EXIT

for _ in {1..30}; do
  if curl --silent --fail "http://127.0.0.1:${PORT}/tools/app-store-assets/index.html" \
    >/dev/null; then
    break
  fi
  sleep 0.1
done

for locale in zh-Hans en-US ja; do
  mkdir -p "$OUTPUT/$locale"
  for screen in 1 2 3 4 5 6; do
    filename="$(printf '%02d' "$screen")-sift.png"
    bash "$PWCLI" --session "$SESSION" open "${PAGE}?locale=${locale}&screen=${screen}"
    bash "$PWCLI" --session "$SESSION" resize 1284 2778
    bash "$PWCLI" --session "$SESSION" run-code \
      "async (page) => { await page.evaluate(() => window.appStoreAssetReady); await page.waitForTimeout(150); }"
    bash "$PWCLI" --session "$SESSION" screenshot \
      --filename "$OUTPUT/$locale/$filename"
  done
done

bash "$PWCLI" --session "$SESSION" close
