#!/bin/bash
# Builds kontor's web UI (doc/spec/web_ui.md §8) into ui/dist/:
# index.html, boot.js, kontor-ui.js, kontor-ui.wasm.
#
#   ui/build.sh                  needs $AIML_VENV (an aiml venv whose
#                                lib/wasm32 holds the wasm32 runtime, aiml
#                                spec/68 §8) and emcc on PATH or $EMCC, of the
#                                emsdk version in lib/wasm32/emsdk.version
set -euo pipefail
cd "$(dirname "$0")"
: "${AIML_VENV:?AIML_VENV: an aiml venv (. <venv>/env)}"
AIML="${AIML:-$AIML_VENV/bin/aiml}"
EMCC="${EMCC:-emcc}"
WASM_LIB="$AIML_VENV/lib/wasm32"
[ -f "$WASM_LIB/libaiml_wasm.a" ] || { echo "no wasm32 runtime in $WASM_LIB (aiml spec/68 F68-94)"; exit 1; }
want="$(cat "$WASM_LIB/emsdk.version")"
"$EMCC" --version | head -1 | grep -qF "$want" \
    || { echo "emcc is not emsdk $want: $("$EMCC" --version | head -1)"; exit 1; }

OUT="${UI_DIST:-dist}"
BUILD="$(mktemp -d)"
trap 'rm -rf "$BUILD"' EXIT
rm -rf "$OUT"; mkdir -p "$OUT"

"$AIML" main.aiml --target wasm32 --emit-main -o "$BUILD/kontor-ui.ll"
# The imports (kontor_ui.aiml, ../lib/text.aiml) come out as .ll files of
# their own next to the main one; all of them go into the link.
"$EMCC" "$BUILD"/*.ll -o "$OUT/kontor-ui.js" \
    -L"$WASM_LIB" -laiml_wasm -fexceptions -O2 \
    -sASYNCIFY=1 -sASYNCIFY_STACK_SIZE=1048576 -sSTACK_SIZE=8388608 \
    -sALLOW_MEMORY_GROWTH=1 -sENVIRONMENT=web \
    -sMAX_WEBGL_VERSION=2 -sMIN_WEBGL_VERSION=2 -sFULL_ES3=1
cp web/index.html web/boot.js "$OUT/"

size=$(gzip -c "$OUT/kontor-ui.wasm" | wc -c)
echo "ui/$OUT: kontor-ui.wasm $(stat -c %s "$OUT/kontor-ui.wasm") bytes, $size gzip-compressed"
# FW-83: at most 3 MiB compressed.
[ "$size" -le $((3 * 1024 * 1024)) ] || { echo "FW-83: wasm over 3 MiB gzip-compressed"; exit 1; }
