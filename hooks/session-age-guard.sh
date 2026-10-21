#!/usr/bin/env bash
# session-age-guard: UserPromptSubmit hook (proposed by a weekly retro sweep 2026-07-11,
# retuned 2026-08-08 and 2026-08-15). Inline prevention for the runaway-session
# cost pattern: a weekly cost report only catches an expensive session AFTER the
# money is spent. This warns in-session once accumulated context is large,
# nudging a fresh session or /compact at the topic boundary. Every turn re-reads
# the whole history, so cost per turn grows with context volume.
#
# Tunables (env): SESSION_GUARD_SIZE_MB (default 3), SESSION_GUARD_NOTIFY_MB
# (default 8, macOS notification), SESSION_GUARD_REWARN_HOURS (default 6).
set -uo pipefail

# 2026-08-08 retune. The old 48h/15MB thresholds stayed silent across all four
# most expensive sessions in the 7/25-8/8 window. The cost pattern had changed: those
# sessions were single-day and dense, not multi-day. Longest real user-prompt
# span was 16.3h, so no age threshold above ~16h can ever fire.
#
#   prompt span   total transcript MB   old guard
#   15.6h       7MB                  silent
#   16.3h      15MB  <- exactly 15, `-gt 15` missed it
#    3.3h      19MB  (2.3MB main + ~17MB subagents)
#     5.7h       3MB                  silent
#     2.2h      11MB                  silent
#
# So: size-of-context is the primary detector, subagent transcripts count toward
# it, and the comparison is -ge. Calibration: 3MB trips 9 of 77 sessions in the
# window (12%), catching 7 of the 8 priciest.
#
# 2026-08-15 recalibration. The age branch was not a mistuned signal, it was a
# broken one: age came from the transcript's BIRTH time, and almost every
# session gets resumed or appended to across days, so `age >= 24h` fired on 61 of
# 65 sessions in the 8/8-8/15 window (94%), noise that would train the model to
# ignore the warning outright. Size alone fires on 6 of 65 (9%) and catches all
# three most expensive sessions (17MB, 9MB, 19MB). Age is reported for context but no
# longer triggers.
SIZE_MB_MAX="${SESSION_GUARD_SIZE_MB:-3}"          # warn when main+subagent transcript bytes reach this
NOTIFY_MB="${SESSION_GUARD_NOTIFY_MB:-8}"          # past this, notify the user directly
REWARN_HOURS="${SESSION_GUARD_REWARN_HOURS:-6}"    # at most one warning per session per this many hours

fsize()  { stat -f %z "$1" 2>/dev/null || stat -c %s "$1" 2>/dev/null || echo 0; }
fmtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || echo 0; }

PAYLOAD=$(cat)
TP=$(printf '%s' "$PAYLOAD" | jq -r '.transcript_path // empty' 2>/dev/null)
SID=$(printf '%s' "$PAYLOAD" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$TP" ] && [ -f "$TP" ] || exit 0

NOW=$(date +%s)
BIRTH=$(stat -f %B "$TP" 2>/dev/null || stat -c %W "$TP" 2>/dev/null || echo "$NOW")
[ "$BIRTH" -gt 0 ] 2>/dev/null || BIRTH=$NOW
AGE_H=$(( (NOW - BIRTH) / 3600 ))

# Count the fan-out too: subagent transcripts live beside the main one, in a dir
# named for the session id. A workflow session's real context load is mostly
# there, and it is invisible to a main-transcript-only size check.
BYTES=$(fsize "$TP")
SUBDIR="$(dirname "$TP")/$(basename "$TP" .jsonl)/subagents"
if [ -d "$SUBDIR" ]; then
  SUB_BYTES=$(find "$SUBDIR" -name '*.jsonl' -print0 2>/dev/null | while IFS= read -r -d '' f; do fsize "$f"; done | awk '{s+=$1} END {print s+0}')
  BYTES=$(( BYTES + ${SUB_BYTES:-0} ))
fi
SIZE_MB=$(( BYTES / 1048576 ))

# -ge, not -gt: a transcript sitting exactly on the threshold is the case that
# escaped the 7/25-8/8 window (exactly 15MB).
[ "$SIZE_MB" -ge "$SIZE_MB_MAX" ] || exit 0

# rate-limit the nag
KEY="${SID:-$(printf '%s' "$TP" | shasum | cut -c1-16)}"
MARKER="${TMPDIR:-/tmp}/session-age-warned-${KEY}"
if [ -f "$MARKER" ]; then
  LAST=$(fmtime "$MARKER")
  [ $(( (NOW - LAST) / 3600 )) -lt "$REWARN_HOURS" ] && exit 0
fi
touch "$MARKER"

# 2026-08-15: the warning was not blind, it was ignored. An earlier sweep
# concluded this guard "fired zero times" across the most expensive sessions; measuring the
# transcripts directly showed the opposite: it fired 41 times in that window and
# 76 times in 8/8-8/15, including inside all three of that window's most expensive
# sessions. Those sessions then ran for 2.7-4.8 more days.
# A UserPromptSubmit stdout nudge is advisory context: the model absorbs it and
# says nothing. So (a) the text is now an instruction to surface it, not a note,
# and (b) past NOTIFY_MB the user is notified directly, routing around the model.
# The person who decides to open a fresh session is the one who has to see this.
if [ "$SIZE_MB" -ge "$NOTIFY_MB" ] && command -v osascript >/dev/null; then
  osascript -e "display notification \"This session holds ${SIZE_MB}MB of context and is costing ~linearly more per turn. Consider /compact or a fresh session.\" with title \"session-age-guard\"" 2>/dev/null || true
fi

echo "⏳ session-age-guard: this session has accumulated ${SIZE_MB}MB of transcript (incl. subagents) over ${AGE_H}h. Every turn re-reads the whole history, so cost per turn grows with context volume. ACTION REQUIRED: say this to the user in the FIRST LINE of your next reply, name the MB figure, and recommend /compact or a fresh session at the next topic boundary. Do not silently absorb this notice."
exit 0
