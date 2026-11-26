#!/bin/bash
# FW-103: starts kontor with the built UI (ui/dist, ui/build.sh), the admin
# "ops" and a published project, and runs tests/ui_smoke.cjs (Playwright,
# headless Chromium) against it.
#   KONTOR_BIN=./kontor tests/ui_smoke.sh [screenshot.png]
set -u
cd "$(dirname "$0")/.."
KONTOR_BIN="${KONTOR_BIN:-./kontor}"
PORT="${PORT:-18098}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
SRV=""
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT
[ -f ui/dist/kontor-ui.wasm ] || { echo "FAIL no ui/dist (run ui/build.sh)"; exit 1; }
ADMIN_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
adm() { curl -s -o "$WORK/body" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }

KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "$KONTOR_BIN" "$PORT" "$WORK/data" --ui-dir ui/dist > "$WORK/server.log" 2>&1 &
SRV=$!
for _ in $(seq 100); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done
curl -s -o /dev/null "$BASE/api/health" || { echo "FAIL server did not start"; tail -20 "$WORK/server.log"; exit 1; }

setup() { [ "$2" = "$3" ] || { echo "FAIL setup $1: got $2 want $3"; exit 1; }; }
setup "admin ops" "$(adm -X POST -d '{"name":"ops","password":"ops-password-1","roles":["admin"]}' "$BASE/api/v1/users")" 201
printf '{"$schema":"exodus.project.config-1.0","name":"lib-a","version":"1.0.0","dependencies":[],"apt_packages":[]}' > "$WORK/m.json"
setup "manifest" "$(adm -X PUT --data-binary @"$WORK/m.json" "$BASE/exodus/lib-a/1.0.0/exodus.json")" 201
setup "package" "$(adm -X PUT --data-binary 'build' "$BASE/exodus/lib-a/1.0.0/package")" 201
setup "session" "$(curl -s -o "$WORK/body" -w '%{http_code}' -u ops:ops-password-1 -X POST "$BASE/api/v1/sessions")" 201
SESSION=$(python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print(j['id'] + ':' + j['token'])" "$WORK/body")

echo "ui smoke (FW-103)"
node tests/ui_smoke.cjs "$BASE" "$SESSION" "${1:-}"
