#!/bin/bash
# End-to-end test of the listing API (doc/spec/listing.md FL-40): generic
# files by prefix, glob, date and page; directory URLs; the 404 hint; exodus
# projects and versions.  Starts kontor on a scratch data dir, like e2e.sh.
#   AIML_BIN=/path/to/aiml tests/listing.sh        (or KONTOR_BIN=./kontor)
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
if [ -n "${KONTOR_BIN:-}" ]; then KONTOR_RUN=("$KONTOR_BIN"); else KONTOR_RUN=("$AIML_BIN" kontor.aiml --); fi
PORT="${PORT:-18096}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
DATA="$WORK/data"
FAILS=0
PASSES=0
SRV=""
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT

pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1" 2>/dev/null; }
ADMIN_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
status() { curl -s -o "${OUT:-$WORK/body}" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }
anon() { curl -s -o "${OUT:-$WORK/body}" -w '%{http_code}' "$@"; }
paths() { json "$WORK/body" "[i['path'] for i in j['items']]"; }

start() {
    KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "${KONTOR_RUN[@]}" "$PORT" "$DATA" "$@" > "$WORK/server.log" 2>&1 &
    SRV=$!
    for _ in $(seq $((${STARTUP_WAIT:-20} * 5))); do curl -s -o /dev/null "$BASE/api/health" && return; sleep 0.2; done
    fail "server did not start"; grep -v WARNING "$WORK/server.log" | tail -20; exit 1
}
stop() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }
# published_ms of a generic file, set by hand so the order is known.
stamp() { python3 - "$DATA/generic/$1/meta.json" "$2" <<'PY'
import json, sys
j = json.load(open(sys.argv[1])); j['published_ms'] = int(sys.argv[2]); json.dump(j, open(sys.argv[1], 'w'))
PY
}

start

echo "a tree of CI builds: run × commit"
for f in ci/1233-aaa111/aiml.tar.gz ci/1233-aaa111/aiml.tar.gz.sha256 \
         ci/1234-bbb222/aiml.tar.gz ci/1234-bbb222/logs/test.log \
         ci/1235-ccc333/aiml.tar.gz releases/v1.0/aiml.tar.gz; do
    check "upload $f" "$(status -X PUT --data-binary "content of $f" "$BASE/generic/aiml/$f")" "201"
done
stamp aiml/ci/1233-aaa111/aiml.tar.gz        1000
stamp aiml/ci/1233-aaa111/aiml.tar.gz.sha256 1000
stamp aiml/ci/1234-bbb222/aiml.tar.gz        3000
stamp aiml/ci/1234-bbb222/logs/test.log      2000
stamp aiml/ci/1235-ccc333/aiml.tar.gz        3000
stamp aiml/releases/v1.0/aiml.tar.gz         500

echo "FL-01/FL-02: one directory"
check "list a directory" "$(status "$BASE/api/v1/list/generic?prefix=aiml/ci/1233-aaa111")" "200"
check "shape" "$(json "$WORK/body" "(j['prefix'], j['total'], j['offset'], j['limit'], j['dirs'])")" "('aiml/ci/1233-aaa111', 2, 0, 1000, [])"
check "full paths, sorted" "$(paths)" "['aiml/ci/1233-aaa111/aiml.tar.gz', 'aiml/ci/1233-aaa111/aiml.tar.gz.sha256']"
check "item fields" "$(json "$WORK/body" "(lambda i: (i['bytes'], len(i['sha256']), i['published_ms'], i['publisher']))(j['items'][0])")" "(37, 64, 1000, 'admin')"
check "the path downloads" "$(OUT="$WORK/dl" status "$BASE/generic/aiml/ci/1233-aaa111/aiml.tar.gz" > /dev/null; cat "$WORK/dl")" "content of ci/1233-aaa111/aiml.tar.gz"
check "subdirectories in dirs" "$(status "$BASE/api/v1/list/generic?prefix=aiml/ci" > /dev/null; json "$WORK/body" "(j['dirs'], j['items'])")" "(['aiml/ci/1233-aaa111', 'aiml/ci/1234-bbb222', 'aiml/ci/1235-ccc333'], [])"
check "root" "$(status "$BASE/api/v1/list/generic" > /dev/null; json "$WORK/body" "(j['prefix'], j['dirs'])")" "('', ['aiml'])"
check "a file and a directory side by side" "$(status "$BASE/api/v1/list/generic?prefix=aiml/ci/1234-bbb222" > /dev/null; json "$WORK/body" "([i['path'] for i in j['items']], j['dirs'])")" "(['aiml/ci/1234-bbb222/aiml.tar.gz'], ['aiml/ci/1234-bbb222/logs'])"

echo "FL-02: recursive, match, sort, paging"
status "$BASE/api/v1/list/generic?prefix=aiml&recursive=1" > /dev/null
check "recursive" "$(json "$WORK/body" "(j['total'], j['dirs'])")" "(6, [])"
check "recursive order" "$(paths)" "['aiml/ci/1233-aaa111/aiml.tar.gz', 'aiml/ci/1233-aaa111/aiml.tar.gz.sha256', 'aiml/ci/1234-bbb222/aiml.tar.gz', 'aiml/ci/1234-bbb222/logs/test.log', 'aiml/ci/1235-ccc333/aiml.tar.gz', 'aiml/releases/v1.0/aiml.tar.gz']"
status "$BASE/api/v1/list/generic?prefix=aiml/ci&match=*/aiml.tar.gz" > /dev/null
check "match * stays in a segment" "$(paths)" "['aiml/ci/1233-aaa111/aiml.tar.gz', 'aiml/ci/1234-bbb222/aiml.tar.gz', 'aiml/ci/1235-ccc333/aiml.tar.gz']"
status "$BASE/api/v1/list/generic?prefix=aiml/ci&match=1234-*/**" > /dev/null
check "match ** spans segments (a run)" "$(paths)" "['aiml/ci/1234-bbb222/aiml.tar.gz', 'aiml/ci/1234-bbb222/logs/test.log']"
status "$BASE/api/v1/list/generic?prefix=aiml/ci&match=*-ccc333/**" > /dev/null
check "a commit" "$(paths)" "['aiml/ci/1235-ccc333/aiml.tar.gz']"
status "$BASE/api/v1/list/generic?prefix=aiml&match=**/*.sha256" > /dev/null
check "match ? and suffix" "$(paths)" "['aiml/ci/1233-aaa111/aiml.tar.gz.sha256']"
status "$BASE/api/v1/list/generic?prefix=aiml/ci&match=nothing-*/**" > /dev/null
check "no match is an empty list" "$(json "$WORK/body" "(j['total'], j['items'])")" "(0, [])"
status "$BASE/api/v1/list/generic?prefix=aiml&recursive=1&sort=published" > /dev/null
check "sort=published: newest first, ties by path" "$(paths)" "['aiml/ci/1234-bbb222/aiml.tar.gz', 'aiml/ci/1235-ccc333/aiml.tar.gz', 'aiml/ci/1234-bbb222/logs/test.log', 'aiml/ci/1233-aaa111/aiml.tar.gz', 'aiml/ci/1233-aaa111/aiml.tar.gz.sha256', 'aiml/releases/v1.0/aiml.tar.gz']"
status "$BASE/api/v1/list/generic?prefix=aiml&recursive=1&limit=2&offset=2" > /dev/null
check "paging" "$(json "$WORK/body" "([i['path'] for i in j['items']], j['total'], j['offset'], j['limit'])")" "(['aiml/ci/1234-bbb222/aiml.tar.gz', 'aiml/ci/1234-bbb222/logs/test.log'], 6, 2, 2)"
status "$BASE/api/v1/list/generic?prefix=aiml&recursive=1&offset=10" > /dev/null
check "offset past the end" "$(json "$WORK/body" "(j['items'], j['total'])")" "([], 6)"
check "limit capped" "$(status "$BASE/api/v1/list/generic?prefix=aiml&limit=99999" > /dev/null; json "$WORK/body" "j['limit']")" "10000"
check "prefix with .. -> 400" "$(status "$BASE/api/v1/list/generic?prefix=aiml/../etc")" "400"
check "match with .. -> 400" "$(status "$BASE/api/v1/list/generic?prefix=aiml&match=../*")" "400"
check "bad limit -> 400" "$(status "$BASE/api/v1/list/generic?limit=abc")" "400"
check "bad sort -> 400" "$(status "$BASE/api/v1/list/generic?sort=size")" "400"
check "missing prefix -> 404" "$(status "$BASE/api/v1/list/generic?prefix=aiml/nope")" "404"
check "404 code" "$(json "$WORK/body" "j['code']")" "not_found"
check "a file as prefix -> 404" "$(status "$BASE/api/v1/list/generic?prefix=aiml/ci/1235-ccc333/aiml.tar.gz")" "404"

echo "FL-03: the newest artifact of a run, in one call"
status "$BASE/api/v1/list/generic?prefix=aiml/ci&match=1234-*/**&sort=published&limit=1" > /dev/null
check "newest of run 1234" "$(paths)" "['aiml/ci/1234-bbb222/aiml.tar.gz']"

echo "FL-04: directory URLs"
check "trailing slash lists" "$(status "$BASE/generic/aiml/ci/")" "200"
check "same answer as FL-01" "$(json "$WORK/body" "(j['prefix'], j['dirs'])")" "('aiml/ci', ['aiml/ci/1233-aaa111', 'aiml/ci/1234-bbb222', 'aiml/ci/1235-ccc333'])"
check "parameters work there" "$(status "$BASE/generic/aiml/ci/?match=*/aiml.tar.gz&limit=1" > /dev/null; paths)" "['aiml/ci/1233-aaa111/aiml.tar.gz']"
check "api alias" "$(status "$BASE/api/v1/generic/aiml/ci/")" "200"
check "without the slash a directory is 404" "$(status "$BASE/generic/aiml/ci")" "404"
check "missing directory with slash -> 404" "$(status "$BASE/generic/aiml/nope/")" "404"

echo "FL-05: a 404 says where to look"
check "missing file -> 404" "$(status "$BASE/generic/aiml/ci/1234-bbb222/missing.bin")" "404"
check "hint: deepest existing directory" "$(json "$WORK/body" "(j['code'], j['list'])")" "('not_found', '/api/v1/list/generic?prefix=aiml/ci/1234-bbb222')"
check "hint for a guessed run" "$(status "$BASE/generic/aiml/ci/9999-zzz/aiml.tar.gz" > /dev/null; json "$WORK/body" "j['list']")" "/api/v1/list/generic?prefix=aiml/ci"
check "hint at the root" "$(status "$BASE/generic/other/x.bin" > /dev/null; json "$WORK/body" "j['list']")" "/api/v1/list/generic?prefix="

echo "FL-10/FL-11: exodus"
mk_manifest() { printf '{"$schema":"exodus.project.config-1.0","name":"%s","version":"%s","dependencies":[],"apt_packages":[]}' "$1" "$2" > "$WORK/m.json"; }
publish() {
    mk_manifest "$1" "$2"
    status -X PUT --data-binary @"$WORK/m.json" "$BASE/exodus/$1/$2/exodus.json" > /dev/null
    status -X PUT --data-binary "build of $1 $2" "$BASE/exodus/$1/$2/package"
}
for v in 1.0.0 1.2.0 1.10.0 2.0.0-rc1; do check "publish tool $v" "$(publish tool "$v")" "201"; done
check "publish lib 0.1.0" "$(publish lib 0.1.0)" "201"
check "delete tool 1.2.0" "$(status -X DELETE "$BASE/exodus/tool/1.2.0")" "204"
check "projects" "$(status "$BASE/api/v1/list/exodus")" "200"
check "sorted by name, newest, count" "$(json "$WORK/body" "[(i['name'], i['newest'], i['versions']) for i in j['items']]")" "[('lib', '0.1.0', 1), ('tool', '2.0.0-rc1', 4)]"
check "versions" "$(status "$BASE/api/v1/list/exodus/tool")" "200"
check "newest first in version order" "$(json "$WORK/body" "[i['version'] for i in j['items']]")" "['2.0.0-rc1', '1.10.0', '1.2.0', '1.0.0']"
check "tombstone marked" "$(json "$WORK/body" "[(i['version'], i['deleted'], i['sha256'], i['bytes']) for i in j['items'] if i['version'] == '1.2.0']")" "[('1.2.0', True, '', 0)]"
check "live version fields" "$(json "$WORK/body" "(lambda i: (i['deleted'], len(i['sha256']), i['bytes'], i['publisher'], i['published_ms'] > 0))(j['items'][1])")" "(False, 64, 20, 'admin', True)"
check "shape" "$(json "$WORK/body" "(j['name'], j['total'], j['offset'], j['limit'])")" "('tool', 4, 0, 1000)"
check "match" "$(status "$BASE/api/v1/list/exodus/tool?match=1.*" > /dev/null; json "$WORK/body" "[i['version'] for i in j['items']]")" "['1.10.0', '1.2.0', '1.0.0']"
check "paging" "$(status "$BASE/api/v1/list/exodus/tool?limit=1&offset=1" > /dev/null; json "$WORK/body" "([i['version'] for i in j['items']], j['total'])")" "(['1.10.0'], 4)"
check "unknown project -> 404" "$(status "$BASE/api/v1/list/exodus/nope")" "404"

echo "FL-30: rights follow downloads"
check "anonymous reader lists" "$(anon "$BASE/api/v1/list/generic?prefix=aiml")" "200"
check "anonymous reader lists exodus" "$(anon "$BASE/api/v1/list/exodus")" "200"
check "set anonymous none" "$(status -X PUT -d '{"anonymous":"none"}' "$BASE/api/v1/settings")" "200"
check "anonymous -> 401" "$(anon "$BASE/api/v1/list/generic?prefix=aiml")" "401"
check "anonymous directory URL -> 401" "$(anon "$BASE/generic/aiml/")" "401"
check "anonymous exodus -> 401" "$(anon "$BASE/api/v1/list/exodus/tool")" "401"
stop

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || { echo "--- server log"; grep -v WARNING "$WORK/server.log" | tail -30; }
exit "$FAILS"
