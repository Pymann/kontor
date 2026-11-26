# kontor running transfers — specification

Status: implemented (2026-11-26).  Requirement ids are `TR-<n>`.

kontor tells whether data is moving right now: an upload (upstream — a CI
job publishing a package, a generic file, an image) or a download
(downstream — an install, a pull).  Scripts ask the API; the web UI shows it.

## 1. What counts

- **TR-01** An **upload** is a `PUT`/`PATCH`/`POST` with a body on an
  artifact route: `/exodus/…/exodus.json`, `/exodus/…/package`,
  `/generic/…`, `/v2/…` (and their `/api/v1/` aliases).  A request without a
  body (the `POST` that opens an OCI upload session) is none.
- **TR-02** A **download** is a `GET` on an artifact route that answers with
  a stored file: `/exodus/…/exodus.json`, `/exodus/…/package`,
  `/generic/…`, `/v2/…` blobs and manifests.  Errors (`401`, `404`, …),
  directory listings and the web UI's own files are none.
- **TR-04** `HEAD` is no download (no body moves).
- **TR-05** Phases:
  - `receiving` (upload): the HTTP runtime reads the body into its spool
    file below `<data>/tmp/spool/`.  kontor's handler has not started yet,
    so method, path and user are `null`; `bytes` is what has arrived so far.
  - `storing` (upload): the body is complete; kontor checks and stores it.
    `bytes` is the body's size; `user` is `null` (authorization runs inside
    the handler).
  - `sending` (download): the file is being streamed; `bytes` is its size,
    `user` the authorized caller.
- **TR-06** A download's file is streamed after the handler released
  kontor's global lock, so the status endpoint (and every other request)
  answers while it runs.

## 2. API

- **TR-10** `GET /api/v1/transfers` (alias `/api/transfers`) answers `200`
  with `Cache-Control: no-store`:

  ```json
  {
    "active": true,
    "uploads": 1,
    "downloads": 1,
    "transfers": [
      {"id": "spool-Ab12Cd", "direction": "upload", "phase": "receiving",
       "method": null, "path": null, "user": null,
       "bytes": 4194304, "started_ms": 1795700129488, "elapsed_ms": 812},
      {"id": "7", "direction": "download", "phase": "sending",
       "method": "GET", "path": "/exodus/lib-a/1.0.0/package", "user": "ci",
       "bytes": 30000000, "started_ms": 1795700134464, "elapsed_ms": 994}
    ],
    "completed": {"uploads": 12, "downloads": 40},
    "last_activity_ms": 1795700134464,
    "now_ms": 1795700135458
  }
  ```

  `active` is `uploads + downloads > 0`.  `completed` counts finished
  transfers since kontor started (receiving uploads count once they are
  stored).  `last_activity_ms` is the last start or end of a transfer, `null`
  before the first.  For a `receiving` upload `started_ms` is when kontor
  first saw it (aiml has no file mtime), so it can be late by up to one poll.
- **TR-12** It needs the `read` right (anonymous callers get it when
  `auth.anonymous` grants it, as for the catalog).
- **TR-13** A script that waits for kontor to be quiet (before a backup, a
  restart):

  ```bash
  until curl -fsS "$KONTOR/api/v1/transfers" | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["active"])'; do sleep 5; done
  ```

## 3. Web UI

- **TR-30** The header shows "Idle: no uploads or downloads" or
  "Active: <n> uploading, <m> downloading"; the overview lists every running
  transfer (direction, path, size, phase, user).  The UI polls every 3 s
  while the caller has the `read` right; a failed poll leaves the message line
  alone.

## 4. Tests

`tests/transfers.sh` (rate-limited curl uploads and downloads against a
scratch kontor), `tests/ui_logic.aiml` (the UI store's poll).
