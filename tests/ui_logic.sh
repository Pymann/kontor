#!/bin/bash
# FW-102: starts kontor on a scratch data dir with the admin "ops", a
# published project and a generic file, then runs tests/ui_logic.aiml (the
# UI's api/store layer, natively) against it.
#   AIML_BIN=/path/to/aiml tests/ui_logic.sh        (or KONTOR_BIN=./kontor)
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
if [ -n "${KONTOR_BIN:-}" ]; then KONTOR_RUN=("$KONTOR_BIN"); else KONTOR_RUN=("$AIML_BIN" kontor.aiml --); fi
PORT="${PORT:-18097}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
SRV=""
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT
ADMIN_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
adm() { curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }

KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "${KONTOR_RUN[@]}" "$PORT" "$WORK/data" > "$WORK/server.log" 2>&1 &
SRV=$!
for _ in $(seq $((${STARTUP_WAIT:-20} * 5))); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done
curl -s -o /dev/null "$BASE/api/health" || { echo "FAIL server did not start"; tail -20 "$WORK/server.log"; exit 1; }

setup() { [ "$2" = "$3" ] || { echo "FAIL setup $1: got $2 want $3"; exit 1; }; }
setup "admin ops" "$(adm -X POST -d '{"name":"ops","password":"ops-password-1","roles":["admin"]}' "$BASE/api/v1/users")" 201
for v in 1.0.0 1.10.0; do
    printf '{"$schema":"exodus.project.config-1.0","name":"lib-a","version":"%s","dependencies":[],"apt_packages":[]}' "$v" > "$WORK/m.json"
    setup "manifest $v" "$(adm -X PUT --data-binary @"$WORK/m.json" "$BASE/exodus/lib-a/$v/exodus.json")" 201
    setup "package $v" "$(adm -X PUT --data-binary "build $v" "$BASE/exodus/lib-a/$v/package")" 201
done
setup "generic file" "$(adm -X PUT --data-binary 'hello' "$BASE/generic/ci/a.txt")" 201

echo "ui logic (FW-102)"
"$AIML_BIN" tests/ui_logic.aiml -- "$BASE" 2>&1 | grep -v WARNING
exit "${PIPESTATUS[0]}"
