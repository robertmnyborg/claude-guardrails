#!/usr/bin/env bash
# commit-evidence-gate — PreToolUse(Bash) hook.
# Enforces "replace trust with evidence" (Nick Nisi / WorkOS): a `git commit` is
# only allowed when a fresh, cryptographically-verified test-evidence marker
# exists for the repo. The agent can't just *say* it ran tests — it has to have
# run `prove-tests`, which SHA-256s the real test output into .claude-verified.
#
# Modes (env CLAUDE_COMMIT_GATE), read from THIS hook's environment — i.e. the
# Claude Code process env. Prefixing the git command (`CLAUDE_COMMIT_GATE=off git
# commit ...`) sets it for git, not for this hook, and has no effect.
#   block (default) — missing/stale evidence blocks the commit
#   warn            — missing/stale evidence prints an advisory, commit proceeds
#   off             — no-op
#
# Per-commit escape hatch that DOES work from the command line: --no-verify
# (also --amend). Intended for repos with no tests to run at all.
#
# Reads the PreToolUse JSON payload on stdin: { tool_input: { command } }.
set -uo pipefail
MODE="${CLAUDE_COMMIT_GATE:-block}"
[ "$MODE" = "off" ] && exit 0

PAYLOAD=$(cat)
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)
# only care about real commits (ignore commit --amend metadata-only, -h, etc.)
printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])git[[:space:]]+(-[^[:space:]]+[[:space:]]+)*commit\b' || exit 0
printf '%s' "$CMD" | grep -qE '\-\-amend|--no-verify' && exit 0

# The commit may target another repo: `cd <dir> && git ...` or `git -C <dir> ...`.
# Resolve the root from that dir, not the session cwd (2026-10-06: a commit in
# one repo was checked against a different repo's 166-minute-old marker).
DIR=$(printf '%s' "$CMD" | sed -nE 's/.*git[[:space:]]+-C[[:space:]]+([^[:space:];&|]+).*/\1/p')
[ -z "$DIR" ] && DIR=$(printf '%s' "$CMD" | sed -nE 's/^[[:space:]]*cd[[:space:]]+([^[:space:];&|]+).*/\1/p')
DIR="${DIR/#\~/$HOME}"
ROOT=$(git -C "${DIR:-.}" rev-parse --show-toplevel 2>/dev/null) || exit 0
MARK="$ROOT/.claude-verified"
STALE_MIN="${CLAUDE_COMMIT_GATE_STALE_MIN:-120}"   # evidence older than this many minutes is stale

emit() {  # $1=decision(allow|block) $2=reason
  if [ "$1" = "block" ] && [ "$MODE" = "block" ]; then
    jq -nc --arg r "$2" '{decision:"block", reason:$r}'
    exit 0
  fi
  # warn mode: surface as additional context, do not block
  printf '⚠ commit-evidence-gate: %s\n' "$2" >&2
  exit 0
}

if [ ! -f "$MARK" ]; then
  emit block "No test evidence for this repo. Run \`prove-tests '<your test cmd>'\` as its OWN Bash call, then commit in a second call — chaining \`prove-tests ... && git commit\` in one command is blocked too, because this gate checks the marker before the command runs. The commit must be backed by a real, hashed test run — don't just claim tests passed. (Repo genuinely has no tests, e.g. a docs/planning-only repo? Use \`git commit --no-verify\` and say so in the message. A \`CLAUDE_COMMIT_GATE=off\` prefix on the git command does NOT work — this hook reads that var from its own env, not your command line.)"
fi

# staleness check (cross-platform mtime)
NOW=$(date +%s)
MT=$(stat -f %m "$MARK" 2>/dev/null || stat -c %Y "$MARK" 2>/dev/null || echo 0)
AGE_MIN=$(( (NOW - MT) / 60 ))
if [ "$AGE_MIN" -gt "$STALE_MIN" ]; then
  # include the last-proven command so the agent can re-run without digging it
  # out of the marker (retro sweep 2026-07-11: 8 sessions paid that discovery cost)
  LAST_CMD=$(jq -r '.cmd // empty' "$MARK" 2>/dev/null)
  if [ -n "$LAST_CMD" ]; then
    emit block "Test evidence is ${AGE_MIN}m old (stale > ${STALE_MIN}m). Re-run: prove-tests '$LAST_CMD'"
  else
    emit block "Test evidence is ${AGE_MIN}m old (stale > ${STALE_MIN}m). Re-run \`prove-tests '<cmd>'\` before committing."
  fi
fi

# integrity check: marker must record a non-empty hash + exit 0
EXIT=$(jq -r '.exit // empty' "$MARK" 2>/dev/null)
HASH=$(jq -r '.sha256 // empty' "$MARK" 2>/dev/null)
if [ -z "$HASH" ] || [ "$EXIT" != "0" ]; then
  emit block "Test evidence exists but records a failing/empty run (exit=$EXIT). Fix tests, re-run prove-tests."
fi

# Visual evidence for UI commits (2026-10-19). Opt-in: runs
# only in repos with .claude/visual.json. Mode CLAUDE_VISUAL_GATE: warn (default)
# | block | off. Guardrail: in block mode it refuses a UI commit without fresh
# screenshots (false pass) and tolerates false blocks on type-only .tsx edits,
# which escape with "[no-visual]" in the message. Every decision goes to
# VISUAL_GATE_LOG (default ~/.claude/hooks/visual-gate.log). Kill the check if,
# after two weeks, fewer than 3 warnings preceded a real visual fix.
VMODE="${CLAUDE_VISUAL_GATE:-warn}"
if [ "$VMODE" != "off" ] && [ -f "$ROOT/.claude/visual.json" ]; then
  UI=$( { git -C "$ROOT" diff --cached --name-only
          printf '%s' "$CMD" | grep -qE 'commit[^;&|]*[[:space:]]-[a-zA-Z]*a' && git -C "$ROOT" diff --name-only; } \
        | grep -E '\.(tsx|jsx|css|scss|vue|html)$' | sort -u)
  VLOG="${VISUAL_GATE_LOG:-$HOME/.claude/hooks/visual-gate.log}"
  if [ -n "$UI" ] && ! printf '%s' "$CMD" | grep -q '\[no-visual\]'; then
    VMARK="$ROOT/.claude-visual/marker.json"
    VERDICT=ok
    if [ ! -f "$VMARK" ]; then VERDICT=missing
    elif [ "$(jq -r .head "$VMARK")" != "$(git -C "$ROOT" rev-parse HEAD)" ]; then VERDICT=stale-head
    else
      VMT=$(stat -f %m "$VMARK" 2>/dev/null || stat -c %Y "$VMARK")
      while IFS= read -r f; do
        [ -f "$ROOT/$f" ] && [ "$(stat -f %m "$ROOT/$f" 2>/dev/null || stat -c %Y "$ROOT/$f")" -gt "$VMT" ] && VERDICT=stale-edit && break
      done <<< "$UI"
    fi
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date -u +%FT%TZ)" "$VMODE" "$VERDICT" "$ROOT" "$(echo "$UI" | wc -l | tr -d ' ')" >> "$VLOG"
    if [ "$VERDICT" != ok ]; then
      R="UI files changed but visual evidence is $VERDICT. Run \`prove-visual\` as its own Bash call, Read every PNG, then commit. Type-only change? Put [no-visual] in the message."
      if [ "$VMODE" = block ]; then jq -nc --arg r "$R" '{decision:"block", reason:$r}'; exit 0; fi
      printf '⚠ commit-evidence-gate (visual): %s\n' "$R" >&2
    fi
  fi
fi

exit 0
