#!/usr/bin/env bash
# PreToolUse(Bash): on `git push`, run the global pre-push secret gate in repos whose local
# core.hooksPath (husky) hides it. Other repos already run it through the global core.hooksPath.
# PRE_PUSH_HOOK overrides the gate path (default: ~/.config/git/hooks/pre-push, i.e. hooks/git/pre-push).
PRE_PUSH_HOOK="${PRE_PUSH_HOOK:-$HOME/.config/git/hooks/pre-push}"
in=$(cat)
cmd=$(jq -r '.tool_input.command // empty' <<<"$in")
grep -qE '(^|[;&|[:space:]])git( -C [^ ]+)? push( |$)' <<<"$cmd" || exit 0
dir=$(jq -r '.cwd // empty' <<<"$in")
c=$(grep -oE '(^|[;&[:space:]])cd [^;&|]+' <<<"$cmd" | tail -1 | sed -E 's/^[;&[:space:]]*cd //; s/[[:space:]]+$//'); [ -n "$c" ] && dir="${c/#\~/$HOME}"
g=$(grep -oE 'git -C [^ ]+ push' <<<"$cmd" | awk '{print $3}'); [ -n "$g" ] && dir="${g/#\~/$HOME}"
cd "$dir" 2>/dev/null && git rev-parse --git-dir >/dev/null 2>&1 || exit 0
[ -z "$(git config --local core.hooksPath)" ] && exit 0
remote=$(git config "branch.$(git branch --show-current).remote" || echo origin)
out=$(printf 'HEAD %s refs/heads/x %s\n' "$(git rev-parse HEAD)" 0000000000000000000000000000000000000000 \
  | SECRET_SCAN_NO_CHAIN=1 "$PRE_PUSH_HOOK" "$remote" 2>&1)
if [ $? -ne 0 ]; then
  jq -n --arg r "Secret gate blocked this push. $out" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
fi
exit 0
