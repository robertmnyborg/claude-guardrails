#!/usr/bin/env python3
# context-checkpoint-guard: Stop hook (2026-11-24).
# Rule it replaces: "every project folder keeps a CONTEXT.md; update it after significant steps."
# As prose that rule held in few folders: 59 of 166 project folders had no CONTEXT.md and 41
# more were over 30 days old, so a session that died mid-task left nothing to resume from.
# The idea comes from agent platforms that keep a session's state outside the sandbox and
# restore from a checkpoint; for a local harness the checkpoint is a short state file.
#
# Blocks ONCE per project per session when the session wrote files under <root>/<project>/
# (Write, Edit, MultiEdit, NotebookEdit) but did not change <root>/<project>/CONTEXT.md.
# A CONTEXT.md modified after the session started also counts, since shell writes never show
# up as Write/Edit calls. The block tells the model to skip the update when the change was
# trivial, so a false fire costs one short turn.
#
# Env (all optional):
#   CHECKPOINT_ROOT   folder whose children are projects (default ~/Projects)
#   CHECKPOINT_FILE   state file name (default CONTEXT.md)
#   CHECKPOINT_SKIP   comma list of top-level folders to ignore (default none)
#   CHECKPOINT_LOG    fire log (default ~/.claude/hooks/context-checkpoint-guard.log)
import json, os, sys, datetime

HOME = os.path.expanduser("~")
ROOT = os.path.abspath(os.path.expanduser(os.environ.get("CHECKPOINT_ROOT", "~/Projects"))) + os.sep
STATE_FILE = os.environ.get("CHECKPOINT_FILE", "CONTEXT.md")
SKIP = {s for s in os.environ.get("CHECKPOINT_SKIP", "").split(",") if s}
LOG = os.path.expanduser(os.environ.get("CHECKPOINT_LOG", "~/.claude/hooks/context-checkpoint-guard.log"))
SEEN_DIR = os.path.join(os.path.dirname(LOG), ".context-checkpoint-seen")
WRITE_TOOLS = {"Write", "Edit", "NotebookEdit", "MultiEdit"}


def project_of(path):
    path = os.path.abspath(os.path.expanduser(path))
    if not path.startswith(ROOT):
        return None
    top = path[len(ROOT):].split(os.sep, 1)[0]
    if not top or top in SKIP or top.startswith("."):
        return None
    root = os.path.join(ROOT, top)
    return root if os.path.isdir(root) else None


def written_paths(transcript):
    paths = []
    with open(transcript) as f:
        for line in f:
            try:
                e = json.loads(line)
            except ValueError:
                continue
            if e.get("type") != "assistant":
                continue
            for c in e.get("message", {}).get("content", []):
                if isinstance(c, dict) and c.get("type") == "tool_use" and c.get("name") in WRITE_TOOLS:
                    inp = c.get("input") or {}
                    p = inp.get("file_path") or inp.get("notebook_path")
                    if p:
                        paths.append(p)
    return paths


data = json.load(sys.stdin)
if data.get("stop_hook_active") or not data.get("transcript_path"):
    sys.exit(0)

touched, checkpointed = set(), set()
for p in written_paths(data["transcript_path"]):
    root = project_of(p)
    if not root:
        continue
    if os.path.abspath(os.path.expanduser(p)) == os.path.join(root, STATE_FILE):
        checkpointed.add(root)
    else:
        touched.add(root)

st = os.stat(data["transcript_path"])
started = getattr(st, "st_birthtime", st.st_ctime)
for root in touched - checkpointed:
    ctx = os.path.join(root, STATE_FILE)
    if os.path.exists(ctx) and os.path.getmtime(ctx) >= started:
        checkpointed.add(root)

session = data.get("session_id") or "unknown"
os.makedirs(SEEN_DIR, exist_ok=True)
seen_file = os.path.join(SEEN_DIR, session)
seen = set(open(seen_file).read().split("\n")) if os.path.exists(seen_file) else set()
missing = sorted(touched - checkpointed - seen)
if not missing:
    sys.exit(0)

with open(seen_file, "a") as f:
    f.write("\n".join(missing) + "\n")
with open(LOG, "a") as f:
    f.write(json.dumps({"ts": datetime.datetime.now().isoformat(timespec="seconds"), "session": session, "projects": missing}) + "\n")

names = ", ".join(os.path.join(m, STATE_FILE) for m in missing)
print(json.dumps({
    "decision": "block",
    "reason": (
        "context-checkpoint-guard: this session changed files in " + ", ".join(missing)
        + " but did not update " + names + ". If the work there reached a state worth resuming from "
        "(something built, decided, or left waiting), add or update a short dated entry: state, what it waits on, next step. "
        "Create the file if it is missing. If the change was trivial (a typo, a scratch file), end your turn with no further output."
    ),
}))
