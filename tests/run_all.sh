#!/bin/bash
# Runs the unit tests and the end-to-end tests.
#   AIML_BIN=/path/to/aiml tests/run_all.sh
cd "$(dirname "$0")/.."
AIML_BIN="${AIML_BIN:-aiml}"
FAILS=0
for t in tests/test_*.aiml; do
    OUT=$("$AIML_BIN" "$t" 2>&1); RC=$?
    echo "$OUT" | grep -v WARNING | tail -1
    [ $RC -eq 0 ] || { echo "FAIL $t"; FAILS=$((FAILS + 1)); }
done
AIML_BIN="$AIML_BIN" tests/e2e.sh || FAILS=$((FAILS + 1))
AIML_BIN="$AIML_BIN" tests/ecosystem.sh || FAILS=$((FAILS + 1))
AIML_BIN="$AIML_BIN" tests/identity.sh || FAILS=$((FAILS + 1))
exit $FAILS
