#!/usr/bin/env python3
# handoff-guard: Stop hook (2026-09-18). Blocks ONCE when the final reply hands the user a step
# ("Next action: say X and I'll...", "reply X and I'll", "want me to ...?") so the model re-checks
# whether that step is a free read-only lookup it should just run. Fires are logged to measure
# false positives; the model is told to stop as-is when the step needs a decision, spend, access,
# or an irreversible action.
#
# Origin: a CLAUDE.md rule ("free lookups are never a question for the user") kept failing. One
# reply ended "say 'check X' and I'll look", handing the user a 2-minute `git show` the model
# could have run itself. The prose rule stayed; this hook is what makes it fire.
# Log path: HANDOFF_GUARD_LOG (default ~/.claude/hooks/handoff-guard.log).
import json, re, sys, os, datetime

HANDOFF = re.compile(
    r"(next action:|\b(reply|say|type|tell me|send me|paste|confirm)\b[^.\n]{0,120}\band I(?:'ll| will)\b|want me to\b[^.\n]*\?)",
    re.I,
)
LOG = os.path.expanduser(os.environ.get("HANDOFF_GUARD_LOG", "~/.claude/hooks/handoff-guard.log"))

def last_assistant_text(path):
    text = ""
    with open(path) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "assistant":
                continue
            parts = [c.get("text", "") for c in e.get("message", {}).get("content", []) if isinstance(c, dict) and c.get("type") == "text"]
            if parts:
                text = "\n".join(parts)
    return text

data = json.load(sys.stdin)
if data.get("stop_hook_active"):
    sys.exit(0)
msg = data.get("last_assistant_message") or ""
if not msg and data.get("transcript_path"):
    msg = last_assistant_text(data["transcript_path"])
tail = msg.strip()[-600:]
m = HANDOFF.search(tail)
if not m:
    sys.exit(0)
with open(LOG, "a") as f:
    f.write(json.dumps({"ts": datetime.datetime.now().isoformat(timespec="seconds"), "session": data.get("session_id"), "match": m.group(0)[:160]}) + "\n")
print(json.dumps({
    "decision": "block",
    "reason": (
        "handoff-guard: your reply ends by handing the user a step (\"" + m.group(0)[:120] + "\"). "
        "If that step is something you can do yourself right now that is read-only, needs no new spend, "
        "and runs in under ~10 minutes (grep, git show, file read, read-only query, fetch), do it now and report the result. "
        "If it needs the user's decision, an approval for spend or prod writes, access you lack, or an irreversible action, "
        "end your turn with no further output."
    ),
}))
