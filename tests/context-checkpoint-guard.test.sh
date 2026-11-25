#!/bin/bash
# context-checkpoint-guard: fires once per project per session, skips CHECKPOINT_SKIP folders,
# counts a CONTEXT.md write as a checkpoint, ignores paths outside the root.
H="$(cd "$(dirname "$0")/.." && pwd)/hooks/context-checkpoint-guard.py"
T=$(mktemp -d "${TMPDIR:-/tmp}/ccguard.XXXXXX")
mkdir -p "$T/p/demo" "$T/p/done" "$T/p/skipme"
export CHECKPOINT_ROOT="$T/p" CHECKPOINT_SKIP=skipme CHECKPOINT_LOG="$T/log/guard.log"
mkdir -p "$T/log"
w() { printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"%s"}}]}}\n' "$1"; }
{ w "$T/p/demo/a.md"; w "$T/p/skipme/x.ts"; w "$T/p/done/b.md"; w "$T/p/done/CONTEXT.md"; w "/etc/hosts"; } > "$T/t.jsonl"
run() { printf '{"transcript_path":"%s","session_id":"%s"}' "$T/t.jsonl" "$1" | python3 "$H"; }
out=$(run s1)
printf '%s' "$out" | grep -q '"block"' && printf '%s' "$out" | grep -q "p/demo" \
                                         && echo "ok  unchecked project blocks"     || echo "FAIL block"
printf '%s' "$out" | grep -q "p/done"    && echo "FAIL checkpointed project named" || echo "ok  CONTEXT.md write counts"
printf '%s' "$out" | grep -q "skipme"    && echo "FAIL skip list ignored"          || echo "ok  skip list honored"
[ -z "$(run s1)" ]                       && echo "ok  second stop is silent"        || echo "FAIL fired twice"
[ -n "$(run s2)" ]                       && echo "ok  new session fires again"      || echo "FAIL new session"
printf '{"stop_hook_active":true,"transcript_path":"%s"}' "$T/t.jsonl" | python3 "$H" | grep -q . \
                                         && echo "FAIL ran inside its own block"    || echo "ok  stop_hook_active skipped"
rm -rf "$T"
