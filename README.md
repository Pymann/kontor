# kontor

An artifact repository written in [aiml](https://github.com/Pymann/aiml) that
knows how your projects depend on each other. Upload a new build of a library
and kontor answers with the rebuild plan for everything downstream — in
parallel waves, with pinned consumers flagged and byte-identical rebuilds
recognized as no-ops.

The name: a *Kontor* was a trading post of the Hanseatic League — where goods
were received, booked, stored and passed on.  (Formerly named *museum*.)

Status: prototype. Two repository types — **generic** (any file) and
**exodus** (projects built with [Exodus](https://github.com/Pymann/exodus)).

## Why

Classic repositories store artifacts but have only a vague idea of who uses
them. kontor reads the `exodus.json` manifest of every project version and
keeps a dependency graph over the newest versions:

- **project edges** from `dependencies` (other Exodus projects)
- **system edges** from `apt_packages` (pinned apt packages with versions)

From that graph it answers two questions:

1. *A new version of X was published — what has to be rebuilt, in which order?*
2. *System package Y moved to version Z — which projects pin another version?*

Exodus itself only rebuilds within one project (see `doc/dependency_resolution_report.md`
in the Exodus repo); kontor is the cross-project layer.

## Run

kontor targets aiml's **`mem-v3-compiler`** branch (memV3 ownership model,
spec/61) plus the branches listed under [aiml requirements](#aiml-requirements).
Since 2026-10-28 (34c3340) all of them are merged into `mem-v3-compiler`
itself; kontor (and cosmos) pass their tests on it.

```bash
aiml kontor.aiml -- 8081 ./data      # port and data directory (defaults: 8081, ./data)
```

Built ahead of time it is an ordinary program and needs no compiler to run.
`exodus.json` takes its compiler from `$AIML` and its runtime from
`$AIML_VENV/lib` (aiml spec/68 F68-23), so a venv has to be active:

```bash
. /path/to/venv/env                  # aiml venv /path/to/venv  (aiml spec/68)
exodus build                         # ./kontor
./kontor 8081 ./data                 # the same arguments, without the `--`

aiml venv /path/to/venv install kontor --git https://github.com/Pymann/kontor
```

The install builds kontor with the venv's own compiler, places `bin/kontor`
and registers the sources as the importable package `@kontor`
(`aiml.tool.json`, aiml spec/68 §6).

Any aiml tool — kontor itself, ufo, cosmos — goes into a kontor and out of it
with the venv (aiml spec/68 §6.1, §6.3):

```bash
KONTOR_TOKEN=… aiml venv /path/to/venv publish --path . --kontor https://kontor.example:8443
KONTOR_TOKEN=… aiml venv /other/venv install kontor --kontor https://kontor.example:8443
```

`publish` sends the committed, git-tracked sources as a reproducible archive;
a version that kontor has is not replaced (`409`), so raise `version` in
`aiml.tool.json` for the next one.  Only a caller with the `admin` right may
overwrite a published version or write a deleted one again.  A private CA goes to the client as
`AIML_WSS_CA=<ca.crt>`.

## API

All endpoints authorize the caller (see [Auth](#auth)). Errors are JSON
`{"error": "...", "code": "..."}` (`bad_request`, `unauthorized`, `forbidden`,
`not_found`, `conflict`, …); the registry under `/v2/` uses the OCI error
format `{"errors":[{"code","message"}]}` instead. Every `/api/…` path also
exists under `/api/v1/…`; `/generic/…` and `/exodus/…` have `/api/v1/` aliases.

| Method | Path | Right | |
|---|---|---|---|
| PUT/GET | `/generic/<path>` | write/read | Upload / download any file. Optional `X-Checksum-Sha256` header is verified on upload. Downloads support `Range`. Emits `artifact.published`. |
| PUT/GET | `/exodus/<name>/<version>/exodus.json` | write/read | Project manifest. Name and version must match the URL. Emits `manifest.published`. Once the version's package is there, `409`. |
| PUT/GET | `/exodus/<name>/<version>/package` | write/read | Build output (any bytes). Upload answers with the rebuild plan and emits `package.published`. A published version is not overwritten: a second upload is `409`. |
| GET | `/api/v1/graph` | read | All projects (newest version) with their dependency and apt edges. |
| GET | `/api/v1/impact?project=<name>&version=<v>` | read | Rebuild plan for a new project version. |
| GET | `/api/v1/impact?apt=<pkg>&version=<v>` | read | Rebuild plan for a system package version. |
| GET | `/api/v1/health` | – | |
| GET | `/api/v1/whoami` | – | `{name, kind (anonymous/user/token), roles}` |
| POST | `/api/v1/tokens` | authenticated | `{label, roles[], owner?}` → `{id, owner, roles, token}`; the secret is shown once. Tokens cannot carry rights their creator lacks; another `owner` needs admin. |
| GET | `/api/v1/tokens` | authenticated | Own tokens (admin: all), never secrets. |
| DELETE | `/api/v1/tokens/<id>` | authenticated | Revoke (own; admin: any). |
| POST/GET | `/api/v1/users` | admin | Create/replace `{name, password, roles[]}` / list. |
| DELETE | `/api/v1/users/<name>` | admin | |
| POST/GET | `/api/v1/webhooks` | webhook_admin | Subscribe `{url, secret (≥16 chars), events[]}` (default `["*"]`; sends `ping`) / list (no secrets). |
| DELETE | `/api/v1/webhooks/<id>` | webhook_admin | |
| POST | `/api/v1/webhooks/<id>/test` | webhook_admin | Queue a `ping`. |
| GET | `/api/v1/webhooks/<id>/deliveries` | webhook_admin | Delivery log: `{delivery, event, attempts, status (pending/retrying/delivered/failed), last_code, updated_ms}`. |
| POST | `/api/v1/webhooks/<id>/deliveries/<delivery>/redeliver` | webhook_admin | Same delivery id and payload again. |
| GET | `/api/v1/layers/<pipeline>` | read | Runs of a cosmos pipeline: tags of `cosmos-layers/<pipeline>`. |
| GET | `/api/v1/layers/<pipeline>/<run>` | read | Stages of one run: name, bindings, reuse, step key, agent, digest, size, media type. |
| * | `/v2/…` | read/write/delete | OCI Distribution v1.1 registry, see [Registry](#registry). |
| GET | `/`, `/ui/…` | – | The web UI (`--ui-dir`, `$KONTOR_UI_DIR`), see [doc/spec/web_ui.md](doc/spec/web_ui.md). |
| POST | `/api/v1/sessions` | Basic login | Session token for the UI `{id, owner, roles, token, expires_ms}` (`auth.session_hours`, default 12). |
| GET | `/api/v1/catalog` | read | What kontor holds: projects, generic files, OCI repositories, layer runs. |
| GET | `/api/v1/catalog/exodus/<name>` | read | Versions with publisher, time, size, protection, dependents, install command. |
| GET | `/api/v1/catalog/generic?prefix=<p>` | read | Directory listing of generic files. |
| GET/PUT | `/api/v1/retention` | admin | Retention policy (opt-in; `data/config/retention.yaml`). |
| POST | `/api/v1/retention/preview` | admin | What the stored (or the posted) policy would delete. |
| POST | `/api/v1/retention/run` | admin | Run it now; `GET /api/v1/retention/runs` is the log. |
| GET/PUT/DELETE | `/api/v1/protected?repo=&name=&version=` | admin | Objects retention never deletes. |
| DELETE | `/exodus/<name>/<version>` | delete | Delete a version (leaves a tombstone; newest, dependencies and protected ones are kept). |
| GET/PUT | `/api/v1/settings` | admin | Anonymous role, public URL, session hours, custom roles; overrides `kontor.yaml`. |

### Auth

- **Roles** are lists of actions: `read`, `write`, `delete`, `admin`,
  `webhook_admin` (`*` = all). Built in: `reader` (read), `writer`
  (read, write), `maintainer` (read, write, delete), `admin` (*).
- **Anonymous** requests get the role `reader` unless configured otherwise
  (`auth.anonymous: none` disables anonymous access).
- **Local users** — passwords as PBKDF2-HMAC-SHA256 (100 000 iterations,
  random salt), compared in constant time; at least 8 characters.
- **API tokens** — 256-bit random hex secrets; only their sha256 is stored;
  revocable; scoped to roles. Use as `Authorization: Bearer <token>` or as the
  password of HTTP Basic (`user:token`, e.g. `docker login`/`skopeo --creds`).
  Basic `user:password` works too.
- **Bootstrap**: `--admin-token-file <path>` or `KONTOR_ADMIN_TOKEN` (≥32
  characters) installs an admin token with id `bootstrap` and owner `admin`.
  The secret is never logged.
- **LDAP** (`identity_sources: [local, ldap]`): HTTP Basic `user:password`
  is checked locally first (break-glass admin), then against the directory —
  DN template (`user_dn: "uid={user},…"`) or search-then-bind
  (`search_base` + `search_filter`, service account `bind_dn` +
  `bind_password_file`).  Input goes through `ldap.escape_dn` /
  `ldap.escape_filter`; an empty password never reaches the directory.
- **SAML 2.0** (`identity_sources: [..., saml]`): `GET /api/v1/sso/saml/login?relay=/path`
  redirects to the IdP; `POST /api/v1/sso/saml/acs` verifies the signed
  response (only for a request kontor issued, once, ≤10 min; optional issuer
  check) and mints a **session token** — an API token with `expires_ms`
  (`session_hours`, default 12).  A local `RelayState` gets a 302 with
  `#token=<id>:<secret>`, anything else gets JSON.
- **Groups → roles**: `auth.group_roles` maps directory/IdP groups (for a DN
  value also its first RDN, `cn=devs,…` → `devs`) to roles; every LDAP/SAML
  user also gets `auth.default_role` (default `reader`, `none` = groups only).
- Needs an aiml with the identity builtins (aiml spec/67, branch
  `feature/identity-builtins-memv3`).

`data/kontor.yaml` (optional):

```yaml
public_url: https://kontor.example.com   # used in webhook payloads ("kontor")
auth:
  anonymous: reader                      # role for anonymous requests, or "none"
  identity_sources: [local]              # or [local, ldap, saml]
  # default_role: reader                 # every LDAP/SAML user
  # group_roles: { devs: writer }        # directory/IdP group → role
  # ldap: { url: "ldap://dir:389", user_dn: "uid={user},ou=people,dc=example,dc=org", group_attr: memberOf }
  # saml: { idp_sso_url: …, idp_cert_file: …, sp_entity_id: …, acs_url: …, idp_entity_id: …, group_attr: groups }
  roles:                                 # added to / overriding the built-ins
    ci: [read, write]
    hooks: [read, webhook_admin]
```

### Registry

OCI Distribution Spec v1.1 under `/v2/`, tested with skopeo
(`tests/ecosystem.sh`): `GET /v2/` (answers `401` with
`WWW-Authenticate: Basic realm="kontor"` without credentials), blob
`HEAD`/`GET` (`Docker-Content-Digest`, `Content-Length`, `Range`), uploads
(monolithic `POST ?digest=`, sessions with `PATCH` + `Content-Range` and
chunked transfer encoding, `PUT ?digest=` verifies the sha256, cross-repo
`?mount=&from=`, `DELETE` cancels), manifests by tag or digest (stored as raw
bytes, `Content-Type` = their `mediaType`, all referenced blobs must exist),
`DELETE` of manifests and tags (right `delete`), `tags/list` and `_catalog`
with `n`/`last` pagination and `Link`. Pushing a manifest emits `image.pushed`.

Blobs live in the same `cas/` as generic files and packages. Request bodies
are spooled to `data/tmp/spool` by the server, never held in memory; an
upload session grows by appending the spooled chunk to its file.
Limits: 10 GiB per request body, 4 MiB per manifest, 120 s idle timeout.

### Webhooks

Contract: `doc/ecosystem.md` §4. Each event is POSTed as
`{"event","delivery","timestamp_ms","kontor","data"}` with
`X-Kontor-Event`, `X-Kontor-Delivery` and
`X-Kontor-Signature-256: sha256=<HMAC-SHA256(secret, body)>`. A worker thread
delivers the persisted queue; non-2xx answers are retried after 1 s, 5 s,
30 s, 2 min and 10 min, then marked `failed`. Delivery is at-least-once —
receivers dedupe on `X-Kontor-Delivery`.

### Example

```bash
curl -X PUT --data-binary @exodus.json localhost:8081/exodus/zlib-lite/1.1.0/exodus.json
curl -X PUT --data-binary @out/libzlib-lite.a localhost:8081/exodus/zlib-lite/1.1.0/package
```

An aiml project published as a source archive is installed straight out of
here, with no git server in between (aiml spec/68 §6.1) — read access is
anonymous by default (`auth: { anonymous: reader }`):

```bash
aiml venv /path/to/venv install ufo --kontor http://localhost:8081
aiml venv /path/to/venv install --all --kontor http://localhost:8081   # the whole toolbox
```

```json
{
  "name": "zlib-lite", "version": "1.1.0", "sha256": "…", "size": 24,
  "unchanged": false,
  "impact": {
    "trigger": {"kind": "project", "name": "zlib-lite", "version": "1.1.0"},
    "rebuild_count": 4,
    "rebuild_waves": [["core"], ["legacy", "net"], ["app"]],
    "needs": {"app": ["core", "net"], "core": ["zlib-lite"], "legacy": ["core"], "net": ["core"]},
    "outdated_pins": [{"project": "tool", "pins": "0.9.0"}],
    "up_to_date": [],
    "cycles": []
  }
}
```

- **rebuild_waves**: every project in a wave depends only on earlier waves, so
  each wave can be built in parallel.
- **needs**: the direct dependencies of each rebuilt project inside the
  rebuild set (the trigger included) — lets a CI skip a project whose rebuilt
  dependencies all came out byte-identical.
- **outdated_pins**: direct consumers that pin a different exact version — they
  are not rebuilt automatically; bump the pin first.
- **unchanged**: the uploaded bytes equal the previous version's package
  (reproducible rebuild) — then `impact` is `null`, nothing downstream changes.
- **cycles**: projects that depend on each other in a cycle and cannot be ordered.

Version specs: empty, `*` and `latest` float; anything else must match exactly.
Dependents further down the chain are always rebuilt, because the versions
their rebuilt dependencies will get are not known yet.

## Storage

```
data/
  kontor.yaml                            optional configuration
  cas/<aa>/<sha256>                      blobs, deduplicated by content (also OCI blobs and manifests)
  generic/<path>/blob.sha256             pointer to the blob
  exodus/<name>/<version>/exodus.json    manifest
  exodus/<name>/<version>/package.sha256 pointer to the package blob
  oci/repos/<repo, "/"→"+">/tags/<tag>   manifest digest of a tag
  oci/repos/<repo>/manifests/<hex>       media type of a manifest in the repository
  oci/uploads/<uuid>, <uuid>.repo        open upload sessions
  auth/users/<name>                      {roles, salted PBKDF2 hash, source}
  auth/tokens/<sha256(secret)>           {id, owner, label, roles, created_ms}
  hooks/subs/<id>                        {url, secret, events}
  hooks/queue/<delivery>                 due deliveries (attempt, next_ms)
  hooks/log/<id>/<delivery>[.body]       delivery log and the signed payload
  tmp/                                   staging for atomic writes, request spool
```

Everything is plain files written via temp file + rename, so a crash never
leaves a half-written record; restarting kontor resumes queued deliveries.

## Layout

| File | |
|---|---|
| `kontor.aiml` | entry point: routes, thin handlers |
| `lib/api.aiml` | `kontor.api.RepositoryApi` — the endpoints |
| `lib/graph.aiml` | `kontor.graph.DependencyGraph` — graph snapshot, rebuild planning |
| `lib/exchange.aiml` | `kontor.http.Exchange` — request/response helpers, JSON errors |
| `lib/auth.aiml` | `kontor.auth.AccessControl` — roles, users, tokens, authentication |
| `lib/identity.aiml` | `kontor.identity.IdentitySources` — LDAP and SAML on the aiml identity builtins |
| `lib/oci.aiml` | `kontor.oci.Registry` — OCI Distribution v1.1 |
| `lib/hooks.aiml` | `kontor.hooks.WebhookHub` — subscriptions, queue, signed delivery |
| `lib/store.aiml` | content-addressed storage, atomic small files |
| `lib/text.aiml` | JSON output, version ordering, path checks |

## Tests

```bash
AIML_BIN=/path/to/aiml tests/run_all.sh
AIML_BIN=/path/to/aiml KONTOR_BIN=./kontor tests/run_all.sh   # against the built binary
```

`KONTOR_BIN` is what a build pipeline sets: the end-to-end tests then drive
the program that was just built, not the compiler reading the sources.

Unit tests for the helpers and the graph (`tests/test_*.aiml`) and an
end-to-end test that starts the server and drives it with curl
(`tests/e2e.sh`: auth and tokens, binary round-trip, range requests, dedup,
checksum and path-traversal rejection, rebuild plans, unchanged detection) and
`tests/ecosystem.sh`: registry protocol via curl, skopeo push/inspect/pull
of an OCI layout (`tests/fixtures/oci/make_layout.py`), a cosmos run-layers
artifact read back via `/v2/` and `/api/v1/layers`, and webhooks against
signature-verifying receivers (one fails twice, then accepts).

## aiml requirements

Building kontor surfaced gaps in aiml; each was fixed on its own branch off
`mem-v3-compiler` with tests, and all of them are merged into
`mem-v3-compiler` (aiml's default branch):

| Branch | Fix |
|---|---|
| `feature/io-write-file-buffer-memv3` | `io.write_file` accepts `buffer<u8>` (binary-safe) |
| `feature/http-binary-body-memv3` | binary-safe request bodies, `req.body_bytes`, `srv.set_max_body` |
| `feature/http-resp-body-file-memv3` | `resp.body_file` streams files (sendfile, Range, ETag) |
| `fix/http-maps-memv3-handles` | `req.params` / `url.get_param` / `req.cookies` / url parts as memV3 managed handles and strings (heap corruption before) |
| `fix/fqn-call-args-memv3` | FQN calls into imports pass list/map args correctly, honor try/catch |
| `fix/fqn-main-composition-memv3` | spec/49 §15 recognizes `{ new: ns.Class }` |
| `fix/namespaced-class-instance-memv3` | `<.member` / `<.method` work in classes under `- namespace:` |
| `fix/same-arg-route-handlers-memv3` | `same_arg` exempts `(http_request_handle, http_response_handle)` handlers |
| `fix/jit-run-with-args-memv3` | multi-file programs no longer crash when started with `-- args` |
| `feature/http-registry-support-memv3` | chunked request bodies, spooling bodies to temp files (`srv.set_spool`, `req.body_path`, `req.body_len`), `HEAD` without body, `io.append_from`, `connection: close` (needed for the registry) |
| `feature/identity-builtins-memv3` | `base64.*`, `ldap.*`, `saml.*` (aiml spec/67) — Basic auth, LDAP and SAML logins |
| `feature/http-client-files-memv3` | binary-safe http client (`client.body_file`, `resp.save_to`, `resp.body_len`), HEAD responses without body — used by cosmos to push/pull images |

### Ownership (memV3)

kontor follows spec/61: the route handler owns the `Exchange` (`ptr<…>`) and
lends it to the API (`ref<…>` parameters); the graph snapshot is read through a
`ref`, and only `reload_graph` moves a new `ptr` into `RepositoryApi.graph`.
Passing a `ptr` to a method moves it — the callee frees it at its end.

A full server session (uploads, downloads, range, manifests, packages, impact,
graph) runs under valgrind with 0 invalid accesses.

## Limits of the prototype

- One lock serializes all request handlers (aiml's server runs one thread per
  connection); webhook delivery runs on its own thread outside it.
- Only the newest version of each project is a graph node.
- LDAP is asked on every Basic-authenticated request (no cache); SAML session
  tokens expire, but expired token files are not swept.
- No garbage collection of unreferenced blobs after manifest deletes.
