#!/usr/bin/env bash
# PreToolUse(Bash): deny commands that carry a literal credential (PGPASSWORD='...', user:pass@ URLs).
# An approved command is saved verbatim to settings.local.json, so a literal password there leaks on the next export.
# SECRET_SCAN overrides the scanner path (default: secret-scan on PATH, else ~/bin/secret-scan).
SCAN="${SECRET_SCAN:-$(command -v secret-scan || echo "$HOME/bin/secret-scan")}"
cmd=$(jq -r '.tool_input.command // empty')
[ -z "$cmd" ] && exit 0
if ! printf '%s\n' "$cmd" | "$SCAN" --stdin 2>/dev/null; then
  jq -n '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",
    permissionDecisionReason:"Command contains a literal credential. Approved commands are saved verbatim to settings.local.json and leak on export. Use ~/.pgpass for psql, or read the value into a variable at runtime (PW=$(aws secretsmanager ...)), and never type the value into the command."}}'
fi
exit 0
