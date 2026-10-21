#!/usr/bin/env bash
# skill-router: PreToolUse(Write|Edit|MultiEdit) hook. EXAMPLE rule table; edit it.
#
# Closes a gap found in a 2026-08-11 harness audit: skills whose SKILL.md says
# "use whenever you write X" have no mechanism that makes them fire. A skill
# description is a retrieval hint, not a trigger. One such skill fired 0 times in
# 90 days. Anything with a deterministic file-path predicate belongs here
# instead: zero model tokens until the predicate hits.
#
# Emits additionalContext (never blocks). Fires at most once per session per rule,
# so it nudges instead of nagging.
#
# Each rule carries: the predicate, the guardrail error it accepts (false fires,
# ~150 tokens once per session, over misses), and a kill condition.
#
# Reads PreToolUse JSON on stdin: { session_id, tool_name, tool_input: { file_path } }.
set -uo pipefail
PAYLOAD=$(cat)
FP=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // "nosid"' 2>/dev/null)
TOOL=$(printf '%s' "$PAYLOAD" | jq -r '.tool_name // empty' 2>/dev/null)
[ -z "$FP" ] && exit 0

STATE="${TMPDIR:-/tmp}/claude-skill-router-$SID"
mkdir -p "$STATE" 2>/dev/null

fire() {  # $1=rule-key  $2=context text
  [ -e "$STATE/$1" ] && return 0
  touch "$STATE/$1"
  jq -nc --arg c "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse", additionalContext:$c}}'
  exit 0
}

SKIP_RE='(\.test\.|\.spec\.|__tests__|/node_modules/|/dist/|/build/|/\.next/|/fixtures/)'
BASE=$(basename "$FP" | tr '[:upper:]' '[:lower:]')

# --- rule: spec ---------------------------------------------------------------
# A PRD, spec, brief, or pitch names a buyer and a job. Predicate is the filename.
# Kill condition: 30 days of fires with no spec citing its evidence.
if printf '%s' "$FP" | grep -qE '\.md$' \
   && printf '%s' "$BASE" | grep -qE '(prd|spec|requirements|brief|one-pager|pitch)' \
   && ! printf '%s' "$FP" | grep -qE "$SKIP_RE"; then
  fire spec \
    "Writing a PRD, spec, brief, or pitch. Invoke Skill(spec-driven-development) before drafting. Name the buyer and the job from real evidence (a quote, a ticket, a call), not an invented persona. This nudge fires once per session."
fi

# --- rule: harness-component --------------------------------------------------
# A hook, a skill, or settings.json is a harness component. Name the predicate
# that fires it and the error it accepts, before writing it.
case "$FP" in
  "$HOME"/.claude/hooks/*|"$HOME"/.claude/skills/*/SKILL.md|"$HOME"/.claude/settings.json)
    fire harness-component \
      "Editing a harness component (hook, skill, or settings). Before you write: (1) name the deterministic predicate that fires it, because a SKILL.md description is a retrieval hint and not a trigger; (2) if it gates or routes, name the guardrail error, meaning which of false-block vs false-pass it refuses and what each costs; (3) name the rollback. This nudge fires once per session." ;;
esac

# --- rule: ux -----------------------------------------------------------------
# Creating a NEW frontend file (Write to a path that does not exist yet) means a
# new screen, route, or component: the moment to check evidence, before pixels.
# Kill condition: 30 days of fires with no evidence gate in the plan.
if [ "$TOOL" = "Write" ] && [ ! -e "$FP" ] \
   && printf '%s' "$FP" | grep -qE '\.(tsx|jsx|vue|svelte|html)$' \
   && ! printf '%s' "$FP" | grep -qE "$SKIP_RE"; then
  fire ux \
    "Creating a new UI file ($FP). Before building, state in one or two lines who arrives at this screen, what evidence says they need it, and the success metric plus the condition that would kill it. Then invoke your UX review skill. Before calling it done, test empty data and labels three times longer. This nudge fires once per session."
fi

exit 0
