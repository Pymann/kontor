#!/usr/bin/env bash
# Fetch a prebuilt aiml (compiler + runtime) from Pymann/aiml and make a venv
# of it (aiml spec/68), so that every exodus.json here finds $AIML and
# $AIML_VENV/lib (F68-23).
#
# Source of the binary, first that works:
#   0. kontor, when AIML_KONTOR_URL is set: the venv bundle aiml's own CI puts
#      there (aiml .github/workflows/ci.yml, "Put the bundle into kontor"):
#        <kontor>/generic/aiml/<key>/aiml-x86_64-linux.tar.gz   (bin/ lib/ env)
#      <key> is AIML_RELEASE (a v* tag, or a commit sha), else `latest` (moved
#      by every v* tag run).  kontor answers with X-Checksum-Sha256; the
#      download is checked against it.  Needs curl only, no GitHub token.
#        AIML_KONTOR_CA      PEM text of kontor's CA (kontor uses its own CA)
#        AIML_KONTOR_TOKEN   only if kontor refuses anonymous reads
#        AIML_KONTOR_STRICT  1 = fail instead of falling back to GitHub
#   1. the release named by AIML_RELEASE (e.g. v1.0.2.4), else the newest
#      published release, prereleases included (drafts are not visible here);
#   2. the aiml-linux-x86_64 artifact of the newest green CI run on master.
# 1. and 2. come with a .sha256 and are checked against it.
#
# Usage: setup-aiml.sh <venv-dir>      (1. and 2. need GH_TOKEN for the gh CLI)
set -euo pipefail

VENV="${1:?venv dir}"
REPO="${AIML_REPO:-Pymann/aiml}"
DL="$(mktemp -d)"
PKG=""

from_kontor() {
    local url="${AIML_KONTOR_URL%/}" key="${AIML_RELEASE:-latest}" curl_args want got
    curl_args=(-fsS --retry 3 --connect-timeout 15 --max-time 1800)
    [[ "$key" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "kontor: unusable key '$key'"; return 1; }
    if [ -n "${AIML_KONTOR_CA:-}" ]; then
        printf '%s\n' "$AIML_KONTOR_CA" > "$DL/kontor-ca.pem"
        curl_args+=(--cacert "$DL/kontor-ca.pem")
    fi
    if [ -n "${AIML_KONTOR_TOKEN:-}" ]; then
        (umask 077; printf 'Authorization: Bearer %s\n' "$AIML_KONTOR_TOKEN" > "$DL/kontor.hdr")
        curl_args+=(-H @"$DL/kontor.hdr")
    fi
    curl "${curl_args[@]}" -D "$DL/kontor.head" -o "$DL/bundle.tar.gz" \
        "$url/generic/aiml/$key/aiml-x86_64-linux.tar.gz" || return 1
    rm -f "$DL/kontor-ca.pem" "$DL/kontor.hdr"
    want="$(tr -d '\r' < "$DL/kontor.head" | sed -n 's/^[Xx]-[Cc]hecksum-[Ss]ha256: *//p' | tail -1)"
    got="$(sha256sum "$DL/bundle.tar.gz" | cut -d' ' -f1)"
    [[ "$want" =~ ^[0-9a-f]{64}$ ]] || { echo "kontor: no X-Checksum-Sha256 in the answer"; return 1; }
    [ "$want" = "$got" ] || { echo "kontor: sha256 $got, kontor says $want"; return 1; }
    mkdir -p "$DL/kontor-pkg"
    tar -xzf "$DL/bundle.tar.gz" -C "$DL/kontor-pkg"
    rm -f "$DL/bundle.tar.gz"
    [ -x "$DL/kontor-pkg/bin/aiml" ] && [ -f "$DL/kontor-pkg/lib/libaiml.so" ] \
        || { echo "kontor: bundle has no bin/aiml and lib/libaiml.so"; return 1; }
    PKG="$DL/kontor-pkg"
    echo "aiml: kontor $url ($key, sha256 $got)"
}

if [ -n "${AIML_KONTOR_URL:-}" ]; then
    if from_kontor; then
        :
    elif [ "${AIML_KONTOR_STRICT:-0}" = "1" ]; then
        echo "::error::aiml not available from kontor $AIML_KONTOR_URL"; exit 1
    else
        echo "::warning::aiml not available from kontor $AIML_KONTOR_URL -- falling back to GitHub"
        rm -rf "${DL:?}"/*
    fi
fi

if [ -z "$PKG" ]; then
    tag="${AIML_RELEASE:-}"
    if [ -z "$tag" ]; then
        tag="$(gh release list -R "$REPO" --exclude-drafts -L 1 --json tagName -q '.[0].tagName' 2>/dev/null || true)"
    fi
    if [ -n "$tag" ] && gh release download "$tag" -R "$REPO" -p 'aiml-*-linux-x86_64.tar.gz*' -D "$DL"; then
        echo "aiml: release $tag"
    elif [ -n "${AIML_RELEASE:-}" ]; then
        echo "::error::aiml release $AIML_RELEASE has no linux-x86_64 tarball"; exit 1
    else
        run="$(gh run list -R "$REPO" -w CI -b master -s success -L 1 --json databaseId -q '.[0].databaseId')"
        [ -n "$run" ] || { echo "::error::no release and no green CI run in $REPO"; exit 1; }
        gh run download "$run" -R "$REPO" -n aiml-linux-x86_64 -D "$DL"
        echo "aiml: CI run https://github.com/$REPO/actions/runs/$run"
    fi
    (cd "$DL" && sha256sum -c ./*.tar.gz.sha256)
    tar -xzf "$DL"/aiml-*-linux-x86_64.tar.gz -C "$DL"
    PKG="$(echo "$DL"/aiml-*-linux-x86_64/)"
fi

# `aiml venv` copies the compiler and the runtime only (F68-10); the pinned
# libraries the tarball bundles next to them have to come along, or bin/aiml
# (RUNPATH $ORIGIN/../lib) no longer finds them.
"$PKG/bin/aiml" venv "$VENV"
cp --update=none "$PKG"/lib/*.so* "$VENV/lib/"

# A venv made from this one by `aiml venv <dir>` (ufo's venv_layer.sh does
# that) gets compiler and runtime only, without the bundled libraries, and
# then needs them from the system -- as on a developer machine, where they are
# installed with apt.  On the runner the tarball's copies play that part.
if [ -n "${GITHUB_ACTIONS:-}" ]; then
    sudo mkdir -p /usr/local/lib/aiml-bundle
    # `install`, not `cp`: it replaces a file instead of writing into it, so a
    # second run does not overwrite libraries that running processes (sudo
    # itself) have mapped -- that segfaulted (cosmos doc/spec/112 §112.7).
    sudo find "$PKG/lib" -maxdepth 1 -name 'lib*.so*' ! -name 'libaiml.so' -exec install -m 0644 {} /usr/local/lib/aiml-bundle/ \;
    echo /usr/local/lib/aiml-bundle | sudo tee /etc/ld.so.conf.d/aiml-bundle.conf > /dev/null
    sudo ldconfig
fi

# shellcheck disable=SC1091
. "$VENV/env"
missing="$(ldd "$AIML" "$AIML_VENV/lib/libaiml.so" | grep 'not found' || true)"
[ -z "$missing" ] || { echo "unresolved libraries:"; echo "$missing"; exit 1; }

# Smoke test, away from any checkout: a program whose exit code is its own.
probe="$(mktemp -d)"
printf -- '- call: [sys.exit, 42]\n' > "$probe/smoke.aiml"
set +e; (cd "$probe" && "$AIML" smoke.aiml); rc=$?; set -e
[ "$rc" -eq 42 ] || { echo "::error::aiml smoke test exited $rc, expected 42"; exit 1; }

if [ -n "${GITHUB_ENV:-}" ]; then
    { echo "AIML_VENV=$AIML_VENV"; echo "AIML=$AIML"; echo "AIML_BIN=$AIML"; } >> "$GITHUB_ENV"
    echo "$AIML_VENV/bin" >> "$GITHUB_PATH"
fi
echo "aiml venv ready at $AIML_VENV"
