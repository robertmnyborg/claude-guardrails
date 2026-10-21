#!/bin/bash
# Visual check in commit-evidence-gate: warn/block/escape/opt-in/freshness.
H="$(cd "$(dirname "$0")/.." && pwd)/hooks/commit-evidence-gate.sh"
T=$(mktemp -d); export VISUAL_GATE_LOG="$T/visual-gate.log"; cd "$T" && git init -q && git -c commit.gpgsign=false -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
echo '{"cmd":"true","exit":0,"sha256":"x"}' > .claude-verified       # fresh passing test evidence
mkdir -p .claude && echo '{"base_url":"http://x"}' > .claude/visual.json
echo 'x' > App.tsx && git add App.tsx
run() { printf '{"tool_input":{"command":"git commit -m \\"%s\\""}}' "$1" | CLAUDE_VISUAL_GATE=$2 bash "$H" 2>&1; }
run msg warn  | grep -q 'visual evidence is missing' && echo "ok  warn mode reports missing" || echo "FAIL warn"
run msg block | grep -q '"block"'                    && echo "ok  block mode blocks"        || echo "FAIL block"
out=$(run '[no-visual] types' block); [ -z "$out" ]  && echo "ok  [no-visual] escapes"     || echo "FAIL escape"
mkdir -p .claude-visual && printf '{"head":"%s"}' "$(git rev-parse HEAD)" > .claude-visual/marker.json
touch -t 202001010000 .claude-visual/marker.json
run msg block | grep -q 'stale-edit'                 && echo "ok  edit after shots is stale" || echo "FAIL stale-edit"
touch .claude-visual/marker.json
out=$(run msg block); [ -z "$out" ]                  && echo "ok  fresh evidence passes"     || echo "FAIL fresh: $out"
rm .claude/visual.json
out=$(run msg block); [ -z "$out" ]                  && echo "ok  no visual.json = no check" || echo "FAIL opt-in"
rm -rf "$T"
