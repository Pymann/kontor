#!/bin/bash
# End-to-end test: starts museum on a scratch data dir and drives it with curl.
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
status() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }

"$AIML_BIN" museum.aiml -- "$PORT" "$DATA" > "$WORK/server.log" 2>&1 &
SRV=$!
for _ in $(seq 100); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done
check "health" "$(status "$BASE/api/health")" "200"

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
check "deduplicated (one blob)" "$(find "$DATA/cas" -type f | wc -l | tr -d ' ')" "1"
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

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || { echo "--- server log"; grep -v WARNING "$WORK/server.log" | tail -20; }
exit "$FAILS"
