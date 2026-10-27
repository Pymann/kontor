# museum ⇄ cosmos — ecosystem contract

Status: draft, 2026-10-27.  This file is the **contract** between the two
programs: wire formats, names and responsibilities.  Each side documents its own
internals; anything both sides must agree on lives here, once.

## 1. Roles

| | museum | cosmos |
|---|---|---|
| is | artifact store + dependency graph | control plane: agents, pipelines, runs |
| owns | blobs, images, layers, packages, manifests, rebuild plans | runs, schedules, agents, users of the control plane |
| never does | run code, schedule work | store artifacts long-term, compute dependency graphs |

The two talk over **HTTP only**: museum's registry + REST API, cosmos' REST API.
Each side can run without the other.

## 2. Images — OCI Distribution API (museum)

museum implements the OCI Distribution Spec v1.1 pull + push endpoints under
`/v2/` (blobs, chunked and monolithic uploads, manifests by tag and digest,
tags list, catalog).  Any OCI client (docker, podman, skopeo, oras, cosmos)
can push and pull.

- Blobs and manifests share museum's content-addressed store (`cas/`), so an
  image layer that is also an exodus package or a generic file is stored once.
- Repository names: `[a-z0-9]+([._-][a-z0-9]+)*(/[a-z0-9]+([._-][a-z0-9]+)*)*`.
- cosmos addresses a museum image as `museum:<repo>:<tag>` or
  `museum:<repo>@sha256:<hex>`; the museum base URL comes from cosmos'
  configuration (`integrations.museum.url`), never from the pipeline (aiml
  F62-17: no host paths/addresses in pipelines).

## 3. Stage layers (museum stores, cosmos produces and consumes)

A cosmos run produces one layer per stage (overlay upper dir).  To share them
beyond one host they are pushed to museum as an **OCI artifact**:

- Repository: `cosmos-layers/<pipeline>`; tag: `<run_id>`.
- Manifest `artifactType`: `application/vnd.cosmos.run-layers.v1+json`.
- `config`: JSON `{run_id, pipeline, base}` (`mediaType`
  `application/vnd.cosmos.run-layers.config.v1+json`).
- `layers[i]`: one descriptor per stage, in stage order, media type
  `application/vnd.oci.image.layer.v1.tar+gzip` (deterministic tar: sorted
  entries, fixed mtime, declared uid/gid — cosmos F96-19), annotations:
  - `cosmos.stage` — bare stage name
  - `cosmos.bindings` — lane bindings (`arch=x86_64,...`, empty for none)
  - `cosmos.reuse` — `opaque|resolved|pure`
  - `cosmos.step_key` — the step key (empty if not cacheable)
  - `cosmos.agent` — producing agent id
- Pulling back = GET manifest + GET the blobs that are missing locally
  (content-addressed, verified by digest on download).

**Trust (cosmos F110-121).** A layer from museum is a claim about work nobody
else saw.  museum verifies only the *bytes* (digest).  Whether a foreign layer
may satisfy a cache hit or a `base:` on another host is cosmos policy
(`layers.trust` in cosmos config: `same_host` (default) | listed agents).

## 4. Webhooks (museum → cosmos and others)

museum POSTs JSON to every configured subscriber.

Headers:

| header | value |
|---|---|
| `Content-Type` | `application/json` |
| `X-Museum-Event` | event name (below) |
| `X-Museum-Delivery` | unique delivery id |
| `X-Museum-Signature-256` | `sha256=<hex HMAC-SHA256(secret, raw body)>` (GitHub-compatible) |

Body (all events): `{"event", "delivery", "timestamp_ms", "museum", "data": {...}}`.

| event | `data` |
|---|---|
| `package.published` | `{name, version, sha256, size, unchanged, impact}` — `impact` is museum's rebuild plan (`rebuild_count`, `rebuild_waves`, `needs`, `outdated_pins`, `up_to_date`, `cycles`) or `null` when unchanged |
| `manifest.published` | `{name, version, dependencies, apt_packages}` |
| `artifact.published` | `{path, sha256, size}` (generic repository) |
| `image.pushed` | `{repository, tag, digest, media_type, artifact_type}` (includes cosmos layer artifacts) |
| `ping` | `{}` — sent when a subscription is created or tested |

**Impact plan** (also returned by `GET /api/impact` and the package upload):
`needs` maps every project in `rebuild_waves` to its **direct** dependencies
inside the rebuild set, where the trigger project counts as part of the set
(wave-1 projects list the trigger); `[]` when none.  Example for the fixture
graph and trigger `zlib-lite`: `{"app":["core","net"],"core":["zlib-lite"],
"legacy":["core"],"net":["core"]}`.

Delivery: at-least-once, retried with backoff (1 s, 5 s, 30 s, 2 min, 10 min),
each attempt recorded; receivers must be idempotent on `X-Museum-Delivery`.
A receiver answers 2xx to accept; anything else is retried.

## 5. Rebuild campaigns (cosmos consumes `package.published`)

cosmos maps exodus projects to pipelines in its catalog (`project:` on a
catalog entry).  On `package.published` with a non-null impact:

1. cosmos opens a **campaign** keyed by the trigger (`name@version`) holding
   museum's waves.
2. It starts the pipelines of wave 1.
3. When a project of the campaign later publishes (its own
   `package.published`), cosmos marks it done in the campaign and starts every
   project of the next waves whose dependencies inside the campaign are done —
   instead of opening a second campaign that would rebuild the same projects
   again.
4. A failed run stops the campaign's dependents (fail closed) and is reported.
5. A dependent whose rebuilt dependencies (per `needs`) **all** published
   byte-identical packages (`unchanged: true`) is skipped — nothing it consumes
   changed.

museum computes *what* depends on what; cosmos decides *when* to run it.

## 6. Identity and access (both)

Both programs accept the same three identity sources, configured separately:

- **local accounts** (each program's own store),
- **LDAP** — simple bind (direct DN template or search-then-bind), group
  membership via a configurable attribute / group search,
- **SAML 2.0 SSO** — SP-initiated, HTTP-Redirect binding for the AuthnRequest,
  HTTP-POST binding for the Response; the Response or Assertion must be signed
  by the configured IdP certificate; audience, destination, validity window
  and issuer are checked.

Authorization is by **roles**, each a list of allowed actions (cosmos spec
100 F100-11).  Groups from LDAP / SAML attributes map to roles in config.

Machine access (CI, docker, cosmos ⇄ museum) uses **API tokens**: random
256-bit secrets, stored only as sha256, revocable, scoped to roles.
museum accepts them as `Authorization: Bearer <token>` or as the password of
HTTP Basic auth (`docker login`).

## 7. REST

| | base path | auth |
|---|---|---|
| museum | `/api/v1/…` (+ `/v2/` registry, + repository paths) | Bearer / Basic / session |
| cosmos | `/api/v1/…` via `cosmos-api` (HTTP gateway to `cosmosd` RPCs) | Bearer (cosmos session or API token) |

Errors are JSON `{"error": "...", "code": "..."}` with a meaningful HTTP status.
Exception: museum's `/v2/` registry answers with the OCI error format
`{"errors":[{"code","message"}]}` that OCI clients expect.

museum's endpoints (implemented, see museum README): `/api/v1/whoami`,
`/api/v1/tokens` (POST/GET, DELETE `/<id>`), `/api/v1/users` (admin),
`/api/v1/webhooks` (POST/GET, DELETE `/<id>`, POST `/<id>/test`,
GET `/<id>/deliveries`, POST `/<id>/deliveries/<delivery>/redeliver`),
`/api/v1/layers/<pipeline>[/<run>]`, `/api/v1/graph`, `/api/v1/impact`,
`/api/v1/health`, plus `/api/v1/generic/…` and `/api/v1/exodus/…` aliases of
the repository paths.  Rights: `read`, `write`, `delete`, `admin`,
`webhook_admin`; anonymous requests get the role `reader` by default
(`auth.anonymous` in `museum.yaml`).
