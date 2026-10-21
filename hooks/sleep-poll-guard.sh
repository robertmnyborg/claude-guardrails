#!/usr/bin/env bash
# sleep-poll-guard: PreToolUse:Bash hook (added 2026-08-29).
#
# WHY THIS EXISTS
# A CLAUDE.md rule said since 2026-08-15: "never `sleep N; <cmd>` to wait for a
# background job, the harness blocks it." Measurement in the 08-15 -> 08-29
# window says the second half of that sentence is FALSE, and that is why the
# rule failed. Of 55 sleep-chained Bash calls, 53 SUCCEEDED and only 2 were
# blocked. The built-in guard is inconsistent, so the model watched
# `sleep 590; tail -3 enrich.log` work over and over and reasonably concluded
# the rule did not apply. One session (a weekly batch job) issued 48 of them,
# roughly 7.9 hours of foreground blocking inside a single run.
#
# Prose that asserts a false fact about the harness is worse than no prose: it
# gets disconfirmed by observation and takes the real advice down with it. So
# the rule becomes a deterministic local predicate that actually fires.
#
# RESULT (first full week live, measured 2026-09-05): chained sleeps fell from
# 138 calls to 1. The three in-window fires were 2 false positives (bounded
# `for i in $(seq 1 N); do ...; sleep 15; done` polls, which are the
# until-loop pattern with a cap) and 1 true positive. Revised 09-05 to exempt
# `for VAR in` loops alongside until/while.
#
# PREDICATE (a regex, not a classifier)
# Deny when a Bash command chains `sleep N` (N >= SLEEP_GUARD_MIN_SECS, default
# 10) to another command. Exempt the documented correct pattern: a sleep inside
# an until/while/for poll loop, which is what the replacement advice tells you
# to write.
#
# GUARDRAIL ERROR
# Refuses false negatives. A missed long blocking sleep burns wall-clock and
# tokens at scale (48 in one session). A false block costs one retry and the
# model has two documented alternatives that are strictly better. Short sleeps
# (< 10s) and loop-internal sleeps stay free, so the common legitimate uses
# (`sleep 2` between polls, `open -a X && sleep 3`) never trip it.
#
# ROLLBACK: remove the PreToolUse Bash entry for this file from
# ~/.claude/settings.json, or `chmod -x` this script.
#
# SMOKE TEST (tests/sleep-poll-guard.test.sh runs all eight):
#   block: 'sleep 590; tail -3 enrich.log'
#   block: 'cmd && sleep 60; tail x.log'
#   block: 'psql -f q.sql > /tmp/o 2>&1 & echo launched; sleep 25; tail -6 /tmp/o'
#   allow: 'until curl -sf localhost:8080; do sleep 2; done'
#   allow: 'for i in $(seq 1 60); do out=$(cmd); case "$out" in *ok*) break;; esac; sleep 15; done'
#   allow: 'for i in 1 2 3; do sleep 10; tail -1 x.log; done'
#   allow: 'sleep 3; echo hi'                 (under threshold)
#   allow: 'tail -3 enrich.log'               (no sleep)
set -uo pipefail

MIN_BLOCK_SECS="${SLEEP_GUARD_MIN_SECS:-10}"

PAYLOAD=$(cat)
CMD=$(printf '%s' "$PAYLOAD" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0

# Exempt the documented correct pattern: sleep inside a poll loop
# (until / while / `for VAR in ...`). A bounded for-loop with a break is the
# until-loop with a cap, and the 09-05 sweep found it was the guard's only
# false positive.
if printf '%s' "$CMD" | grep -qE '(^|[;&|[:space:]])(until|while)[[:space:]]|(^|[;&|[:space:]])for[[:space:]]+[A-Za-z_][A-Za-z0-9_]*[[:space:]]+in[[:space:]]'; then
  exit 0
fi

# Find `sleep N` chained to a following command via ; or && or ||
SECS=$(printf '%s' "$CMD" \
  | grep -oE '(^|[;&|[:space:]])sleep[[:space:]]+[0-9]+[[:space:]]*(;|&&|\|\|)' \
  | grep -oE '[0-9]+' | sort -rn | head -1)
[ -n "${SECS:-}" ] || exit 0
[ "$SECS" -ge "$MIN_BLOCK_SECS" ] || exit 0

cat >&2 <<EOF
BLOCKED by sleep-poll-guard: this command blocks the foreground for ${SECS}s to wait for something.

Chaining \`sleep ${SECS}\` to another command burns ${SECS}s of wall clock per call and returns one
stale snapshot. The built-in harness guard catches this only sometimes (2 of 55 calls in one
measured two-week window), so "it worked last time" is not evidence that it is fine.

Use one of these instead:
  1. Start the job with run_in_background: true, then read its output file when the
     task-completion notification arrives. Preferred, costs zero waiting.
  2. Poll with an until-loop, which this guard permits:
       until <condition>; do sleep 2; done
  3. Use the Monitor tool with an until-condition.

If you genuinely need a short pause, keep it under ${MIN_BLOCK_SECS}s.
EOF
exit 2
