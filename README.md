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

museum needs an aiml build that includes the branches listed under
[aiml requirements](#aiml-requirements) (merged on `museum/aiml-support` in the
aiml repo).

```bash
aiml museum.aiml -- 8081 ./data      # port and data directory (defaults: 8081, ./data)
```

## API

| Method | Path | |
|---|---|---|
| PUT/GET | `/generic/<path>` | Upload / download any file. Optional `X-Checksum-Sha256` header is verified on upload. Downloads support `Range`. |
| PUT/GET | `/exodus/<name>/<version>/exodus.json` | Project manifest. Name and version must match the URL. |
| PUT/GET | `/exodus/<name>/<version>/package` | Build output (any bytes). Upload answers with the rebuild plan. |
| GET | `/api/graph` | All projects (newest version) with their dependency and apt edges. |
| GET | `/api/impact?project=<name>&version=<v>` | Rebuild plan for a new project version. |
| GET | `/api/impact?apt=<pkg>&version=<v>` | Rebuild plan for a system package version. |
| GET | `/api/health` | |

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
    "outdated_pins": [{"project": "tool", "pins": "0.9.0"}],
    "up_to_date": [],
    "cycles": []
  }
}
```

- **rebuild_waves**: every project in a wave depends only on earlier waves, so
  each wave can be built in parallel.
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
  cas/<aa>/<sha256>                      blobs, deduplicated by content
  generic/<path>/blob.sha256             pointer to the blob
  exodus/<name>/<version>/exodus.json    manifest
  exodus/<name>/<version>/package.sha256 pointer to the package blob
  tmp/                                   staging for atomic writes (write + rename)
```

## Layout

| File | |
|---|---|
| `museum.aiml` | entry point: routes, thin handlers |
| `lib/api.aiml` | `museum.api.RepositoryApi` — the endpoints |
| `lib/graph.aiml` | `museum.graph.DependencyGraph` — graph snapshot, rebuild planning |
| `lib/exchange.aiml` | `museum.http.Exchange` — request/response helpers |
| `lib/store.aiml` | content-addressed storage, atomic small files |
| `lib/text.aiml` | JSON output, version ordering, path checks |

## Tests

```bash
AIML_BIN=/path/to/aiml tests/run_all.sh
```

Unit tests for the helpers and the graph (`tests/test_*.aiml`) and an
end-to-end test that starts the server and drives it with curl
(`tests/e2e.sh`: binary round-trip, range requests, dedup, checksum and
path-traversal rejection, rebuild plans, unchanged detection).

## aiml requirements

Building museum surfaced gaps in aiml; each is fixed on its own branch in the
aiml repo with tests, and all are merged on `museum/aiml-support`:

| Branch | Fix |
|---|---|
| `feature/io-write-file-buffer` | `io.write_file` accepts `buffer<u8>` (binary-safe) |
| `feature/http-binary-body` | binary-safe request bodies, `req.body_bytes`, `srv.set_max_body` |
| `feature/http-resp-body-file` | `resp.body_file` streams files (sendfile, Range, ETag) |
| `fix/fqn-call-args` | FQN calls into imports pass list/map args by reference, honor try/catch |
| `fix/fqn-main-composition` | spec/49 §15 recognizes `{ new: ns.Class }` |
| `fix/namespaced-class-instance` | `<.member` / `<.method` work in classes under `- namespace:` |
| `fix/same-arg-route-handlers` | `same_arg` exempts `(http_request_handle, http_response_handle)` handlers |
| `fix/jit-run-with-args` | multi-file programs no longer crash when started with `-- args` |
| `fix/import-cache-stdout-noise` | no stray `cf83e135…  -` line on stdout |

## Limits of the prototype

- Uploads are held in memory before they are written (cap set to 1 GiB);
  streaming uploads to disk need a streaming request API in aiml.
- The server handles one request at a time (aiml's default).
- No authentication yet.
- Only the newest version of each project is a graph node.
- Rebuild plans are returned, not yet sent to a CI system (webhooks are the
  obvious next step).
