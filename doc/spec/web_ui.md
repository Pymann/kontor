# kontor web UI — specification

Status: **DRAFT** (2026-11-25). Spec first, then tests, then implementation.
Where this chapter and the implementation disagree, this chapter wins.

kontor serves a WebAssembly application from its own HTTP port. With it a
person configures kontor from the browser — users and tokens, retention
times, a few runtime settings — and gets a human-readable overview of what
kontor holds and what can be installed from it.

Requirement ids are `FW-<n>`. "UI" is the browser application, "backend" is
`kontor` itself.

## 1. Scope

In scope:

- **FW-01** Overview (catalog) of everything kontor stores: exodus projects
  and their versions (aiml tools among them), generic files, OCI
  repositories and tags, cosmos layer runs.
- **FW-02** User and token management (local users; tokens of every
  identity source).
- **FW-03** Retention: policies, a dry run that shows what a policy would
  delete, an on-demand run, a scheduled run, and the log of past runs.
- **FW-04** Runtime settings: anonymous role, public URL, custom roles.
- **FW-05** Every UI action is an ordinary REST call that a script can make
  too. The UI has no private API and no rights beyond the caller's.

Out of scope for this chapter (later chapters): webhook administration in
the UI (the REST API stays), LDAP/SAML configuration from the UI (secrets
stay in files), translations (UI texts are English), uploads from the
browser.

## 2. Delivery

- **FW-10** `GET /ui/` and everything below it is the UI, served from a
  directory of static files: `index.html`, `kontor-ui.js`, `kontor-ui.wasm`
  (and whatever else the build emits). `GET /` redirects (`302`) to `/ui/`.
  `GET /ui` redirects to `/ui/`.
- **FW-11** The directory is `--ui-dir <path>` or `$KONTOR_UI_DIR`; the
  default is `../share/kontor/ui` relative to the binary (where
  `aiml venv install` places it), then `./ui/dist`. Without a UI directory
  kontor runs as before and `/ui/` answers `404`
  `{"error":"the web UI is not installed (--ui-dir)","code":"not_found"}`.
- **FW-12** The UI files need no authorization (they hold no data); every
  data request the UI makes is authorized as usual.
- **FW-13** Caching: `index.html` is sent with `Cache-Control: no-cache`;
  the other files with an `ETag` (the sha256 of the file) and answer a
  matching `If-None-Match` with `304`. `.wasm` is `application/wasm`.
- **FW-14** Security headers on every `/ui/` response:
  `Content-Security-Policy: default-src 'self'; script-src 'self' 'wasm-unsafe-eval'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; frame-ancestors 'none'`,
  `X-Content-Type-Options: nosniff`, `Referrer-Policy: no-referrer`.
- **FW-15** Path traversal: a path that leaves the UI directory (`..`,
  encoded or not, or a symlink pointing out) is `404`.

## 3. Login and sessions

The UI never stores a password. It works with **session tokens**: API tokens
with an expiry, the same kind SAML logins already mint.

- **FW-20** `POST /api/v1/sessions` with HTTP Basic `user:password` (local
  or LDAP) answers `201`
  `{"id","owner","roles","token":"<id>:<secret>","expires_ms"}`. The expiry is
  `auth.session_hours` (default 12). Wrong credentials: `401`, with the same
  delay and message whether the user exists or not. A token as the Basic
  password is refused here (`400`): a session is made from a login, not from
  a token.
- **FW-21** SAML: the UI's "Sign in with SSO" button goes to
  `/api/v1/sso/saml/login?relay=/ui/`; the existing ACS answers with a
  `302` to `/ui/#token=<id>:<secret>`. The UI takes the token out of the
  fragment and removes the fragment from the address bar
  (`history.replaceState`).
- **FW-22** The UI keeps the token in memory and in `sessionStorage` (so a
  reload in the same tab stays signed in, a new tab does not). No cookies:
  every request carries `Authorization: Bearer <token>`, so there is no CSRF
  surface.
- **FW-23** "Sign out" is `DELETE /api/v1/tokens/<id>` on the session token,
  then the UI forgets it. A `401` on any call returns the UI to the login
  screen with "Your session has ended".
- **FW-24** Anonymous use: when `auth.anonymous` grants `read`, the UI opens
  on the overview without a login; the login button stays in the header.
  When it is `none`, the UI opens on the login screen.
- **FW-25** The UI shows a section only when `GET /api/v1/whoami` lists the
  right for it (overview: `read`; users, retention, settings: `admin`).
  Hiding is a convenience — the backend still checks every call (FW-05).
- **FW-26** Expired session tokens are swept: the retention run (§5) deletes
  token files whose `expires_ms` has passed (closes the open point in the
  README "expired token files are not swept").

## 4. Overview (catalog)

- **FW-30** `GET /api/v1/catalog` (right `read`) answers
  ```json
  {
    "kontor": {"public_url": "…", "version": "0.2.0", "disk_bytes": 123, "blob_count": 45},
    "exodus":  [{"name","newest","versions":3,"bytes","tool":true,"updated_ms"}],
    "generic": {"files": 12, "bytes": 3456},
    "oci":     [{"repository","tags":4,"bytes","updated_ms"}],
    "layers":  [{"pipeline","runs":7,"updated_ms"}]
  }
  ```
  `tool` is true when the newest package carries an `aiml.tool.json`
  (aiml spec/68 F68-66), i.e. `aiml venv install` can install it.
- **FW-31** `GET /api/v1/catalog/exodus/<name>` (right `read`): every
  version, newest first in version order (spec/68's ordering), each
  `{"version","published_ms","publisher","sha256","bytes","protected","dependencies":[…],"dependents":[…]}`,
  plus `"install": "aiml venv <dir> install <name> --kontor <public_url> --version <v>"`.
  `dependents` are the projects whose newest manifest depends on this name.
- **FW-32** `GET /api/v1/catalog/generic?prefix=<p>` (right `read`): the
  directory listing below `<p>`: `{"dirs":[…],"files":[{"name","bytes","sha256","published_ms","publisher"}]}`.
- **FW-33** `GET /api/v1/catalog/oci/<repository>` (right `read`): tags
  with digest, media type, size and `published_ms`.
- **FW-34** Publish metadata: from this chapter on, every successful
  publish (generic PUT, exodus manifest/package PUT, OCI manifest PUT)
  writes `published_ms` and `publisher` (the principal's name) next to the
  object. Objects from before have `published_ms` from the file's mtime and
  `publisher: null`.
- **FW-35** The UI's overview: one table per repository type with a text
  filter; a project row opens its version list (FW-31) with the dependency
  edges, the rebuild impact (`/api/v1/impact`) and the install command with a
  copy button. Sizes are shown human-readable (KiB/MiB/GiB, base 1024),
  times as local date and time plus "3 days ago".

## 5. Retention

Retention is **opt-in**: without a policy nothing is ever deleted.

### 5.1 Policies

- **FW-40** Policies live in `data/config/retention.yaml` and are read and
  written through `GET`/`PUT /api/v1/retention` (right `admin`; `PUT`
  validates the whole document and replaces it; invalid → `400` with the
  first error and its path, nothing written).
  ```yaml
  schedule: "03:00"          # UTC, daily; "" = only on demand
  rules:
    - repo: exodus           # exodus | generic | oci
      match: "*"             # glob over the project name / generic path / OCI repository
      keep_last: 10          # newest N versions (exodus), tags (oci); optional
      max_age_days: 180      # delete what is older; optional
    - repo: generic
      match: "ci-cache/**"
      max_age_days: 14
    - repo: oci
      match: "cosmos-layers/*"
      keep_last: 20
      untagged_after_days: 2 # manifests without a tag
  ```
- **FW-41** The **first** rule whose `repo` and `match` fit an object
  decides; an object no rule fits is kept. A rule needs at least one of
  `keep_last`, `max_age_days`, `untagged_after_days`. With both `keep_last`
  and `max_age_days` a version is deleted only when it is outside the newest
  N **and** older than D days.
- **FW-42** **Never deleted**, whatever the rules say:
  1. the newest version of every exodus project and the newest tag of every
     OCI repository;
  2. an exodus version that the newest manifest of another project depends
     on with exactly that version;
  3. an object marked protected — `PUT /api/v1/protect/<repo>/<name>/<version>`
     / `DELETE …` (right `admin`); for generic `<name>` is the path.
  A dry run lists these as `kept` with the reason (`newest`, `dependency`,
  `protected`).
- **FW-43** Age is `now − published_ms` (FW-34).

### 5.2 Running

- **FW-44** `POST /api/v1/retention/preview` (right `admin`, optional body:
  a policy document to try instead of the stored one) answers
  `{"delete":[{"repo","name","version","bytes","rule"}],"kept":[{…,"reason"}],"bytes":N}`
  and changes nothing.
- **FW-45** `POST /api/v1/retention/run` (right `admin`) applies the stored
  policy and answers `202 {"run":"<id>"}`; the run happens on its own
  thread, under the store lock per deleted object, so uploads keep working.
  One run at a time: a second one while it runs is `409`.
- **FW-46** A run deletes the selected objects, then sweeps unreferenced CAS
  blobs (mark and sweep over every manifest, package, generic file and OCI
  manifest; a blob younger than 24 hours is kept, so an upload in progress
  is not hit), then expired session tokens (FW-26).
- **FW-47** Every deleted version leaves a **tombstone**: `GET` answers
  `410 {"code":"gone"}`, and a new `PUT` of the same version stays `409` —
  a version number is never reused (reproducibility, matching "a published
  version is not overwritten"). Exodus deletes remove the version from the
  graph; if it was the newest, the graph is reloaded.
- **FW-48** Each deletion emits the webhook event `artifact.deleted`
  `{"repo","name","version","reason":"retention"|"manual"}`.
- **FW-49** `GET /api/v1/retention/runs` (right `admin`): the last 50 runs,
  `{"run","started_ms","finished_ms","trigger":"schedule"|"manual","by","deleted","bytes_freed","errors":[…]}`.
- **FW-50** Manual delete outside retention:
  `DELETE /exodus/<name>/<version>` (right `delete`) — the same tombstone,
  protection and event rules; `409` for a version FW-42 protects, with the
  reason.

### 5.3 In the UI

- **FW-51** The retention page edits the rules as a list (add, remove, move
  up/down, fields per rule), shows "Preview" (FW-44 with the edited,
  unsaved document) as a table of what would go and how many bytes are
  freed, then "Save" and "Run now". The run log is a table below.

## 6. Settings

- **FW-60** `GET`/`PUT /api/v1/settings` (right `admin`):
  `{"public_url","anonymous","session_hours","roles":{"ci":["read","write"]}}`.
  Stored in `data/config/settings.yaml`; a key set there **overrides** the
  same key of `kontor.yaml` (which stays the file an operator writes by
  hand, with its comments). `GET` also says where each value comes from:
  `"source":{"anonymous":"settings"|"kontor.yaml"|"default", …}`.
- **FW-61** Changes take effect for the next request, without a restart.
- **FW-62** Guard rails: built-in roles cannot be redefined; a role in use
  by a user or token cannot be removed (`409`, naming who uses it); the last
  user with `admin` cannot lose it or be deleted (`409`) — the bootstrap
  token does not count as that user.

## 7. Users and tokens in the UI

- **FW-70** Users page: table of users (name, source, roles), "New user"
  (name, password twice, roles as checkboxes from the known roles), "Change
  roles", "Reset password", "Delete" with confirmation. Uses the existing
  `/api/v1/users` endpoints; `POST` replaces, so the UI sends the full user.
  LDAP/SAML users are shown read-only (their roles come from groups).
- **FW-71** Tokens page: own tokens (admin: all) with label, owner, roles,
  created, expiry; "New token" shows the secret **once** with a copy button
  and a warning; "Revoke" with confirmation.
- **FW-72** Password field input is masked; the UI never logs request
  bodies.

## 8. The UI program

Toolchain: **aiml → wasm32** (decided 2026-11-25 by the owner). The UI is
an aiml program, `ui/kontor_ui.aiml`, drawn with aiml's UI widgets
(aiml spec/44_3) on a canvas and compiled with aiml's wasm32 target
(emscripten, the frame loop of aiml `doc/wasm_frame_loop.md`).

- **FW-80** Source in `ui/`, build output in `ui/dist/` (not committed).
  The UI is built in kontor's CI and shipped in the same release/venv
  install as the binary (`share/kontor/ui`).
- **FW-81** The UI's state and API client are a layer of their own,
  separate from drawing, so they can be tested without a browser (§9).
- **FW-82** Works in the current Firefox and Chromium at 1280×800 and down
  to 800 px width; keyboard navigation through every form (Tab, Enter,
  Escape closes a dialog).
- **FW-83** Size budget: the wasm file ≤ 3 MiB gzip-compressed; first
  render ≤ 2 s on a local network.

It needs from aiml (tracked there, spec first):

- **FW-90** `http.fetch(method, url, headers: map<string,string>, body: string)`
  → `{status: i32, body: string, headers}` on wasm32 (`window.fetch`) and
  natively (http client) — today only `http.fetch_text` (GET, body only)
  exists (spec/32_2).
- **FW-91** A masked mode for `ui.text_input` (password fields), and
  clipboard write for copy buttons on wasm32.
- **FW-92** The aiml release carries the wasm32 runtime (`libaiml_wasm.a`)
  and names the emsdk version it was built with, so kontor's CI builds the
  UI out of the aiml release like it builds the binary.
- **FW-93** Browser hooks for `sessionStorage` get/set and reading/clearing
  the URL fragment (FW-21, FW-22).

## 9. Tests

- **FW-100** `tests/test_retention.aiml` (unit): the selection function —
  versions with dates, dependencies and protections in, delete/kept sets out
  — covers FW-41, FW-42 (all three reasons), FW-43, the `keep_last` +
  `max_age_days` conjunction and "no rule → kept".
- **FW-101** `tests/webui.sh` (e2e against the built `./kontor`, like
  `e2e.sh`): static delivery (FW-10…FW-15, incl. traversal and the
  missing-UI case), sessions (FW-20, FW-23, FW-26), catalog (FW-30…FW-34),
  retention preview/run/tombstones/events/log (FW-44…FW-50), settings and
  guard rails (FW-60…FW-62), and a `403` for every admin endpoint called
  with a `reader` token.
- **FW-102** UI logic test, without a browser: the UI's state/API layer
  (FW-81), run natively by the compiler against a running kontor: log in, list the catalog, create a user,
  edit a retention rule and preview it, sign out.
- **FW-103** Browser smoke test in CI (headless Chromium, Playwright):
  `/ui/` loads with no console errors and no CSP violations, login works,
  the overview lists a published project.
- **FW-104** CI: `tests/run_all.sh` runs FW-100 and FW-101; a `web-ui` job
  builds the UI and runs FW-102 and FW-103.

## 10. Order of work

1. Backend (§3–§7 endpoints) with FW-100/FW-101 — independent of the UI
   toolchain.
2. aiml prerequisites FW-90…FW-93.
3. The UI (§8) with FW-102/FW-103.

## Open points

- Whether tombstones (FW-47) should be purgeable by an admin to allow a
  version number to be reused.
