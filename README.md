# museum

An artifact repository written in [aiml](https://github.com/Pymann/aiml) that
knows how your projects depend on each other. Upload a new build of a library
and museum answers with the rebuild plan for everything downstream — in
parallel waves, with pinned consumers flagged and byte-identical rebuilds
recognized as no-ops.

Status: prototype. Two repository types — **generic** (any file) and
**exodus** (projects built with [Exodus](https://github.com/Pymann/exodus)).

## Why

Classic repositories store artifacts but have only a vague idea of who uses
them. museum reads the `exodus.json` manifest of every project version and
keeps a dependency graph over the newest versions:

- **project edges** from `dependencies` (other Exodus projects)
- **system edges** from `apt_packages` (pinned apt packages with versions)

From that graph it answers two questions:

1. *A new version of X was published — what has to be rebuilt, in which order?*
2. *System package Y moved to version Z — which projects pin another version?*

Exodus itself only rebuilds within one project (see `doc/dependency_resolution_report.md`
in the Exodus repo); museum is the cross-project layer.

## Run

museum targets aiml's **`mem-v3-compiler`** branch (memV3 ownership model,
spec/61) plus the branches listed under [aiml requirements](#aiml-requirements),
all merged on `museum/aiml-support-memv3` in the aiml repo.

```bash
aiml museum.aiml -- 8081 ./data      # port and data directory (defaults: 8081, ./data)
```

## API

All endpoints authorize the caller (see [Auth](#auth)). Errors are JSON
`{"error": "...", "code": "..."}` (`bad_request`, `unauthorized`, `forbidden`,
`not_found`, `conflict`, …); the registry under `/v2/` uses the OCI error
format `{"errors":[{"code","message"}]}` instead. Every `/api/…` path also
exists under `/api/v1/…`; `/generic/…` and `/exodus/…` have `/api/v1/` aliases.

| Method | Path | Right | |
|---|---|---|---|
| PUT/GET | `/generic/<path>` | write/read | Upload / download any file. Optional `X-Checksum-Sha256` header is verified on upload. Downloads support `Range`. Emits `artifact.published`. |
| PUT/GET | `/exodus/<name>/<version>/exodus.json` | write/read | Project manifest. Name and version must match the URL. Emits `manifest.published`. |
| PUT/GET | `/exodus/<name>/<version>/package` | write/read | Build output (any bytes). Upload answers with the rebuild plan and emits `package.published`. |
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
- **Bootstrap**: `--admin-token-file <path>` or `MUSEUM_ADMIN_TOKEN` (≥32
  characters) installs an admin token with id `bootstrap` and owner `admin`.
  The secret is never logged.
- **LDAP / SAML**: `auth.identity_sources` is the seam — `authenticate()`
  asks each configured source in order. Today only `local` exists; naming
  `ldap` or `saml` is a startup error until the aiml ldap/saml builtins land.

`data/museum.yaml` (optional):

```yaml
public_url: https://museum.example.com   # used in webhook payloads ("museum")
auth:
  anonymous: reader                      # role for anonymous requests, or "none"
  identity_sources: [local]              # later: [local, ldap, saml]
  roles:                                 # added to / overriding the built-ins
    ci: [read, write]
    hooks: [read, webhook_admin]
```

### Registry

OCI Distribution Spec v1.1 under `/v2/`, tested with skopeo
(`tests/ecosystem.sh`): `GET /v2/` (answers `401` with
`WWW-Authenticate: Basic realm="museum"` without credentials), blob
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
`{"event","delivery","timestamp_ms","museum","data"}` with
`X-Museum-Event`, `X-Museum-Delivery` and
`X-Museum-Signature-256: sha256=<HMAC-SHA256(secret, body)>`. A worker thread
delivers the persisted queue; non-2xx answers are retried after 1 s, 5 s,
30 s, 2 min and 10 min, then marked `failed`. Delivery is at-least-once —
receivers dedupe on `X-Museum-Delivery`.

### Example

```bash
curl -X PUT --data-binary @exodus.json localhost:8081/exodus/zlib-lite/1.1.0/exodus.json
curl -X PUT --data-binary @out/libzlib-lite.a localhost:8081/exodus/zlib-lite/1.1.0/package
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
  museum.yaml                            optional configuration
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
leaves a half-written record; restarting museum resumes queued deliveries.

## Layout

| File | |
|---|---|
| `museum.aiml` | entry point: routes, thin handlers |
| `lib/api.aiml` | `museum.api.RepositoryApi` — the endpoints |
| `lib/graph.aiml` | `museum.graph.DependencyGraph` — graph snapshot, rebuild planning |
| `lib/exchange.aiml` | `museum.http.Exchange` — request/response helpers, JSON errors |
| `lib/auth.aiml` | `museum.auth.AccessControl` — roles, users, tokens, authentication |
| `lib/b64.aiml` | base64 decoding for Basic auth (stopgap until aiml's `base64.decode`) |
| `lib/oci.aiml` | `museum.oci.Registry` — OCI Distribution v1.1 |
| `lib/hooks.aiml` | `museum.hooks.WebhookHub` — subscriptions, queue, signed delivery |
| `lib/store.aiml` | content-addressed storage, atomic small files |
| `lib/text.aiml` | JSON output, version ordering, path checks |

## Tests

```bash
AIML_BIN=/path/to/aiml tests/run_all.sh
```

Unit tests for the helpers and the graph (`tests/test_*.aiml`) and an
end-to-end test that starts the server and drives it with curl
(`tests/e2e.sh`: auth and tokens, binary round-trip, range requests, dedup,
checksum and path-traversal rejection, rebuild plans, unchanged detection) and
`tests/ecosystem.sh`: registry protocol via curl, skopeo push/inspect/pull
of an OCI layout (`tests/fixtures/oci/make_layout.py`), a cosmos run-layers
artifact read back via `/v2/` and `/api/v1/layers`, and webhooks against
signature-verifying receivers (one fails twice, then accepts).

## aiml requirements

Building museum surfaced gaps in aiml; each is fixed on its own branch off
`mem-v3-compiler` with tests, and all are merged on `museum/aiml-support-memv3`:

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
| `feature/http-registry-support-memv3` | chunked request bodies, spooling bodies to temp files (`srv.set_spool`, `req.body_path`, `req.body_len`), `HEAD` without body, `io.append_from` (needed for the registry; not yet on `museum/aiml-support-memv3`) |

### Ownership (memV3)

museum follows spec/61: the route handler owns the `Exchange` (`ptr<…>`) and
lends it to the API (`ref<…>` parameters); the graph snapshot is read through a
`ref`, and only `reload_graph` moves a new `ptr` into `RepositoryApi.graph`.
Passing a `ptr` to a method moves it — the callee frees it at its end.

A full server session (uploads, downloads, range, manifests, packages, impact,
graph) runs under valgrind with 0 invalid accesses.

## Limits of the prototype

- One lock serializes all request handlers (aiml's server runs one thread per
  connection); webhook delivery runs on its own thread outside it.
- Only the newest version of each project is a graph node.
- LDAP and SAML are configuration seams only (see [Auth](#auth)).
- Basic auth decoding is a museum-side stopgap that accepts printable ASCII
  credentials only, until aiml's `base64.decode` builtin is available.
- No garbage collection of unreferenced blobs after manifest deletes.
