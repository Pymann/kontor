#!/bin/bash
# End-to-end test of LDAP and SAML 2.0 logins (doc/ecosystem.md §6) against a
# throwaway slapd and a simulated IdP (key via openssl, signature via xmlsec1).
#   AIML_BIN=/path/to/aiml tests/identity.sh
# Needs an aiml with the identity builtins (spec/67).  Skips (exit 0) when
# slapd or xmlsec1 is missing.
set -u
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
PORT="${PORT:-18094}"
LDAP_PORT=$((PORT + 300))
BASE="http://127.0.0.1:$PORT"
WORK="$(mktemp -d)"
DATA="$WORK/data"; mkdir -p "$DATA"
FAILS=0; PASSES=0; PIDS=""
trap 'kill $PIDS 2>/dev/null; [ -f "$WORK/slapd.pid" ] && kill "$(cat "$WORK/slapd.pid")" 2>/dev/null; rm -rf "$WORK"' EXIT
pass() { PASSES=$((PASSES + 1)); echo "  ok   $1"; }
fail() { FAILS=$((FAILS + 1)); echo "  FAIL $1"; }
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1: got '$2' want '$3'"; fi; }
SLAPD="$(command -v slapd || echo /usr/sbin/slapd)"
if [ ! -x "$SLAPD" ] || ! command -v xmlsec1 >/dev/null; then echo "SKIP: slapd or xmlsec1 missing"; exit 0; fi

# ── directory ────────────────────────────────────────────────────────────────
mkdir -p "$WORK/ldapdb"
MODLINE=""; [ -e /usr/lib/ldap/back_mdb.so ] && MODLINE="modulepath /usr/lib/ldap
moduleload back_mdb"
cat > "$WORK/slapd.conf" <<CONF
include /etc/ldap/schema/core.schema
include /etc/ldap/schema/cosine.schema
include /etc/ldap/schema/inetorgperson.schema
pidfile $WORK/slapd.pid
$MODLINE
database mdb
maxsize 10485760
suffix "dc=example,dc=org"
rootdn "cn=admin,dc=example,dc=org"
rootpw admin-secret
directory $WORK/ldapdb
access to attrs=userPassword by anonymous auth by * none
access to * by * read
CONF
SP="$(command -v slappasswd || echo /usr/sbin/slappasswd)"
cat > "$WORK/data.ldif" <<LDIF
dn: dc=example,dc=org
objectClass: dcObject
objectClass: organization
o: Example
dc: example

dn: ou=people,dc=example,dc=org
objectClass: organizationalUnit
ou: people

dn: uid=alice,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: alice
cn: Alice
sn: Example
businessCategory: cn=devs,ou=groups,dc=example,dc=org
userPassword: $("$SP" -s alice-pw)

dn: uid=bob,ou=people,dc=example,dc=org
objectClass: inetOrgPerson
uid: bob
cn: Bob
sn: Example
userPassword: $("$SP" -s bob-pw)
LDIF
"$(command -v slapadd || echo /usr/sbin/slapadd)" -f "$WORK/slapd.conf" -l "$WORK/data.ldif" > /dev/null 2>&1 || { echo "FAIL slapadd"; exit 1; }
"$SLAPD" -f "$WORK/slapd.conf" -h "ldap://127.0.0.1:$LDAP_PORT/" > /dev/null 2>&1
for _ in $(seq 50); do [ -f "$WORK/slapd.pid" ] && break; sleep 0.1; done

# ── IdP keys + config ────────────────────────────────────────────────────────
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=idp" -keyout "$WORK/idp_key.pem" -out "$WORK/idp_cert.pem" 2>/dev/null
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=evil" -keyout "$WORK/evil_key.pem" -out "$WORK/evil_cert.pem" 2>/dev/null
ACS="$BASE/api/v1/sso/saml/acs"
cat > "$DATA/museum.yaml" <<YAML
auth:
  anonymous: none
  identity_sources: [local, ldap, saml]
  default_role: reader
  group_roles:
    devs: writer
  ldap:
    url: "ldap://127.0.0.1:$LDAP_PORT"
    user_dn: "uid={user},ou=people,dc=example,dc=org"
    group_attr: businessCategory
  saml:
    idp_sso_url: "https://idp.example/sso"
    idp_cert_file: "$WORK/idp_cert.pem"
    sp_entity_id: "https://museum.example/sp"
    acs_url: "$ACS"
    idp_entity_id: "https://idp.example"
    group_attr: groups
    session_hours: 1
YAML
"$AIML_BIN" museum.aiml -- "$PORT" "$DATA" > "$WORK/server.log" 2>&1 & PIDS="$PIDS $!"
for _ in $(seq 100); do curl -s -o /dev/null "$BASE/api/health" && break; sleep 0.2; done

code() { curl -s -o "$WORK/body" -w '%{http_code}' "$@"; }
roles() { python3 -c "import json; print(','.join(json.load(open('$WORK/body'))['roles']))"; }

echo "ldap"
check "alice (ldap) whoami" "$(code -u alice:alice-pw "$BASE/api/v1/whoami")" "200"
check "alice roles: default + devs→writer" "$(roles)" "reader,writer"
check "bob (ldap) whoami" "$(code -u bob:bob-pw "$BASE/api/v1/whoami")" "200"
check "bob roles: default only" "$(roles)" "reader"
check "alice may write" "$(code -u alice:alice-pw -X PUT --data-binary hello "$BASE/api/v1/generic/id/a.txt")" "201"
check "bob may not write" "$(code -u bob:bob-pw -X PUT --data-binary hello "$BASE/api/v1/generic/id/b.txt")" "403"
check "wrong password" "$(code -u alice:nope "$BASE/api/v1/whoami")" "401"
check "empty password" "$(code -u alice: "$BASE/api/v1/whoami")" "401"
check "login '*'" "$(code -u '*:alice-pw' "$BASE/api/v1/whoami")" "401"

echo "saml"
rid_of() { python3 -c "import sys,urllib.parse,base64,zlib,re; q=urllib.parse.parse_qs(urllib.parse.urlparse(sys.argv[1]).query); print(re.search(r'ID=\"([^\"]+)\"', zlib.decompress(base64.b64decode(q['SAMLRequest'][0]),-15).decode()).group(1))" "$1"; }
make_resp() {  # make_resp <request_id> <key-prefix> <out.b64>
    python3 - "$1" "$ACS" > "$WORK/resp.tmpl.xml" <<'PY'
import sys
rid, acs = sys.argv[1], sys.argv[2]
sig = ('<ds:Signature xmlns:ds="http://www.w3.org/2000/09/xmldsig#"><ds:SignedInfo>'
       '<ds:CanonicalizationMethod Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/>'
       '<ds:SignatureMethod Algorithm="http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"/>'
       '<ds:Reference URI="#_a1"><ds:Transforms><ds:Transform Algorithm="http://www.w3.org/2000/09/xmldsig#enveloped-signature"/>'
       '<ds:Transform Algorithm="http://www.w3.org/2001/10/xml-exc-c14n#"/></ds:Transforms>'
       '<ds:DigestMethod Algorithm="http://www.w3.org/2001/04/xmlenc#sha256"/><ds:DigestValue></ds:DigestValue></ds:Reference>'
       '</ds:SignedInfo><ds:SignatureValue></ds:SignatureValue><ds:KeyInfo><ds:X509Data/></ds:KeyInfo></ds:Signature>')
print('<samlp:Response xmlns:samlp="urn:oasis:names:tc:SAML:2.0:protocol" xmlns:saml="urn:oasis:names:tc:SAML:2.0:assertion" '
      f'ID="_r1" Version="2.0" IssueInstant="2026-10-27T20:00:00Z" Destination="{acs}" InResponseTo="{rid}">'
      '<saml:Issuer>https://idp.example</saml:Issuer><samlp:Status><samlp:StatusCode Value="urn:oasis:names:tc:SAML:2.0:status:Success"/></samlp:Status>'
      '<saml:Assertion ID="_a1" Version="2.0" IssueInstant="2026-10-27T20:00:00Z"><saml:Issuer>https://idp.example</saml:Issuer>' + sig +
      f'<saml:Subject><saml:NameID>carol@example.org</saml:NameID><saml:SubjectConfirmation Method="urn:oasis:names:tc:SAML:2.0:cm:bearer">'
      f'<saml:SubjectConfirmationData InResponseTo="{rid}" NotOnOrAfter="2099-01-01T00:00:00Z" Recipient="{acs}"/></saml:SubjectConfirmation></saml:Subject>'
      '<saml:Conditions NotBefore="2020-01-01T00:00:00Z" NotOnOrAfter="2099-01-01T00:00:00Z"><saml:AudienceRestriction>'
      '<saml:Audience>https://museum.example/sp</saml:Audience></saml:AudienceRestriction></saml:Conditions>'
      '<saml:AuthnStatement AuthnInstant="2026-10-27T20:00:00Z" SessionIndex="_s1"><saml:AuthnContext><saml:AuthnContextClassRef>'
      'urn:oasis:names:tc:SAML:2.0:ac:classes:Password</saml:AuthnContextClassRef></saml:AuthnContext></saml:AuthnStatement>'
      '<saml:AttributeStatement><saml:Attribute Name="groups"><saml:AttributeValue>devs</saml:AttributeValue></saml:Attribute>'
      '</saml:AttributeStatement></saml:Assertion></samlp:Response>')
PY
    xmlsec1 --sign --privkey-pem "$WORK/$2_key.pem,$WORK/$2_cert.pem" --id-attr:ID urn:oasis:names:tc:SAML:2.0:assertion:Assertion \
        --output "$WORK/resp.xml" "$WORK/resp.tmpl.xml" 2>/dev/null
    base64 -w 0 "$WORK/resp.xml" > "$3"
}
acs() { curl -s -o "$WORK/body" -D "$WORK/hdr" -w '%{http_code}' -X POST --data-urlencode "SAMLResponse@$1" --data-urlencode "RelayState=$2" "$ACS"; }
location() { grep -i '^location:' "$WORK/hdr" | tr -d '\r' | cut -d' ' -f2-; }

LOC=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/api/v1/sso/saml/login?relay=/ui")
check "login → IdP" "${LOC%%\?*}" "https://idp.example/sso"
make_resp "$(rid_of "$LOC")" idp "$WORK/good.b64"
check "acs → 302" "$(acs "$WORK/good.b64" /ui)" "302"
TOK="$(location)"; TOK="${TOK#*#token=}"; SECRET="${TOK#*:}"
check "session token works" "$(code -H "Authorization: Bearer $SECRET" "$BASE/api/v1/whoami")" "200"
check "carol roles from SAML groups" "$(roles)" "reader,writer"
check "same response again" "$(acs "$WORK/good.b64" /ui)" "401"
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/api/v1/sso/saml/login")
make_resp "$(rid_of "$LOC")" evil "$WORK/evil.b64"
check "foreign certificate" "$(acs "$WORK/evil.b64" "")" "401"
make_resp "_unsolicited" idp "$WORK/unsol.b64"
check "unsolicited response" "$(acs "$WORK/unsol.b64" "")" "401"
LOC=$(curl -s -o /dev/null -w '%{redirect_url}' "$BASE/api/v1/sso/saml/login")
make_resp "$(rid_of "$LOC")" idp "$WORK/third.b64"
check "foreign RelayState → JSON, no redirect" "$(acs "$WORK/third.b64" "//evil.example/x")" "200"
check "no password in the log" "$(grep -c 'alice-pw\|bob-pw' "$WORK/server.log")" "0"

echo "$PASSES passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
