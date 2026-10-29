#!/bin/bash
# End-to-end test: starts kontor on a scratch data dir and drives it with curl.
#   AIML_BIN=/path/to/aiml tests/e2e.sh
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
PORT="${PORT:-18091}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
DATA="$WORK/data"
FAILS=0
PASSES=0
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT

pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
# json <file> <python expression over j>
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1"; }
ADMIN_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
# status: as admin (Bearer); anon: without credentials
status() { curl -s -o "${OUT:-$WORK/body}" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }
anon() { curl -s -o "${OUT:-$WORK/body}" -w '%{http_code}' "$@"; }

KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "$AIML_BIN" kontor.aiml -- "$PORT" "$DATA" > "$WORK/server.log" 2>&1 &
SRV=$!
for _ in $(seq $((${STARTUP_WAIT:-20} * 5))); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done
check "health" "$(status "$BASE/api/health")" "200"
grep -q "$ADMIN_TOKEN" "$WORK/server.log" && fail "bootstrap token appears in the log" || pass "bootstrap token not logged"

echo "auth"
check "anonymous whoami" "$(anon "$BASE/api/v1/whoami")" "200"
check "anonymous is reader" "$(json "$WORK/body" "(j['kind'], j['roles'])")" "('anonymous', ['reader'])"
check "admin whoami" "$(status "$BASE/api/v1/whoami")" "200"
check "admin roles" "$(json "$WORK/body" "(j['name'], j['roles'])")" "('admin', ['admin'])"
check "bad bearer -> 401" "$(anon -H 'Authorization: Bearer 00ff' "$BASE/api/v1/whoami")" "401"
check "401 error is JSON with code" "$(json "$WORK/body" "j['code']")" "unauthorized"
check "anonymous write -> 401" "$(anon -X PUT --data-binary 'x' "$BASE/generic/anon.bin")" "401"
check "challenge header" "$(curl -s -o /dev/null -D - -X PUT --data-binary x "$BASE/generic/anon.bin" | grep -i '^www-authenticate' | tr -d '\r')" 'www-authenticate: Basic realm="kontor"'
check "create user ci" "$(status -X POST -d '{"name":"ci","password":"s3cret-pass","roles":["writer"]}' "$BASE/api/v1/users")" "201"
check "short password rejected" "$(status -X POST -d '{"name":"bob","password":"short","roles":["reader"]}' "$BASE/api/v1/users")" "400"
check "users list" "$(status "$BASE/api/v1/users" > /dev/null; json "$WORK/body" "[u['name'] for u in j['users']]")" "['ci']"
check "basic user:password" "$(anon -u ci:s3cret-pass "$BASE/api/v1/whoami" > /dev/null; json "$WORK/body" "(j['name'], j['kind'])")" "('ci', 'user')"
check "wrong password -> 401" "$(anon -u ci:wrong-pass "$BASE/api/v1/whoami")" "401"
check "ci mints writer token" "$(anon -u ci:s3cret-pass -X POST -d '{"label":"pipeline","roles":["writer"]}' "$BASE/api/v1/tokens")" "201"
CI_TOKEN=$(json "$WORK/body" "j['token']"); CI_TOKEN_ID=$(json "$WORK/body" "j['id']")
check "token is 256-bit hex" "$(echo -n "$CI_TOKEN" | grep -cE '^[0-9a-f]{64}$')" "1"
check "only the hash is stored" "$(grep -rl "$CI_TOKEN" "$DATA/auth" 2>/dev/null | wc -l | tr -d ' ')" "0"
check "ci cannot mint admin token" "$(anon -u ci:s3cret-pass -X POST -d '{"label":"x","roles":["admin"]}' "$BASE/api/v1/tokens")" "403"
check "token via bearer" "$(anon -H "Authorization: Bearer $CI_TOKEN" "$BASE/api/v1/whoami" > /dev/null; json "$WORK/body" "(j['name'], j['kind'])")" "('ci', 'token')"
check "token via basic user:token" "$(anon -u "ci:$CI_TOKEN" -X PUT --data-binary 'ci' "$BASE/generic/ci/one.bin")" "201"
check "writer cannot list users" "$(anon -H "Authorization: Bearer $CI_TOKEN" "$BASE/api/v1/users")" "403"
check "403 code" "$(json "$WORK/body" "j['code']")" "forbidden"
check "ci lists own tokens" "$(anon -u ci:s3cret-pass "$BASE/api/v1/tokens" > /dev/null; json "$WORK/body" "[t['id'] for t in j['tokens']]")" "['$CI_TOKEN_ID']"
check "token list has no secrets" "$(grep -c "$CI_TOKEN" "$WORK/body")" "0"
check "revoke token" "$(anon -u ci:s3cret-pass -X DELETE "$BASE/api/v1/tokens/$CI_TOKEN_ID")" "204"
check "revoked token -> 401" "$(anon -H "Authorization: Bearer $CI_TOKEN" "$BASE/api/v1/whoami")" "401"
check "delete user" "$(status -X DELETE "$BASE/api/v1/users/ci")" "204"
check "deleted user -> 401" "$(anon -u ci:s3cret-pass "$BASE/api/v1/whoami")" "401"
check "unknown endpoint JSON 404" "$(anon "$BASE/api/v1/nope" > /dev/null; json "$WORK/body" "j['code']")" "not_found"

echo "generic repository"
head -c 3145728 /dev/urandom > "$WORK/blob.bin"
SHA=$(sha256sum "$WORK/blob.bin" | cut -d' ' -f1)
check "upload 3 MiB binary" "$(status -X PUT --data-binary @"$WORK/blob.bin" -H "X-Checksum-Sha256: $SHA" "$BASE/generic/tools/blob/1.0/blob.bin")" "201"
check "reported sha256" "$(json "$WORK/body" "j['sha256']")" "$SHA"
check "download" "$(curl -s -o "$WORK/back.bin" -w '%{http_code}' "$BASE/generic/tools/blob/1.0/blob.bin")" "200"
cmp -s "$WORK/blob.bin" "$WORK/back.bin" && pass "download is byte-identical" || fail "download differs"
check "range request" "$(curl -s -o "$WORK/part.bin" -w '%{http_code}' -H 'Range: bytes=100-199' "$BASE/generic/tools/blob/1.0/blob.bin")" "206"
cmp -s <(head -c 200 "$WORK/blob.bin" | tail -c 100) "$WORK/part.bin" && pass "range bytes match" || fail "range bytes differ"
check "checksum mismatch rejected" "$(status -X PUT --data-binary @"$WORK/blob.bin" -H 'X-Checksum-Sha256: 00' "$BASE/generic/tools/other.bin")" "400"
check "same bytes, second path" "$(status -X PUT --data-binary @"$WORK/blob.bin" "$BASE/generic/mirror/blob.bin")" "201"
check "deduplicated (one blob)" "$(find "$DATA/cas" -type f -size +1M | wc -l | tr -d ' ')" "1"
check "anonymous download (reader)" "$(OUT=/dev/null anon "$BASE/generic/mirror/blob.bin")" "200"
check "/api/v1/generic alias" "$(OUT="$WORK/alias.bin" anon "$BASE/api/v1/generic/mirror/blob.bin")" "200"
cmp -s "$WORK/blob.bin" "$WORK/alias.bin" && pass "alias bytes identical" || fail "alias bytes differ"
check "missing artifact" "$(status "$BASE/generic/nope/x.bin")" "404"
check "path traversal rejected" "$(status --path-as-is "$BASE/generic/a/../../etc/passwd")" "400"

echo "exodus repository"
put_manifest() { status -X PUT --data-binary @"$1" "$BASE/exodus/$2/$3/exodus.json"; }
for f in tests/fixtures/*.exodus.json; do
    base=$(basename "$f" .exodus.json); name=${base%-*}; version=${base##*-}
    check "manifest $name@$version" "$(put_manifest "$f" "$name" "$version")" "201"
done
check "manifest name mismatch rejected" "$(put_manifest tests/fixtures/core-1.0.0.exodus.json core 9.9.9)" "400"
check "package before manifest" "$(status -X PUT --data-binary 'x' "$BASE/exodus/ghost/1.0.0/package")" "409"
check "graph lists newest legacy" "$(curl -s "$BASE/api/graph" > "$WORK/g.json"; json "$WORK/g.json" "[p['version'] for p in j['projects'] if p['name']=='legacy'][0]")" "1.0.0"

printf 'zlib-lite build 1.0.0\0\1\2' > "$WORK/z100.bin"
check "package zlib-lite@1.0.0" "$(status -X PUT --data-binary @"$WORK/z100.bin" "$BASE/exodus/zlib-lite/1.0.0/package")" "201"

# New version with different bytes: every dependent must rebuild, in order.
sed 's/"version": "1.0.0"/"version": "1.1.0"/' tests/fixtures/zlib-lite-1.0.0.exodus.json > "$WORK/z110.json"
check "manifest zlib-lite@1.1.0" "$(put_manifest "$WORK/z110.json" zlib-lite 1.1.0)" "201"
printf 'zlib-lite build 1.1.0\0\3\4' > "$WORK/z110.bin"
check "package zlib-lite@1.1.0" "$(status -X PUT --data-binary @"$WORK/z110.bin" "$BASE/exodus/zlib-lite/1.1.0/package")" "201"
cp "$WORK/body" "$WORK/up110.json"
check "upload reports change" "$(json "$WORK/up110.json" "j['unchanged']")" "False"
check "rebuild waves" "$(json "$WORK/up110.json" "j['impact']['rebuild_waves']")" "[['core'], ['legacy', 'net'], ['app']]"
check "pinned consumer flagged" "$(json "$WORK/up110.json" "j['impact']['outdated_pins']")" "[{'project': 'tool', 'pins': '0.9.0'}]"

# Rebuild that produced identical bytes: nothing downstream to do.
sed 's/"version": "1.0.0"/"version": "1.1.1"/' tests/fixtures/zlib-lite-1.0.0.exodus.json > "$WORK/z111.json"
check "manifest zlib-lite@1.1.1" "$(put_manifest "$WORK/z111.json" zlib-lite 1.1.1)" "201"
check "package zlib-lite@1.1.1" "$(status -X PUT --data-binary @"$WORK/z110.bin" "$BASE/exodus/zlib-lite/1.1.1/package")" "201"
check "identical bytes -> unchanged" "$(json "$WORK/body" "j['unchanged']")" "True"
check "identical bytes -> no plan" "$(json "$WORK/body" "j['impact']")" "None"

check "package download" "$(curl -s -o "$WORK/zback.bin" -w '%{http_code}' "$BASE/exodus/zlib-lite/1.1.0/package")" "200"
cmp -s "$WORK/z110.bin" "$WORK/zback.bin" && pass "package bytes identical (with NULs)" || fail "package bytes differ"
check "manifest download" "$(status "$BASE/exodus/core/1.0.0/exodus.json")" "200"
check "manifest content" "$(json "$WORK/body" "j['name']")" "core"

echo "impact API"
curl -s "$BASE/api/impact?apt=libssl-dev&version=3.0.13-0ubuntu3.16" > "$WORK/apt.json"
check "apt bump waves" "$(json "$WORK/apt.json" "j['rebuild_waves']")" "[['core'], ['legacy', 'net'], ['app']]"
curl -s "$BASE/api/impact?apt=libssl-dev&version=3.0.13-0ubuntu3.7" > "$WORK/apt_same.json"
check "apt same version" "$(json "$WORK/apt_same.json" "(j['rebuild_count'], j['up_to_date'])")" "(0, ['core'])"
curl -s "$BASE/api/impact?project=net" > "$WORK/net.json"
check "impact of net" "$(json "$WORK/net.json" "j['rebuild_waves']")" "[['app']]"
check "impact needs a target" "$(status "$BASE/api/impact")" "400"
check "/api/v1/impact alias" "$(anon "$BASE/api/v1/impact?project=net" > /dev/null; json "$WORK/body" "j['rebuild_waves']")" "[['app']]"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || { echo "--- server log"; grep -v WARNING "$WORK/server.log" | tail -20; }
exit "$FAILS"
