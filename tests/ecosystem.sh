#!/bin/bash
# End-to-end test of kontor's ecosystem half (doc/ecosystem.md): the OCI
# registry under /v2/ (curl + skopeo), cosmos stage layers (§3) and webhooks
# (§4) with signature-verifying receivers.
#   AIML_BIN=/path/to/aiml tests/ecosystem.sh
# skopeo is optional (its checks are skipped when it is missing).
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
# The built binary when KONTOR_BIN is set (aiml.tool.json, aiml spec/68 §6);
# the compiler reading the source otherwise.
if [ -n "${KONTOR_BIN:-}" ]; then KONTOR_RUN=("$KONTOR_BIN"); else KONTOR_RUN=("$AIML_BIN" kontor.aiml --); fi
PORT="${PORT:-18092}"
HOOK_A=$((PORT + 1)); HOOK_B=$((PORT + 2))
BASE="http://127.0.0.1:$PORT"
REG="127.0.0.1:$PORT"
WORK="$(mktemp -d)"
DATA="$WORK/data"
FAILS=0
PASSES=0
PIDS=""
trap 'kill $PIDS 2>/dev/null; if [ -n "${KEEP:-}" ]; then echo "kept $WORK"; else rm -rf "$WORK"; fi' EXIT

pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
json() { python3 -c "import json,sys; j=json.load(open(sys.argv[1])); print($2)" "$1"; }
TOKEN=$(head -c 32 /dev/urandom | sha256sum | cut -d' ' -f1)
AUTH=(-H "Authorization: Bearer $TOKEN")
status() { curl -s -o "${OUT:-$WORK/body}" -D "$WORK/headers" -w '%{http_code}' "${AUTH[@]}" "$@"; }
anon() { curl -s -o "${OUT:-$WORK/body}" -D "$WORK/headers" -w '%{http_code}' "$@"; }
hdr() { grep -i "^$1:" "$WORK/headers" | head -1 | cut -d' ' -f2- | tr -d '\r'; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
# wait_for <seconds> <shell condition>
wait_for() { for _ in $(seq $(($1 * 5))); do eval "$2" && return 0; sleep 0.2; done; return 1; }
# receiver log query: hooklog <log> <python expression over list r>
hooklog() { python3 -c "import json,sys; r=[json.loads(l) for l in open(sys.argv[1])]; print($2)" "$1" 2>/dev/null; }

SECRET_A="secret-for-receiver-a"; SECRET_B="secret-for-receiver-b"
touch "$WORK/a.jsonl" "$WORK/b.jsonl"
python3 tests/webhook_receiver.py "$HOOK_A" "$SECRET_A" "$WORK/a.jsonl" 0 & PIDS="$PIDS $!"
python3 tests/webhook_receiver.py "$HOOK_B" "$SECRET_B" "$WORK/b.jsonl" 2 & PIDS="$PIDS $!"
KONTOR_ADMIN_TOKEN="$TOKEN" "${KONTOR_RUN[@]}" "$PORT" "$DATA" > "$WORK/server.log" 2>&1 & PIDS="$PIDS $!"
wait_for "${STARTUP_WAIT:-20}" 'curl -s -o /dev/null "$BASE/api/health"'

echo "webhooks: subscribe"
check "subscribe A (all events)" "$(status -X POST -d "{\"url\":\"http://127.0.0.1:$HOOK_A/hook\",\"secret\":\"$SECRET_A\",\"events\":[\"*\"]}" "$BASE/api/v1/webhooks")" "201"
SUB_A=$(json "$WORK/body" "j['id']")
check "subscribe B (package.published)" "$(status -X POST -d "{\"url\":\"http://127.0.0.1:$HOOK_B/hook\",\"secret\":\"$SECRET_B\",\"events\":[\"package.published\"]}" "$BASE/api/v1/webhooks")" "201"
SUB_B=$(json "$WORK/body" "j['id']")
check "short secret rejected" "$(status -X POST -d '{"url":"http://127.0.0.1:1/","secret":"short"}' "$BASE/api/v1/webhooks")" "400"
check "anonymous cannot subscribe" "$(anon -X POST -d '{}' "$BASE/api/v1/webhooks")" "401"
check "list webhooks" "$(status "$BASE/api/v1/webhooks" > /dev/null; json "$WORK/body" "sorted(s['id'] for s in j['webhooks'])")" "$(python3 -c "print(sorted(['$SUB_A','$SUB_B']))")"
check "list has no secrets" "$(grep -c "$SECRET_A" "$WORK/body")" "0"
wait_for 10 '[ "$(hooklog "$WORK/a.jsonl" "len(r)")" -ge 1 ]'
check "ping delivered to A" "$(hooklog "$WORK/a.jsonl" "(r[0]['event'], r[0]['body']['event'], r[0]['body']['data'])")" "('ping', 'ping', {})"
check "ping signature valid" "$(hooklog "$WORK/a.jsonl" "r[0]['signature_ok']")" "True"
check "ping envelope" "$(hooklog "$WORK/a.jsonl" "sorted(r[0]['body'].keys())")" "['data', 'delivery', 'event', 'kontor', 'timestamp_ms']"
check "content type" "$(hooklog "$WORK/a.jsonl" "r[0]['content_type']")" "application/json"
check "test endpoint" "$(status -X POST "$BASE/api/v1/webhooks/$SUB_A/test")" "202"
wait_for 10 '[ "$(hooklog "$WORK/a.jsonl" "len(r)")" -ge 2 ]'
check "test ping delivered" "$(hooklog "$WORK/a.jsonl" "r[1]['event']")" "ping"

echo "registry: protocol (curl)"
check "GET /v2/ without credentials -> 401" "$(anon "$BASE/v2/")" "401"
check "Basic challenge" "$(hdr www-authenticate)" 'Basic realm="kontor"'
check "api version header" "$(hdr docker-distribution-api-version)" "registry/2.0"
check "GET /v2/ with token" "$(status "$BASE/v2/")" "200"
check "GET /v2/ with basic admin:token" "$(anon -u "admin:$TOKEN" "$BASE/v2/")" "200"
printf 'layer one bytes\n' > "$WORK/b1"; D1="sha256:$(sha "$WORK/b1")"
check "monolithic upload" "$(status -X POST --data-binary @"$WORK/b1" -H 'Content-Type: application/octet-stream' "$BASE/v2/demo/raw/blobs/uploads/?digest=$D1")" "201"
check "location" "$(hdr location)" "/v2/demo/raw/blobs/$D1"
check "anonymous push -> 401" "$(anon -X POST "$BASE/v2/demo/raw/blobs/uploads/")" "401"
check "HEAD blob" "$(status -I "$BASE/v2/demo/raw/blobs/$D1")" "200"
check "HEAD digest header" "$(hdr docker-content-digest)" "$D1"
check "HEAD length" "$(hdr content-length)" "16"
check "GET blob range" "$(status -H 'Range: bytes=6-8' "$BASE/v2/demo/raw/blobs/$D1"; cat "$WORK/body")" "206one"
check "unknown blob" "$(status "$BASE/v2/demo/raw/blobs/sha256:$(printf '0%.0s' $(seq 64))")" "404"
check "BLOB_UNKNOWN code" "$(json "$WORK/body" "j['errors'][0]['code']")" "BLOB_UNKNOWN"
check "invalid name" "$(status "$BASE/v2/Bad_Name/tags/list")" "404"
check "NAME_INVALID" "$(json "$WORK/body" "j['errors'][0]['code']")" "NAME_INVALID"

head -c 300000 /dev/urandom > "$WORK/b2"; D2="sha256:$(sha "$WORK/b2")"
head -c 100000 "$WORK/b2" > "$WORK/c1"; tail -c 200000 "$WORK/b2" > "$WORK/c2"
check "start session" "$(status -X POST "$BASE/v2/demo/raw/blobs/uploads/")" "202"
LOC=$(hdr location); UUID=$(hdr docker-upload-uuid)
check "session uuid in location" "$(echo "$LOC" | grep -c "$UUID")" "1"
check "PATCH chunk 1" "$(status -X PATCH --data-binary @"$WORK/c1" -H 'Content-Type: application/octet-stream' -H 'Content-Range: 0-99999' "$BASE$LOC")" "202"
check "range after chunk 1" "$(hdr range)" "0-99999"
check "out-of-order chunk -> 416" "$(status -X PATCH --data-binary @"$WORK/c2" -H 'Content-Range: 5-200004' "$BASE$LOC")" "416"
check "PATCH chunk 2 (chunked TE)" "$(status -X PATCH -H 'Transfer-Encoding: chunked' --data-binary @"$WORK/c2" -H 'Content-Range: 100000-299999' "$BASE$LOC")" "202"
check "upload status" "$(status "$BASE$LOC")" "204"
check "status range" "$(hdr range)" "0-299999"
check "PUT wrong digest -> 400" "$(status -X PUT "$BASE$LOC?digest=sha256:$(printf 'a%.0s' $(seq 64))")" "400"
check "DIGEST_INVALID" "$(json "$WORK/body" "j['errors'][0]['code']")" "DIGEST_INVALID"
check "new session" "$(status -X POST "$BASE/v2/demo/raw/blobs/uploads/")" "202"
LOC=$(hdr location)
check "PATCH whole" "$(status -X PATCH --data-binary @"$WORK/c1" "$BASE$LOC")" "202"
check "PUT final chunk + digest" "$(status -X PUT --data-binary @"$WORK/c2" "$BASE$LOC?digest=$D2")" "201"
check "chunked blob roundtrip" "$(OUT="$WORK/b2back" status "$BASE/v2/demo/raw/blobs/$D2" > /dev/null; sha "$WORK/b2back")" "${D2#sha256:}"
check "cross-repo mount" "$(status -X POST "$BASE/v2/other/repo/blobs/uploads/?mount=$D2&from=demo/raw")" "201"
check "cancel upload" "$(status -X POST "$BASE/v2/demo/raw/blobs/uploads/" > /dev/null; L=$(hdr location); status -X DELETE "$BASE$L")" "204"

printf '{}' > "$WORK/cfg"; DC="sha256:$(sha "$WORK/cfg")"
status -X POST --data-binary @"$WORK/cfg" "$BASE/v2/demo/raw/blobs/uploads/?digest=$DC" > /dev/null
python3 - "$WORK/m.json" "$DC" "$D1" "$WORK/missing.json" <<'EOF'
import json, sys
m = {"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json",
     "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": sys.argv[2], "size": 2},
     "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": sys.argv[3], "size": 16}]}
open(sys.argv[1], "w").write(json.dumps(m))
m["layers"][0]["digest"] = "sha256:" + "b" * 64
open(sys.argv[4], "w").write(json.dumps(m))
EOF
MT="application/vnd.oci.image.manifest.v1+json"
check "manifest with missing blob -> 400" "$(status -X PUT -H "Content-Type: $MT" --data-binary @"$WORK/missing.json" "$BASE/v2/demo/raw/manifests/v1")" "400"
check "MANIFEST_BLOB_UNKNOWN" "$(json "$WORK/body" "j['errors'][0]['code']")" "MANIFEST_BLOB_UNKNOWN"
DM="sha256:$(sha "$WORK/m.json")"
check "PUT manifest by tag" "$(status -X PUT -H "Content-Type: $MT" --data-binary @"$WORK/m.json" "$BASE/v2/demo/raw/manifests/v1")" "201"
check "manifest digest header" "$(hdr docker-content-digest)" "$DM"
check "GET manifest by tag: raw bytes" "$(OUT="$WORK/mback" status "$BASE/v2/demo/raw/manifests/v1" > /dev/null; sha "$WORK/mback")" "${DM#sha256:}"
check "manifest content type" "$(hdr content-type)" "$MT"
check "HEAD manifest by digest" "$(status -I "$BASE/v2/demo/raw/manifests/$DM")" "200"
check "HEAD digest" "$(hdr docker-content-digest)" "$DM"
check "second tag" "$(status -X PUT -H "Content-Type: $MT" --data-binary @"$WORK/m.json" "$BASE/v2/demo/raw/manifests/latest")" "201"
check "tags/list" "$(status "$BASE/v2/demo/raw/tags/list" > /dev/null; json "$WORK/body" "(j['name'], j['tags'])")" "('demo/raw', ['latest', 'v1'])"
check "tags/list paginated" "$(status "$BASE/v2/demo/raw/tags/list?n=1" > /dev/null; json "$WORK/body" "j['tags']")" "['latest']"
check "Link header" "$(hdr link | grep -c 'last=latest')" "1"
check "anonymous pull (reader)" "$(OUT=/dev/null anon "$BASE/v2/demo/raw/manifests/v1")" "200"
check "anonymous delete -> 401" "$(anon -X DELETE "$BASE/v2/demo/raw/manifests/latest")" "401"
check "delete tag" "$(status -X DELETE "$BASE/v2/demo/raw/manifests/latest")" "202"
check "deleted tag gone" "$(status "$BASE/v2/demo/raw/manifests/latest")" "404"
check "MANIFEST_UNKNOWN" "$(json "$WORK/body" "j['errors'][0]['code']")" "MANIFEST_UNKNOWN"
check "v1 survives" "$(OUT=/dev/null status "$BASE/v2/demo/raw/manifests/v1")" "200"

echo "registry: skopeo"
if command -v skopeo > /dev/null; then
    python3 tests/fixtures/oci/make_layout.py image "$WORK/layout" > "$WORK/img.digest"
    SK=(--src-tls-verify=false --dest-tls-verify=false)
    check "skopeo push without creds fails" "$(skopeo copy "${SK[@]}" "oci:$WORK/layout:1.0" "docker://$REG/demo/hello:1.0" > /dev/null 2>&1; echo $?)" "1"
    check "skopeo copy oci -> kontor" "$(skopeo copy "${SK[@]}" --dest-creds "admin:$TOKEN" "oci:$WORK/layout:1.0" "docker://$REG/demo/hello:1.0" > "$WORK/sk.log" 2>&1; echo $?)" "0"
    [ "$FAILS" -eq 0 ] || tail -5 "$WORK/sk.log"
    skopeo inspect --tls-verify=false "docker://$REG/demo/hello:1.0" > "$WORK/inspect.json" 2>&1
    check "skopeo inspect (anonymous)" "$(json "$WORK/inspect.json" "(j['Digest'], len(j['Layers']), j['Os'])")" "($(python3 -c "print(repr('$(cat "$WORK/img.digest")'))"), 1, 'linux')"
    check "skopeo inspect --raw" "$(skopeo inspect --tls-verify=false --creds "admin:$TOKEN" --raw "docker://$REG/demo/hello:1.0" | sha256sum | cut -d' ' -f1)" "$(cut -d: -f2 "$WORK/img.digest")"
    check "skopeo copy kontor -> oci" "$(skopeo copy "${SK[@]}" --src-creds "admin:$TOKEN" "docker://$REG/demo/hello:1.0" "oci:$WORK/back:1.0" > "$WORK/sk2.log" 2>&1; echo $?)" "0"
    check "roundtrip blobs identical" "$(cd "$WORK/layout/blobs/sha256" && ls | sort | tr '\n' ' ')" "$(cd "$WORK/back/blobs/sha256" && ls | sort | tr '\n' ' ')"
    check "skopeo list-tags" "$(skopeo list-tags --tls-verify=false "docker://$REG/demo/hello" | python3 -c 'import json,sys; print(json.load(sys.stdin)["Tags"])')" "['1.0']"
    check "skopeo copy registry -> registry tag" "$(skopeo copy "${SK[@]}" --src-creds "admin:$TOKEN" --dest-creds "admin:$TOKEN" "docker://$REG/demo/hello:1.0" "docker://$REG/demo/hello:stable" > /dev/null 2>&1; echo $?)" "0"
    check "skopeo delete" "$(skopeo delete --tls-verify=false --creds "admin:$TOKEN" "docker://$REG/demo/hello:stable" > /dev/null 2>&1; echo $?)" "0"
else
    echo "  skip skopeo not installed"
fi
check "_catalog" "$(status "$BASE/v2/_catalog" > /dev/null; json "$WORK/body" "[r for r in j['repositories'] if r.startswith('demo/')]")" "$(command -v skopeo > /dev/null && echo "['demo/hello', 'demo/raw']" || echo "['demo/raw']")"

echo "stage layers (contract §3)"
python3 tests/fixtures/oci/make_layout.py run-layers "$WORK/rl" > "$WORK/rl.digest"
RLD=$(cat "$WORK/rl.digest")
python3 - "$WORK/rl" > "$WORK/rl.list" <<'EOF'
import json, sys
idx = json.load(open(sys.argv[1] + "/index.json"))
m = json.load(open(sys.argv[1] + "/blobs/sha256/" + idx["manifests"][0]["digest"][7:]))
for d in [m["config"]] + m["layers"]:
    print(d["digest"])
EOF
UPLOADED=0
while read -r d; do
    [ "$(status -X POST --data-binary @"$WORK/rl/blobs/sha256/${d#sha256:}" "$BASE/v2/cosmos-layers/demo/blobs/uploads/?digest=$d")" = "201" ] && UPLOADED=$((UPLOADED + 1))
done < "$WORK/rl.list"
check "stage blobs pushed" "$UPLOADED" "4"
check "run-layers manifest pushed" "$(status -X PUT -H "Content-Type: $MT" --data-binary @"$WORK/rl/blobs/sha256/${RLD#sha256:}" "$BASE/v2/cosmos-layers/demo/manifests/run-42")" "201"
check "pulled back via /v2/ byte-identical" "$(OUT="$WORK/rlback" status "$BASE/v2/cosmos-layers/demo/manifests/run-42" > /dev/null; sha "$WORK/rlback")" "${RLD#sha256:}"
check "artifactType preserved" "$(json "$WORK/rlback" "j['artifactType']")" "application/vnd.cosmos.run-layers.v1+json"
check "runs view" "$(anon "$BASE/api/v1/layers/demo" > /dev/null; json "$WORK/body" "(j['repository'], [(r['run_id'], r['digest']) for r in j['runs']])")" "('cosmos-layers/demo', [('run-42', '$RLD')])"
check "run view" "$(anon "$BASE/api/v1/layers/demo/run-42")" "200"
cp "$WORK/body" "$WORK/run.json"
check "stages in order" "$(json "$WORK/run.json" "[s['stage'] for s in j['stages']]")" "['checkout', 'build', 'test']"
check "annotations" "$(json "$WORK/run.json" "[(s['bindings'], s['reuse'], s['step_key'], s['agent']) for s in j['stages']]")" "[('', 'opaque', '', 'agent-a'), ('arch=x86_64', 'resolved', 'k-1f2e3d', 'agent-a'), ('arch=x86_64,os=linux', 'pure', 'k-9a8b7c', 'agent-b')]"
check "stage digests + sizes" "$(json "$WORK/run.json" "[(s['digest'], s['size']) for s in j['stages']]")" "$(python3 -c "import json; m=json.load(open('$WORK/rlback')); print([(l['digest'], l['size']) for l in m['layers']])")"
check "media types" "$(json "$WORK/run.json" "sorted(set(s['media_type'] for s in j['stages']))")" "['application/vnd.oci.image.layer.v1.tar+gzip']"
check "total size" "$(json "$WORK/run.json" "j['total_size'] == sum(s['size'] for s in j['stages'])")" "True"
check "stage blob pull verifies" "$(D=$(sed -n 2p "$WORK/rl.list"); OUT="$WORK/st" status "$BASE/v2/cosmos-layers/demo/blobs/$D" > /dev/null; echo "sha256:$(sha "$WORK/st")" | grep -c "$D")" "1"
check "unknown run" "$(anon "$BASE/api/v1/layers/demo/run-0")" "404"
check "plain image is not a run-layers artifact" "$(status -X PUT -H "Content-Type: $MT" --data-binary @"$WORK/m.json" "$BASE/v2/cosmos-layers/demo/manifests/not-a-run" > /dev/null; anon "$BASE/api/v1/layers/demo/not-a-run")" "422"

echo "webhooks: events"
wait_for 10 '[ "$(hooklog "$WORK/a.jsonl" "len([x for x in r if x[\"event\"]==\"image.pushed\" and x[\"body\"][\"data\"][\"tag\"]==\"run-42\"])")" = 1 ]'
check "image.pushed for the run-layers artifact" "$(hooklog "$WORK/a.jsonl" "[x['body']['data'] for x in r if x['event']=='image.pushed' and x['body']['data']['tag']=='run-42'][0]")" "{'repository': 'cosmos-layers/demo', 'tag': 'run-42', 'digest': '$RLD', 'media_type': '$MT', 'artifact_type': 'application/vnd.cosmos.run-layers.v1+json'}"
check "artifact.published" "$(status -X PUT --data-binary 'hello' "$BASE/generic/hooks/a.txt")" "201"
for f in tests/fixtures/*.exodus.json; do
    base=$(basename "$f" .exodus.json); name=${base%-*}; version=${base##*-}
    status -X PUT --data-binary @"$f" "$BASE/exodus/$name/$version/exodus.json" > /dev/null
done
printf 'zlib build\0\1' > "$WORK/z.bin"
check "package.published (upload)" "$(status -X PUT --data-binary @"$WORK/z.bin" "$BASE/exodus/zlib-lite/1.0.0/package")" "201"
wait_for 10 '[ "$(hooklog "$WORK/a.jsonl" "len([x for x in r if x[\"event\"]==\"package.published\"])")" = 1 ]'
check "A: artifact.published data" "$(hooklog "$WORK/a.jsonl" "[x['body']['data'] for x in r if x['event']=='artifact.published'][0]")" "{'path': 'hooks/a.txt', 'sha256': '$(printf hello | sha256sum | cut -d' ' -f1)', 'size': 5}"
check "A: manifest.published deps" "$(hooklog "$WORK/a.jsonl" "[x['body']['data']['dependencies'] for x in r if x['event']=='manifest.published' and x['body']['data']['name']=='core'][0]")" "[{'name': 'zlib-lite', 'spec': ''}]"
check "A: package.published impact" "$(hooklog "$WORK/a.jsonl" "[x['body']['data']['impact']['needs'] for x in r if x['event']=='package.published'][0]")" "{'app': ['core', 'net'], 'core': ['zlib-lite'], 'legacy': ['core'], 'net': ['core']}"
check "A: all signatures valid" "$(hooklog "$WORK/a.jsonl" "all(x['signature_ok'] for x in r)")" "True"
check "A: delivery ids unique" "$(hooklog "$WORK/a.jsonl" "len(set(x['delivery'] for x in r)) == len(r)")" "True"
echo "  (receiver B fails twice; kontor retries after 1 s and 5 s)"
wait_for 25 '[ "$(hooklog "$WORK/b.jsonl" "len([x for x in r if x[\"event\"]==\"package.published\"])")" = 3 ]'
check "B: three attempts, same delivery" "$(hooklog "$WORK/b.jsonl" "[(x['status'], x['event']) for x in r if x['event']!='ping']")" "[(500, 'package.published'), (500, 'package.published'), (200, 'package.published')]"
check "B: one delivery id" "$(hooklog "$WORK/b.jsonl" "len(set(x['delivery'] for x in r if x['event']!='ping'))")" "1"
check "B: signatures valid" "$(hooklog "$WORK/b.jsonl" "all(x['signature_ok'] for x in r)")" "True"
check "B: no other events" "$(hooklog "$WORK/b.jsonl" "sorted(set(x['event'] for x in r))")" "['package.published', 'ping']"
wait_for 10 'status "$BASE/api/v1/webhooks/$SUB_B/deliveries" > /dev/null; [ "$(json "$WORK/body" "[d[\"status\"] for d in j[\"deliveries\"] if d[\"event\"]==\"package.published\"]")" = "['"'"'delivered'"'"']" ]'
check "B: delivery log" "$(status "$BASE/api/v1/webhooks/$SUB_B/deliveries" > /dev/null; json "$WORK/body" "[(d['event'], d['attempts'], d['status'], d['last_code']) for d in j['deliveries'] if d['event']=='package.published']")" "[('package.published', 3, 'delivered', 200)]"
DLV=$(json "$WORK/body" "[d['delivery'] for d in j['deliveries'] if d['event']=='package.published'][0]")
check "redeliver" "$(status -X POST "$BASE/api/v1/webhooks/$SUB_B/deliveries/$DLV/redeliver")" "202"
wait_for 10 '[ "$(hooklog "$WORK/b.jsonl" "len([x for x in r if x[\"delivery\"]==\"$DLV\"])")" = 4 ]'
check "redelivered with the same id" "$(hooklog "$WORK/b.jsonl" "[x['status'] for x in r if x['delivery']=='$DLV'][-1]")" "200"
check "delete webhook" "$(status -X DELETE "$BASE/api/v1/webhooks/$SUB_B")" "204"
check "deleted webhook deliveries -> 404" "$(status "$BASE/api/v1/webhooks/$SUB_B/deliveries")" "404"
check "secrets not in server log" "$(grep -c -e "$TOKEN" -e "$SECRET_A" "$WORK/server.log")" "0"

echo
echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ] || { echo "--- server log"; grep -v WARNING "$WORK/server.log" | tail -20; }
exit "$FAILS"
