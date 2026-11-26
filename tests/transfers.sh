#!/bin/bash
# End-to-end test of GET /api/v1/transfers (doc/spec/transfers.md): idle,
# an upload while its body arrives, a download while it streams (and that
# kontor answers other requests meanwhile), the completed counters.
#   AIML_BIN=/path/to/aiml tests/transfers.sh        (or KONTOR_BIN=./kontor)
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
if [ -n "${KONTOR_BIN:-}" ]; then KONTOR_RUN=("$KONTOR_BIN"); else KONTOR_RUN=("$AIML_BIN" kontor.aiml --); fi
PORT="${PORT:-18098}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
FAILS=0
PASSES=0
SRV=""
BG=""
trap 'kill $SRV $BG 2>/dev/null; rm -rf "$WORK"' EXIT

pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null; }
ADMIN_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
status() { curl -s -o "${OUT:-$WORK/body}" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }
transfers() { status "$BASE/api/v1/transfers" > "$WORK/code"; }
# Polls until the transfers document satisfies the python expression $1 (≤ 5 s).
wait_for() {
    for _ in $(seq 50); do
        transfers; [ "$(json "$WORK/body" "$1")" = "True" ] && return 0; sleep 0.1
    done
    return 1
}

KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "${KONTOR_RUN[@]}" "$PORT" "$WORK/data" > "$WORK/server.log" 2>&1 &
SRV=$!
for _ in $(seq $((${STARTUP_WAIT:-20} * 5))); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done
curl -s -o /dev/null "$BASE/api/health" || { echo "FAIL server did not start"; tail -20 "$WORK/server.log"; exit 1; }

echo "TR-10: idle"
check "status" "$(status "$BASE/api/v1/transfers")" "200"
check "nothing running" "$(json "$WORK/body" "(j['active'], j['uploads'], j['downloads'], j['transfers'])")" "(False, 0, 0, [])"
check "nothing done yet" "$(json "$WORK/body" "(j['completed'], j['last_activity_ms'])")" "({'uploads': 0, 'downloads': 0}, None)"
check "alias /api/transfers" "$(status "$BASE/api/transfers")" "200"
check "not cached" "$(curl -s -D - -o /dev/null -H "Authorization: Bearer $ADMIN_TOKEN" "$BASE/api/v1/transfers" | tr -d '\r' | grep -i '^cache-control:' | cut -d' ' -f2)" "no-store"

echo "TR-20: an upload while its body arrives"
head -c 6000000 /dev/urandom > "$WORK/big.bin"
curl -s -o "$WORK/up.json" -H "Authorization: Bearer $ADMIN_TOKEN" -H 'Expect:' --limit-rate 2M \
    -T "$WORK/big.bin" "$BASE/generic/ci/big.bin" &
BG=$!
if wait_for "j['active'] and j['uploads'] == 1 and j['transfers'][0]['phase'] == 'receiving' and j['transfers'][0]['bytes'] > 0"; then
    pass "upload is seen while receiving"
else
    fail "upload not seen: $(cat "$WORK/body")"
fi
check "receiving: direction" "$(json "$WORK/body" "j['transfers'][0]['direction']")" "upload"
check "receiving: path not known yet" "$(json "$WORK/body" "j['transfers'][0]['path']")" "None"
wait "$BG"; BG=""
check "upload stored" "$(json "$WORK/up.json" "j['size']")" "6000000"
wait_for "not j['active']" && pass "idle after the upload" || fail "still active: $(cat "$WORK/body")"
check "one upload completed" "$(json "$WORK/body" "j['completed']['uploads']")" "1"

echo "TR-21: a download while it streams"
curl -s -o "$WORK/down.bin" -H "Authorization: Bearer $ADMIN_TOKEN" --limit-rate 2M "$BASE/generic/ci/big.bin" &
BG=$!
if wait_for "j['downloads'] == 1"; then pass "download is seen"; else fail "download not seen: $(cat "$WORK/body")"; fi
check "download entry" "$(json "$WORK/body" "[(t['direction'], t['phase'], t['method'], t['path'], t['user'], t['bytes']) for t in j['transfers']]")" \
    "[('download', 'sending', 'GET', '/generic/ci/big.bin', 'admin', 6000000)]"
# TR-06: the stream does not hold kontor's lock
START=$(date +%s%N)
check "other requests answer meanwhile" "$(status "$BASE/api/v1/catalog")" "200"
ELAPSED_MS=$(( ($(date +%s%N) - START) / 1000000 ))
if [ "$ELAPSED_MS" -lt 1000 ]; then pass "... at once (${ELAPSED_MS} ms)"; else fail "catalog took ${ELAPSED_MS} ms"; fi
wait "$BG"; BG=""
check "download complete" "$(cmp -s "$WORK/big.bin" "$WORK/down.bin" && echo same)" "same"
wait_for "not j['active']" && pass "idle after the download" || fail "still active: $(cat "$WORK/body")"
check "one download completed" "$(json "$WORK/body" "j['completed']['downloads']")" "1"
check "last activity set" "$(json "$WORK/body" "j['last_activity_ms'] > 0")" "True"

echo "TR-04: a HEAD and a failed read are no downloads"
check "HEAD" "$(status -I "$BASE/v2/")" "200"
check "missing" "$(status "$BASE/generic/ci/nope.bin")" "404"
transfers
check "still one download" "$(json "$WORK/body" "j['completed']['downloads']")" "1"

echo "TR-12: needs the read right"
printf 'auth:\n  anonymous: none\n' > "$WORK/data/kontor.yaml"
kill "$SRV"; wait "$SRV" 2>/dev/null
KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "${KONTOR_RUN[@]}" "$PORT" "$WORK/data" > "$WORK/server.log" 2>&1 &
SRV=$!
for _ in $(seq $((${STARTUP_WAIT:-20} * 5))); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done
check "anonymous refused" "$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/v1/transfers")" "401"
check "admin allowed" "$(status "$BASE/api/v1/transfers")" "200"

echo "transfers: $PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
