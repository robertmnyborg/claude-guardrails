#!/bin/bash
# Deviation-line check in commit-evidence-gate. Uses --no-verify so only the deviation
# check runs (the test-evidence check is skipped after it).
H="$(cd "$(dirname "$0")/.." && pwd)/hooks/commit-evidence-gate.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/cegate.XXXXXX"); export COMMIT_GATE_LOG="$T/commit-gate.log"; cd "$T" && git init -q
printf 'subject\n\nDeviations: none\n' > ok.txt; printf 'subject\n' > bad.txt
run() { jq -nc --arg c "$1" '{tool_input:{command:$c}}' | CLAUDE_COMMIT_GATE="${2:-block}" bash "$H" 2>&1; }
blocks() { run "$1" | grep -q 'no `Deviations:` line'; }
passes() { [ -z "$(run "$1")" ]; }
blocks 'git commit --no-verify -m "fix"'                         && echo "ok  missing line blocks"      || echo "FAIL missing"
passes 'git commit --no-verify -m "fix" -m "Deviations: none"'   && echo "ok  none passes"              || echo "FAIL none"
passes "git commit --no-verify -m \"\$(cat <<'EOF'
fix

Deviations: cut retry path, filed T-12
EOF
)\""                                                             && echo "ok  heredoc line passes"      || echo "FAIL heredoc"
blocks 'git commit --no-verify -m "x" -m "Deviations: "'         && echo "ok  empty value blocks"       || echo "FAIL empty"
blocks 'git commit -am "x"'                                      && echo "ok  -am checked"              || echo "FAIL -am"
passes "git commit --no-verify -F $T/ok.txt"                     && echo "ok  -F file with line"        || echo "FAIL -F ok"
blocks "git commit --no-verify -F $T/bad.txt"                    && echo "ok  -F file without line"     || echo "FAIL -F bad"
passes 'git commit --amend --no-edit'                            && echo "ok  unreadable msg skipped"   || echo "FAIL amend"
out=$(run 'git commit --no-verify -m "x"' warn); printf '%s' "$out" | grep -q '⚠' && ! printf '%s' "$out" | grep -q '"block"' \
                                                                 && echo "ok  warn mode does not block" || echo "FAIL warn"
passes 'git status'                                              && echo "ok  non-commit ignored"       || echo "FAIL non-commit"
rm -rf "$T"
