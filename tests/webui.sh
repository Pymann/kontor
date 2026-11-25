#!/bin/bash
# End-to-end test of the web UI backend (doc/spec/web_ui.md FW-101): static
# delivery, sessions, catalog, retention, settings.  Starts kontor on a
# scratch data dir and drives it with curl, like e2e.sh.
#   AIML_BIN=/path/to/aiml tests/webui.sh        (or KONTOR_BIN=./kontor)
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
if [ -n "${KONTOR_BIN:-}" ]; then KONTOR_RUN=("$KONTOR_BIN"); else KONTOR_RUN=("$AIML_BIN" kontor.aiml --); fi
PORT="${PORT:-18095}"
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
DATA="$WORK/data"
UI="$WORK/ui"
FAILS=0
PASSES=0
SRV=""
trap 'kill $SRV 2>/dev/null; rm -rf "$WORK"' EXIT

pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1"; }
header() { grep -i "^$1:" "$WORK/headers" | head -1 | cut -d' ' -f2- | tr -d '\r'; }
ADMIN_TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
status() { curl -s -o "${OUT:-$WORK/body}" -D "$WORK/headers" -w '%{http_code}' -H "Authorization: Bearer $ADMIN_TOKEN" "$@"; }
anon() { curl -s -o "${OUT:-$WORK/body}" -D "$WORK/headers" -w '%{http_code}' "$@"; }
bearer() { local tok="$1"; shift; curl -s -o "${OUT:-$WORK/body}" -D "$WORK/headers" -w '%{http_code}' -H "Authorization: Bearer $tok" "$@"; }

start() {
    KONTOR_ADMIN_TOKEN="$ADMIN_TOKEN" "${KONTOR_RUN[@]}" "$PORT" "$DATA" "$@" > "$WORK/server.log" 2>&1 &
    SRV=$!
    for _ in $(seq $((${STARTUP_WAIT:-20} * 5))); do curl -s -o /dev/null "$BASE/api/health" && return; sleep 0.2; done
    fail "server did not start"; grep -v WARNING "$WORK/server.log" | tail -20; exit 1
}
stop() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=""; }

# A stand-in for the built UI (ui/dist): the backend serves whatever is there.
mkdir -p "$UI/assets"
printf '<!doctype html><title>kontor</title><script src="kontor-ui.js"></script>\n' > "$UI/index.html"
printf 'console.log("kontor ui")\n' > "$UI/kontor-ui.js"
printf '\0asm\1\0\0\0' > "$UI/kontor-ui.wasm"
printf 'body{}\n' > "$UI/assets/app.css"
printf 'secret\n' > "$WORK/outside.txt"
ln -s "$WORK/outside.txt" "$UI/escape.txt"

echo "ui delivery without a UI directory (FW-11)"
KONTOR_UI_DIR="$WORK/none" start
check "/ui/ without UI -> 404" "$(anon "$BASE/ui/")" "404"
check "404 says what is missing" "$(json "$WORK/body" "(j['code'], '--ui-dir' in j['error'])")" "('not_found', True)"
check "API still works" "$(anon "$BASE/api/v1/health")" "200"
stop

echo "ui delivery (FW-10, FW-12…FW-15)"
start --ui-dir "$UI"
check "/ redirects" "$(anon "$BASE/")" "302"
check "/ -> /ui/" "$(header location)" "/ui/"
check "/ui redirects" "$(anon "$BASE/ui")" "302"
check "/ui -> /ui/" "$(header location)" "/ui/"
check "/ui/ is index.html" "$(anon "$BASE/ui/")" "200"
check "index content" "$(grep -c 'kontor-ui.js' "$WORK/body")" "1"
check "index content type" "$(header content-type | cut -d';' -f1)" "text/html"
check "index not cached" "$(header cache-control)" "no-cache"
check "csp" "$(header content-security-policy)" "default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'"
check "nosniff" "$(header x-content-type-options)" "nosniff"
check "no referrer" "$(header referrer-policy)" "no-referrer"
check "wasm" "$(OUT="$WORK/w.wasm" anon "$BASE/ui/kontor-ui.wasm")" "200"
check "wasm type" "$(header content-type)" "application/wasm"
cmp -s "$UI/kontor-ui.wasm" "$WORK/w.wasm" && pass "wasm bytes identical" || fail "wasm bytes differ"
ETAG="$(header etag)"
check "etag present" "$([ -n "$ETAG" ] && echo yes)" "yes"
# If-None-Match → 304 is the HTTP runtime's part (aiml, web_ui.md FW-94);
# checked here once the aiml in use does it.
if [ "${KONTOR_EXPECT_304:-0}" = 1 ]; then
    check "if-none-match -> 304" "$(anon -H "If-None-Match: $ETAG" "$BASE/ui/kontor-ui.wasm")" "304"
fi
check "nested file" "$(anon "$BASE/ui/assets/app.css")" "200"
check "css type" "$(header content-type | cut -d';' -f1)" "text/css"
check "ui ignores a bad credential" "$(anon -H 'Authorization: Bearer 00ff' "$BASE/ui/")" "200"
check "missing file" "$(anon "$BASE/ui/nope.js")" "404"
check "traversal" "$(anon --path-as-is "$BASE/ui/../../../etc/passwd")" "404"
check "encoded traversal" "$(anon --path-as-is "$BASE/ui/..%2f..%2f..%2fetc%2fpasswd")" "404"
check "symlink out of the UI dir" "$(anon "$BASE/ui/escape.txt")" "404"

echo "users for the rest"
check "create admin ops" "$(status -X POST -d '{"name":"ops","password":"ops-password-1","roles":["admin"]}' "$BASE/api/v1/users")" "201"
check "create reader rita" "$(status -X POST -d '{"name":"rita","password":"rita-password-1","roles":["reader"]}' "$BASE/api/v1/users")" "201"

echo "sessions (FW-20, FW-23)"
check "login rita" "$(anon -u rita:rita-password-1 -X POST "$BASE/api/v1/sessions")" "201"
check "session fields" "$(json "$WORK/body" "(j['owner'], j['roles'], len(j['token']), j['expires_ms'] > 0)")" "('rita', ['reader'], 64, True)"
RITA=$(json "$WORK/body" "j['token']"); RITA_ID=$(json "$WORK/body" "j['id']")
check "session expires in 12 h" "$(json "$WORK/body" "abs(j['expires_ms'] - __import__('time').time()*1000 - 12*3600*1000) < 120000")" "True"
check "whoami lists rights (FW-25)" "$(status "$BASE/api/v1/whoami" > /dev/null; json "$WORK/body" "j['rights']")" "['read', 'write', 'delete', 'admin', 'webhook_admin']"
check "anonymous reader rights" "$(anon "$BASE/api/v1/whoami" > /dev/null; json "$WORK/body" "j['rights']")" "['read']"
check "session works as bearer" "$(bearer "$RITA" "$BASE/api/v1/whoami" > /dev/null; json "$WORK/body" "(j['name'], j['kind'])")" "('rita', 'token')"
check "wrong password -> 401" "$(anon -u rita:wrong-password -X POST "$BASE/api/v1/sessions")" "401"
MSG_WRONG=$(json "$WORK/body" "j['error']")
check "unknown user -> 401" "$(anon -u nobody:wrong-password -X POST "$BASE/api/v1/sessions")" "401"
check "same message for unknown user" "$(json "$WORK/body" "j['error']")" "$MSG_WRONG"
check "no credentials -> 401" "$(anon -X POST "$BASE/api/v1/sessions")" "401"
check "bearer is not a login -> 400" "$(bearer "$ADMIN_TOKEN" -X POST "$BASE/api/v1/sessions")" "400"
check "token as basic password -> 400" "$(anon -u "admin:$ADMIN_TOKEN" -X POST "$BASE/api/v1/sessions")" "400"
check "session in token list" "$(bearer "$RITA" "$BASE/api/v1/tokens" > /dev/null; json "$WORK/body" "[t['id'] for t in j['tokens'] if t.get('expires_ms')]")" "['$RITA_ID']"
check "sign out" "$(bearer "$RITA" -X DELETE "$BASE/api/v1/tokens/$RITA_ID")" "204"
check "signed out -> 401" "$(bearer "$RITA" "$BASE/api/v1/whoami")" "401"
check "login ops" "$(anon -u ops:ops-password-1 -X POST "$BASE/api/v1/sessions")" "201"
OPS=$(json "$WORK/body" "j['token']")
check "login rita again" "$(anon -u rita:rita-password-1 -X POST "$BASE/api/v1/sessions")" "201"
RITA=$(json "$WORK/body" "j['token']")

echo "publishing with metadata (FW-34)"
put_manifest() { bearer "$OPS" -X PUT --data-binary @"$1" "$BASE/exodus/$2/$3/exodus.json"; }
mk_manifest() {  # name version [dep-name dep-version]
    if [ $# -gt 2 ]; then deps="[{\"name\":\"$3\",\"version\":\"$4\"}]"; else deps="[]"; fi
    printf '{"$schema":"exodus.project.config-1.0","name":"%s","version":"%s","dependencies":%s,"apt_packages":[]}' "$1" "$2" "$deps" > "$WORK/m.json"
}
publish() {  # name version [dep-name dep-version]
    mk_manifest "$@"
    put_manifest "$WORK/m.json" "$1" "$2" > /dev/null
    printf 'build of %s %s' "$1" "$2" > "$WORK/p.bin"
    bearer "$OPS" -X PUT --data-binary @"$WORK/p.bin" "$BASE/exodus/$1/$2/package"
}
for v in 1.0.0 1.1.0 1.2.0 1.3.0 1.10.0; do check "publish lib-a $v" "$(publish lib-a "$v")" "201"; done
check "publish app 1.0.0 (pins lib-a 1.1.0)" "$(publish app 1.0.0 lib-a 1.1.0)" "201"
check "meta written" "$(json "$DATA/exodus/lib-a/1.0.0/meta.json" "(j['publisher'], j['published_ms'] > 0)")" "('ops', True)"
check "generic upload" "$(bearer "$OPS" -X PUT --data-binary 'cache' "$BASE/generic/ci-cache/old.tar")" "201"
check "generic upload 2" "$(bearer "$OPS" -X PUT --data-binary 'cache2' "$BASE/generic/ci-cache/new.tar")" "201"
check "generic upload 3" "$(bearer "$OPS" -X PUT --data-binary 'release' "$BASE/generic/releases/r1.tar")" "201"
check "generic meta" "$(json "$DATA/generic/ci-cache/old.tar/meta.json" "j['publisher']")" "ops"
# Age the objects: rewrite published_ms (FW-43 measures age from it).
age() { python3 - "$1" "$2" <<'PY'
import json, sys, time
path, days = sys.argv[1], float(sys.argv[2])
j = json.load(open(path)); j['published_ms'] = int((time.time() - days * 86400) * 1000)
json.dump(j, open(path, 'w'))
PY
}
age "$DATA/exodus/lib-a/1.0.0/meta.json" 400
age "$DATA/exodus/lib-a/1.1.0/meta.json" 300
age "$DATA/exodus/lib-a/1.2.0/meta.json" 200
age "$DATA/exodus/lib-a/1.3.0/meta.json" 2
age "$DATA/generic/ci-cache/old.tar/meta.json" 30
age "$DATA/generic/releases/r1.tar/meta.json" 900

echo "catalog (FW-30…FW-33)"
check "catalog as reader" "$(bearer "$RITA" "$BASE/api/v1/catalog")" "200"
check "catalog projects" "$(json "$WORK/body" "sorted(p['name'] for p in j['exodus'])")" "['app', 'lib-a']"
check "catalog newest by version order" "$(json "$WORK/body" "[(p['newest'], p['versions']) for p in j['exodus'] if p['name']=='lib-a'][0]")" "('1.10.0', 5)"
check "catalog generic" "$(json "$WORK/body" "j['generic']['files']")" "3"
check "catalog kontor block" "$(json "$WORK/body" "(j['kontor']['blob_count'] > 0, j['kontor']['disk_bytes'] > 0, 'public_url' in j['kontor'])")" "(True, True, True)"
check "project versions" "$(bearer "$RITA" "$BASE/api/v1/catalog/exodus/lib-a")" "200"
check "versions newest first" "$(json "$WORK/body" "[v['version'] for v in j['versions']]")" "['1.10.0', '1.3.0', '1.2.0', '1.1.0', '1.0.0']"
check "version fields" "$(json "$WORK/body" "[(v['publisher'], len(v['sha256']), v['bytes'] > 0, v['protected']) for v in j['versions']][0]")" "('ops', 64, True, False)"
check "dependents" "$(json "$WORK/body" "j['dependents']")" "['app']"
check "install command" "$(json "$WORK/body" "j['install'].startswith('aiml venv <dir> install lib-a --kontor ')")" "True"
check "unknown project" "$(bearer "$RITA" "$BASE/api/v1/catalog/exodus/nope")" "404"
check "generic listing" "$(bearer "$RITA" "$BASE/api/v1/catalog/generic?prefix=ci-cache")" "200"
check "generic files" "$(json "$WORK/body" "sorted(f['name'] for f in j['files'])")" "['new.tar', 'old.tar']"
check "generic root dirs" "$(bearer "$RITA" "$BASE/api/v1/catalog/generic" > /dev/null; json "$WORK/body" "sorted(j['dirs'])")" "['ci-cache', 'releases']"

echo "rights (FW-25, FW-05)"
for ep in "GET /api/v1/retention" "PUT /api/v1/retention" "POST /api/v1/retention/preview" "POST /api/v1/retention/run" "GET /api/v1/retention/runs" "GET /api/v1/settings" "PUT /api/v1/settings" "GET /api/v1/protected" "PUT /api/v1/protected?repo=exodus&name=lib-a&version=1.0.0"; do
    set -- $ep
    check "reader $1 ${2%%\?*} -> 403" "$(bearer "$RITA" -X "$1" -d '{}' "$BASE$2")" "403"
done
check "anonymous catalog with anonymous reader" "$(anon "$BASE/api/v1/catalog")" "200"

echo "retention policy (FW-40, FW-41)"
check "no policy yet" "$(bearer "$OPS" "$BASE/api/v1/retention")" "200"
check "empty rules" "$(json "$WORK/body" "j['rules']")" "[]"
check "invalid policy -> 400" "$(bearer "$OPS" -X PUT --data-binary $'rules:\n  - repo: exodus\n    match: "*"\n' "$BASE/api/v1/retention")" "400"
check "error has the path" "$(json "$WORK/body" "'rules[0]' in j['error']")" "True"
check "nothing written" "$(test -e "$DATA/config/retention.yaml" && echo yes || echo no)" "no"
POLICY=$'schedule: ""\nrules:\n  - repo: exodus\n    match: "lib-*"\n    keep_last: 1\n    max_age_days: 100\n  - repo: generic\n    match: "ci-cache/**"\n    max_age_days: 14\n'
check "store policy" "$(bearer "$OPS" -X PUT --data-binary "$POLICY" "$BASE/api/v1/retention")" "200"
check "policy read back" "$(bearer "$OPS" "$BASE/api/v1/retention" > /dev/null; json "$WORK/body" "[(r['repo'], r['match'], r.get('keep_last'), r.get('max_age_days')) for r in j['rules']]")" "[('exodus', 'lib-*', 1, 100), ('generic', 'ci-cache/**', None, 14)]"

echo "protection (FW-42.3)"
check "protect lib-a 1.0.0" "$(bearer "$OPS" -X PUT "$BASE/api/v1/protected?repo=exodus&name=lib-a&version=1.0.0")" "204"
check "listed" "$(bearer "$OPS" "$BASE/api/v1/protected" > /dev/null; json "$WORK/body" "j['protected']")" "[{'repo': 'exodus', 'name': 'lib-a', 'version': '1.0.0'}]"
check "catalog shows protected" "$(bearer "$RITA" "$BASE/api/v1/catalog/exodus/lib-a" > /dev/null; json "$WORK/body" "[v['version'] for v in j['versions'] if v['protected']]")" "['1.0.0']"

echo "preview (FW-44)"
check "preview" "$(bearer "$OPS" -X POST "$BASE/api/v1/retention/preview")" "200"
check "would delete" "$(json "$WORK/body" "sorted((d['repo'], d['name'], d['version']) for d in j['delete'])")" "[('exodus', 'lib-a', '1.2.0'), ('generic', 'ci-cache/old.tar', '')]"
check "kept reasons" "$(json "$WORK/body" "sorted((k['name'], k['version'], k['reason']) for k in j['kept'] if k['name']=='lib-a')")" "[('lib-a', '1.0.0', 'protected'), ('lib-a', '1.1.0', 'dependency'), ('lib-a', '1.10.0', 'newest'), ('lib-a', '1.3.0', 'max_age')]"
check "preview changes nothing" "$(test -e "$DATA/exodus/lib-a/1.2.0/package.sha256" && echo kept || echo gone)" "kept"
check "preview of an unsaved policy" "$(bearer "$OPS" -X POST --data-binary $'rules:\n  - repo: generic\n    match: "**"\n    max_age_days: 1\n' "$BASE/api/v1/retention/preview" > /dev/null; json "$WORK/body" "sorted(d['name'] for d in j['delete'])")" "['ci-cache/old.tar', 'releases/r1.tar']"
check "invalid preview policy -> 400" "$(bearer "$OPS" -X POST --data-binary $'rules:\n  - repo: nope\n' "$BASE/api/v1/retention/preview")" "400"

echo "run (FW-45…FW-49)"
check "webhook for events" "$(bearer "$OPS" -X POST -d '{"url":"http://127.0.0.1:9/hook","secret":"0123456789abcdef","events":["artifact.deleted"]}' "$BASE/api/v1/webhooks")" "201"
HOOK=$(json "$WORK/body" "j['id']")
check "run" "$(bearer "$OPS" -X POST "$BASE/api/v1/retention/run")" "202"
RUN=$(json "$WORK/body" "j['run']")
for _ in $(seq 50); do
    bearer "$OPS" "$BASE/api/v1/retention/runs" > /dev/null
    [ "$(json "$WORK/body" "[r for r in j['runs'] if r['run']=='$RUN' and r.get('finished_ms')] != []")" = "True" ] && break
    sleep 0.2
done
check "run logged" "$(json "$WORK/body" "[(r['trigger'], r['by'], r['deleted'], r['errors']) for r in j['runs'] if r['run']=='$RUN']")" "[('manual', 'ops', 2, [])]"
check "bytes freed" "$(json "$WORK/body" "[r['bytes_freed'] > 0 for r in j['runs'] if r['run']=='$RUN']")" "[True]"
check "tombstone" "$(json "$DATA/exodus/lib-a/1.2.0/tombstone.json" "(j['by'], j['reason'])")" "('ops', 'retention')"
check "deleted package -> 410" "$(anon "$BASE/exodus/lib-a/1.2.0/package")" "410"
check "410 code" "$(json "$WORK/body" "j['code']")" "gone"
check "deleted manifest -> 410" "$(anon "$BASE/exodus/lib-a/1.2.0/exodus.json")" "410"
mk_manifest lib-a 1.2.0
check "writer wendy" "$(bearer "$OPS" -X POST -d '{"name":"wendy","password":"wendy-password-1","roles":["writer"]}' "$BASE/api/v1/users")" "201"
check "a writer does not reuse the version" "$(anon -u wendy:wendy-password-1 -X PUT --data-binary @"$WORK/m.json" "$BASE/exodus/lib-a/1.2.0/exodus.json")" "409"
check "an admin may write it again" "$(publish lib-a 1.2.0)" "201"
check "tombstone gone" "$(test -e "$DATA/exodus/lib-a/1.2.0/tombstone.json" && echo yes || echo no)" "no"
check "readable again" "$(anon -o /dev/null "$BASE/exodus/lib-a/1.2.0/package")" "200"
check "admin overwrites a published package" "$(printf 'rebuilt' > "$WORK/p2.bin"; bearer "$OPS" -X PUT --data-binary @"$WORK/p2.bin" "$BASE/exodus/lib-a/1.2.0/package")" "201"
check "overwritten bytes served" "$(curl -s "$BASE/exodus/lib-a/1.2.0/package")" "rebuilt"
check "writer cannot overwrite" "$(anon -u wendy:wendy-password-1 -X PUT --data-binary 'x' "$BASE/exodus/lib-a/1.2.0/package")" "409"
check "kept versions remain" "$(anon -o /dev/null "$BASE/exodus/lib-a/1.1.0/package")" "200"
check "generic deleted" "$(anon "$BASE/generic/ci-cache/old.tar")" "404"
check "generic may be written again" "$(bearer "$OPS" -X PUT --data-binary 'cache' "$BASE/generic/ci-cache/old.tar")" "201"
check "catalog after run" "$(bearer "$RITA" "$BASE/api/v1/catalog/exodus/lib-a" > /dev/null; json "$WORK/body" "[v['version'] for v in j['versions']]")" "['1.10.0', '1.3.0', '1.2.0', '1.1.0', '1.0.0']"
check "deletion events" "$(bearer "$OPS" "$BASE/api/v1/webhooks/$HOOK/deliveries" > /dev/null; json "$WORK/body" "len([d for d in j['deliveries'] if d['event']=='artifact.deleted'])")" "2"
check "young unreferenced blob kept (24 h grace)" "$(find "$DATA/cas" -type f | xargs grep -l 'build of lib-a 1.2.0' 2>/dev/null | wc -l | tr -d ' ')" "1"

echo "manual delete (FW-50)"
check "reader cannot delete" "$(bearer "$RITA" -X DELETE "$BASE/exodus/lib-a/1.3.0")" "403"
check "protected -> 409" "$(bearer "$OPS" -X DELETE "$BASE/exodus/lib-a/1.0.0")" "409"
check "409 names the reason" "$(json "$WORK/body" "'protected' in j['error']")" "True"
check "dependency -> 409" "$(bearer "$OPS" -X DELETE "$BASE/exodus/lib-a/1.1.0")" "409"
check "newest -> 409" "$(bearer "$OPS" -X DELETE "$BASE/exodus/lib-a/1.10.0")" "409"
check "delete 1.3.0" "$(bearer "$OPS" -X DELETE "$BASE/exodus/lib-a/1.3.0")" "204"
check "manual tombstone" "$(json "$DATA/exodus/lib-a/1.3.0/tombstone.json" "j['reason']")" "manual"
check "unprotect" "$(bearer "$OPS" -X DELETE "$BASE/api/v1/protected?repo=exodus&name=lib-a&version=1.0.0")" "204"
check "delete 1.0.0 now" "$(bearer "$OPS" -X DELETE "$BASE/exodus/lib-a/1.0.0")" "204"

echo "session sweep (FW-26)"
python3 - "$DATA/auth/tokens" <<'PY'
import json, os, sys
d = sys.argv[1]
for f in os.listdir(d):
    p = os.path.join(d, f); j = json.load(open(p))
    if j.get('owner') == 'ops' and j.get('expires_ms'):
        j['expires_ms'] = 1; json.dump(j, open(p, 'w'))
PY
check "expired session -> 401" "$(bearer "$OPS" "$BASE/api/v1/whoami")" "401"
check "run as bootstrap admin" "$(status -X POST "$BASE/api/v1/retention/run")" "202"
for _ in $(seq 50); do
    [ "$(grep -l '"owner":"ops"' "$DATA"/auth/tokens/* 2>/dev/null | wc -l | tr -d ' ')" = "0" ] && break; sleep 0.2
done
check "expired session file swept" "$(grep -l '"owner":"ops"' "$DATA"/auth/tokens/* 2>/dev/null | wc -l | tr -d ' ')" "0"
check "live session kept" "$(bearer "$RITA" "$BASE/api/v1/whoami")" "200"

echo "settings (FW-60…FW-62)"
check "settings" "$(status "$BASE/api/v1/settings")" "200"
check "defaults and sources" "$(json "$WORK/body" "(j['anonymous'], j['session_hours'], j['source']['anonymous'])")" "('reader', 12, 'default')"
check "set anonymous none" "$(status -X PUT -d '{"anonymous":"none","session_hours":2}' "$BASE/api/v1/settings")" "200"
check "source is settings" "$(status "$BASE/api/v1/settings" > /dev/null; json "$WORK/body" "(j['anonymous'], j['source']['anonymous'])")" "('none', 'settings')"
check "effective without restart" "$(anon "$BASE/api/v1/catalog")" "401"
check "ui files still public" "$(anon "$BASE/ui/")" "200"
check "session_hours applies" "$(anon -u rita:rita-password-1 -X POST "$BASE/api/v1/sessions" > /dev/null; json "$WORK/body" "abs(j['expires_ms'] - __import__('time').time()*1000 - 2*3600*1000) < 120000")" "True"
check "custom role" "$(status -X PUT -d '{"roles":{"ci":["read","write"]}}' "$BASE/api/v1/settings")" "200"
check "built-in role not redefined" "$(status -X PUT -d '{"roles":{"admin":["read"]}}' "$BASE/api/v1/settings")" "400"
check "unknown action" "$(status -X PUT -d '{"roles":{"x":["fly"]}}' "$BASE/api/v1/settings")" "400"
check "user with custom role" "$(status -X POST -d '{"name":"carl","password":"carl-password-1","roles":["ci"]}' "$BASE/api/v1/users")" "201"
check "role in use cannot go" "$(status -X PUT -d '{"roles":{}}' "$BASE/api/v1/settings")" "409"
check "409 names the user" "$(json "$WORK/body" "'carl' in j['error']")" "True"
check "last admin cannot be deleted" "$(status -X DELETE "$BASE/api/v1/users/ops")" "409"
check "last admin keeps admin" "$(status -X POST -d '{"name":"ops","password":"ops-password-1","roles":["reader"]}' "$BASE/api/v1/users")" "409"
check "second admin" "$(status -X POST -d '{"name":"ada","password":"ada-password-1","roles":["admin"]}' "$BASE/api/v1/users")" "201"
check "now ops can go" "$(status -X DELETE "$BASE/api/v1/users/ops")" "204"
stop; start --ui-dir "$UI"
check "settings survive a restart" "$(status "$BASE/api/v1/settings" > /dev/null; json "$WORK/body" "(j['anonymous'], j['roles'].get('ci'))")" "('none', ['read', 'write'])"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || { echo "--- server log"; grep -v WARNING "$WORK/server.log" | tail -30; }
exit "$FAILS"
