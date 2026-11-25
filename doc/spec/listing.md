# Listing: finding what kontor holds

Status: decided 2026-11-25 (owner's report: an agent "probes run number ×
commit systematically, because kontor has no listing").

kontor answered only exact paths. A client that wanted "the artifact of run
1234" or "the newest build of commit abc123" had to guess paths and count
404s. This chapter gives every repository type a listing that a script or an
agent can use with `curl`, so no client has to probe.

The web UI's catalog (web_ui.md FW-30…FW-33) is built for people and may
change with the UI; the listing here is the stable machine API. Both read the
same store and the same publish metadata (web_ui.md FW-34).

## 1. Generic files

- **FL-01** `GET /api/v1/list/generic` (right `read`) lists the generic
  files below a prefix:

  ```json
  {
    "prefix": "aiml/ci",
    "items": [{"path": "aiml/ci/1234-abc123/aiml.tar.gz", "bytes": 1048576,
               "sha256": "…", "published_ms": 1764000000000, "publisher": "ci"}],
    "dirs": ["aiml/ci/1234-abc123"],
    "total": 1,
    "offset": 0,
    "limit": 1000
  }
  ```

  `path` is the full path below `/generic/`, so `GET /generic/<path>`
  downloads it as is. A file published before publish metadata existed
  gets the time kontor first saw it (web_ui.md FW-34) and `publisher` `""`.
- **FL-02** Query parameters, all optional:
  - `prefix` — a directory below `generic/` (default: the root). Same rules
    as a generic path: no `..`, no empty segment, no leading `/` → `400`.
    A prefix that is not a directory → `404` `{"code":"not_found"}`.
  - `recursive=1` — every file at any depth below the prefix; `dirs` is then
    `[]`. Without it: the files directly in the prefix, and its
    subdirectories in `dirs` (sorted).
  - `match=<glob>` — only paths (relative to the prefix) that match: `*` and
    `?` stay inside one segment, `**` spans any number of segments.
    `match` implies `recursive=1` when it contains `/` or `**`. Same path
    rules as `prefix` → `400`.
  - `sort=path` (default, ascending) or `sort=published` (`published_ms`,
    newest first; ties by path).
  - `limit` (default 1000, at most 10000) and `offset` (default 0) page the
    sorted list. `total` is the count before paging.
- **FL-03** "The newest artifact of run 1234" is one call:
  `GET /api/v1/list/generic?prefix=aiml/ci&match=1234-*/**&sort=published&limit=1`.
- **FL-04** A directory URL lists itself: `GET /generic/<dir>/` (trailing
  slash, also under `/api/v1/generic/`) answers like FL-01 with
  `prefix=<dir>` and the same query parameters. Without the slash a
  directory stays a `404` — a download must never get a JSON listing
  instead of the file.
- **FL-05** A `404` on a generic download says where to look: its JSON body
  carries `"list": "/api/v1/list/generic?prefix=<p>"`, `<p>` being the
  deepest existing directory above the requested path (`""` for the root).

## 2. exodus projects

- **FL-10** `GET /api/v1/list/exodus` (right `read`):
  `{"items":[{"name","newest","versions"}]}`, sorted by name; `newest` is the
  highest live version in spec/68's version order (`""` when every version
  is deleted), `versions` counts what FL-11 lists, tombstones included.
- **FL-11** `GET /api/v1/list/exodus/<name>` (right `read`): every version,
  newest first in version order,
  `{"name","items":[{"version","published_ms","publisher","sha256","bytes","deleted"}],"total","offset","limit"}`.
  `deleted` is `true` for a tombstone (web_ui.md FW-47); its `sha256` is
  `""` and `bytes` `0`. `match=<glob>` filters versions (`*`, `?`),
  `limit`/`offset` page as in FL-02. An unknown project → `404`.

## 3. OCI and cosmos layers

- **FL-20** OCI keeps the registry's own listing: `GET /v2/_catalog` and
  `GET /v2/<name>/tags/list` (distribution spec, with `n`/`last` paging),
  and the layer views `GET /api/v1/layers/<pipeline>[/<run>]`. The README
  names them in the same section as FL-01 and FL-10, so a reader finds all
  listings in one place.

## 4. Common rules

- **FL-30** Rights: `read`, like a download. With `auth.anonymous: read` the
  listing is anonymous like the files themselves; a listing never shows a
  file the caller could not download.
- **FL-31** Results are deterministic: the same store gives the same bytes
  (stable sort, ties broken by path or version).
- **FL-32** A listing walks the store directories; it does not build or keep
  an index. Its cost grows with the subtree asked for, which is why `prefix`
  exists and why `limit` is capped.

## 5. Tests

- **FL-40** `tests/listing.sh` (e2e against the built `./kontor`, like
  `e2e.sh`): a tree of generic files over several runs and commits; FL-01
  shape; FL-02 each parameter (non-recursive with `dirs`, recursive, `match`
  with `*` and `**`, `sort=published` with ties, paging and `total`, bad
  prefix `400`, missing prefix `404`, limit capped); FL-03 as written; FL-04
  trailing slash lists and no-slash stays `404`; FL-05 hint; FL-10/FL-11
  including a tombstoned version and `match`; anonymous `401` when
  `auth.anonymous` is `none` and `200` when it is `read` (FL-30).
- **FL-41** `tests/run_all.sh` runs it.
