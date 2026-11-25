#!/bin/bash
# Docs-only skip in commit-evidence-gate: .md/.txt-only changes need no test evidence.
H="$(cd "$(dirname "$0")/.." && pwd)/hooks/commit-evidence-gate.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cegate.XXXXXX"); export COMMIT_GATE_LOG="$T/commit-gate.log"
R="$T/repo"; mkdir "$R"; cd "$R" && git init -q
run() { jq -nc --arg c 'git commit -m "x" -m "Deviations: none"' '{tool_input:{command:$c}}' | bash "$H" 2>&1; }
echo a > README.md; echo b > notes.txt
out=$(run); [ -z "$out" ]                          && echo "ok  docs-only commit skips test check" || echo "FAIL docs-only: $out"
grep -q 'docs-only' "$COMMIT_GATE_LOG"             && echo "ok  docs-only skip is logged"         || echo "FAIL docs-only log"
echo c > app.py
run | grep -q 'No test evidence'                   && echo "ok  one code file keeps the gate on"  || echo "FAIL code file"
rm app.py; git -c user.name=t -c user.email=t@example.com add -A >/dev/null
run | grep -q '"block"'                            && echo "FAIL staged docs blocked"             || echo "ok  staged docs-only skips"
rm -rf "$T"
