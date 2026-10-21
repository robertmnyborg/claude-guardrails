# claude-guardrails

Claude Code hooks that enforce rules the model ignores when the rules live only in CLAUDE.md.

A CLAUDE.md rule is a suggestion the model weighs against what it observes. When a rule said "the harness blocks chained `sleep`", the model watched 53 of 55 chained sleeps succeed and stopped believing it. One session then spent about 7.9 hours in 48 foreground sleeps. The fix was a 10-line regex in a hook. After one week of the hook, chained sleeps fell from 138 calls to 1.

Each hook here started as a prose rule that failed, and each one has a dated note in its header saying how it failed and what the hook changed.

| Hook | Event | Blocks or nudges | Motivating number |
|---|---|---|---|
| `sleep-poll-guard.sh` | PreToolUse Bash | blocks `sleep N; cmd` for N >= 10 | 48 sleeps, ~7.9 h in one session; 138 to 1 per week |
| `secret-command-guard.sh` | PreToolUse Bash | blocks commands with a literal credential | three secret leaks before it shipped |
| `push-secret-gate.sh` + `git/pre-push` | PreToolUse Bash, git | blocks `git push` of commits holding a secret | the earlier scan missed punctuation-heavy passwords |
| `commit-evidence-gate.sh` | PreToolUse Bash | blocks `git commit` without a hashed passing test run | "tests pass" was a claim, not evidence |
| `handoff-guard.py` | Stop | blocks once when a reply hands the user a free lookup | 163 fires in its first 5 weeks |
| `session-age-guard.sh` | UserPromptSubmit | tells the model to warn the user about context size | 3 sessions ran 2.7 to 4.8 more days after a silent warning |
| `skill-router.sh` | PreToolUse Write/Edit | injects a skill nudge on a file-path match | one skill fired 0 times in 90 days on its description alone |

Helpers in `bin/`: `secret-scan` (shared scanner), `prove-tests` (writes the test evidence), `prove-visual` (writes screenshot evidence).

## Install

Requirements: bash, jq, perl, python3, git. `gitleaks` for directory scans and the pre-push gate (`brew install gitleaks`). Node 22+ and a Chrome with remote debugging for `prove-visual`. Tested on macOS; the scripts fall back to GNU `stat` on Linux.

1. Copy the hooks: `mkdir -p ~/.claude/hooks && cp hooks/*.sh hooks/*.py ~/.claude/hooks/`.
2. Copy the helpers to a directory on your PATH: `cp bin/* ~/bin/`.
3. Install the global git pre-push gate: `mkdir -p ~/.config/git/hooks && cp hooks/git/pre-push ~/.config/git/hooks/ && git config --global core.hooksPath ~/.config/git/hooks`.
4. Merge the snippet below into the `hooks` key of `~/.claude/settings.json`.
5. Run `bash tests/run-all.sh` to confirm the scripts work on your machine.

Skip any hook you do not want. Each one is independent, except that the two secret hooks need `secret-scan`.

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash", "hooks": [
        { "type": "command", "command": "bash $HOME/.claude/hooks/sleep-poll-guard.sh" },
        { "type": "command", "command": "bash $HOME/.claude/hooks/secret-command-guard.sh" },
        { "type": "command", "command": "bash $HOME/.claude/hooks/push-secret-gate.sh" },
        { "type": "command", "command": "bash $HOME/.claude/hooks/commit-evidence-gate.sh" }
      ]},
      { "matcher": "Write|Edit|MultiEdit", "hooks": [
        { "type": "command", "command": "bash $HOME/.claude/hooks/skill-router.sh" }
      ]}
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "bash $HOME/.claude/hooks/session-age-guard.sh" }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "python3 $HOME/.claude/hooks/handoff-guard.py", "timeout": 10 }] }
    ]
  }
}
```

### Configuration (env vars, all optional)

| Variable | Default | Used by |
|---|---|---|
| `SECRET_SCAN` | `secret-scan` on PATH, else `~/bin/secret-scan` | secret-command-guard, pre-push |
| `PRE_PUSH_HOOK` | `~/.config/git/hooks/pre-push` | push-secret-gate |
| `SLEEP_GUARD_MIN_SECS` | `10` | sleep-poll-guard |
| `CLAUDE_COMMIT_GATE` | `block` (`warn`, `off`) | commit-evidence-gate |
| `CLAUDE_COMMIT_GATE_STALE_MIN` | `120` | commit-evidence-gate |
| `CLAUDE_VISUAL_GATE` | `warn` (`block`, `off`) | commit-evidence-gate |
| `VISUAL_GATE_LOG` | `~/.claude/hooks/visual-gate.log` | commit-evidence-gate |
| `HANDOFF_GUARD_LOG` | `~/.claude/hooks/handoff-guard.log` | handoff-guard |
| `SESSION_GUARD_SIZE_MB` / `_NOTIFY_MB` / `_REWARN_HOURS` | `3` / `8` / `6` | session-age-guard |
| `PROVE_VISUAL_CDP` / `PROVE_VISUAL_LAUNCH` | `http://127.0.0.1:9222` / unset | prove-visual |

Hooks read these from the Claude Code process environment. Set them in the `env` key of `settings.json` or in your shell profile. A prefix on the model's command (`CLAUDE_COMMIT_GATE=off git commit`) reaches git, not the hook, and does nothing.

## The hooks

### sleep-poll-guard

Blocks a Bash command that chains `sleep N` (N >= 10) to another command, such as `sleep 590; tail -3 build.log`. Allows sleeps inside `until`, `while`, and `for VAR in` loops, because a bounded poll loop is the pattern the deny message recommends. Allows sleeps under 10 seconds.

Failure: a CLAUDE.md rule claimed the built-in harness blocked chained sleeps. Over two weeks, 53 of 55 chained sleeps succeeded, so the model learned the rule was false. One batch session issued 48 of them, about 7.9 hours of blocked wall clock.

Result: chained sleeps fell from 138 calls in a week to 1. The first version also blocked bounded `for` loops (2 false positives of 3 fires), and the exemption now covers them.

### secret-command-guard

Blocks a Bash command that contains a literal credential: `PGPASSWORD=...`, `user:pass@host` URLs, `token=ghp_...`, PEM private keys. Claude Code saves an approved command verbatim to `settings.local.json`, so a password typed into one command leaks the next time anyone exports or shares that file.

`secret-scan --stdin` makes the decision. It passes placeholders (`$VAR`, `<...>`, `***`), env reads (`os.environ[...]`, `process.env.X`), sed redactions, and localhost URLs. A line containing `secret-scan:allow` passes, and only a human should add that marker.

Failure: three leaks, and an earlier scanner that could not match punctuation-heavy passwords. In its first week the guard denied 5 commands: 1 real key, 1 deliberate test, 1 correct block on fake tokens in a test, and 2 false positives on code that reads a secret from the environment. Those 2 false positives mattered, because the deny message tells the model to read secrets from the environment. The regression cases in `tests/secret-scan-cases/` cover each fix (11 clean lines, 8 dirty lines). One tuning pass opened a hole that let any unquoted end-of-line value through, and the frozen cases caught it: 4 of 10 passed before the fix and 10 of 10 after.

### push-secret-gate and git/pre-push

`git/pre-push` is a global git hook (`core.hooksPath`). It runs `gitleaks` plus `secret-scan` over every outgoing commit, including one that adds a secret and a later commit that deletes it. It prints file names, never values. A human can bypass a confirmed false positive with `SECRET_SCAN_SKIP=1 git push`.

Repos that use husky set a local `core.hooksPath`, which hides the global hook. `push-secret-gate.sh` closes that gap: on any `git push` the model runs in such a repo, it runs the global gate first and denies the push if the gate fails.

### commit-evidence-gate + prove-tests

Blocks `git commit` unless the repo has a `.claude-verified` marker that is under 120 minutes old and records exit 0 and a SHA-256 of real test output. `prove-tests "<cmd>"` runs the tests and writes that marker. The model can still claim tests passed, but the commit stays blocked until `prove-tests` writes a passing run. (Idea from Nick Nisi's WorkOS talk on replacing trust with evidence.)

Escape hatch for repos with no tests: `git commit --no-verify`, stated in the message.

Fixes the header records:
- The stale-evidence message now includes the last proven command, because rediscovering it cost one extra turn in 8 sessions in one week.
- The message says to run `prove-tests` as its own call. `prove-tests ... && git commit` is blocked too, because the hook checks the marker before the command runs.
- The hook resolves the target repo from `cd <dir> &&` or `git -C <dir>`. Before this fix, a commit in one repo was checked against another repo's 166-minute-old marker.

**Visual check (opt-in).** In a repo with `.claude/visual.json`, a commit that touches `.tsx/.jsx/.css/.scss/.vue/.html` also needs fresh screenshots from `prove-visual`. `prove-visual` captures light and dark themes at 1280 and 390 px wide, plus a pass with every short label tripled, and writes a hashed marker tied to `HEAD`. The check warns by default. `[no-visual]` in the commit message skips it for type-only edits.

```json
{ "base_url": "http://localhost:3000", "routes": ["/", "/settings"], "stress": true }
```

### handoff-guard

A Stop hook. If the last 600 characters of the reply hand the user a step ("Next action:", "reply X and I'll...", "want me to ...?"), it blocks the stop once. The block tells the model to run the step if it is read-only, free, and under 10 minutes, and otherwise to stop without more output. `stop_hook_active` prevents a loop.

Failure: CLAUDE.md said free lookups are never a question for the user, and replies still ended with "say 'check X' and I'll look", which handed the user a 2-minute `git show`. The hook fired 163 times in its first 5 weeks. Each fire goes to a log so you can measure false positives. The fires have not been hand-labeled yet, so its precision is unmeasured.

### session-age-guard

A UserPromptSubmit hook. Once the main transcript plus subagent transcripts reach 3 MB, it injects an instruction: tell the user the size in the first line of the next reply and recommend `/compact` or a fresh session. Past 8 MB it also sends a macOS notification. It warns at most once per session every 6 hours.

Failures:
- An age threshold (48 h, later 24 h) used the transcript's birth time. Resumed sessions made it fire on 61 of 65 sessions (94%), which was noise. Size fires on 6 of 65 (9%) and caught all three of the most expensive sessions.
- `-gt 15` missed an expensive session that sat at exactly 15 MB. The check uses `-ge` now.
- A stdout note is advisory, and the model absorbed it silently: the guard fired 41 times in one window, and the three sessions it fired in ran 2.7 to 4.8 more days. The text now orders the model to surface it, and the notification goes around the model to the user.

### skill-router

An example, not a finished product. A skill's description is a retrieval hint, not a trigger. One skill whose description said "use whenever writing backend code" fired 0 times in 90 days. This hook matches file paths and injects `additionalContext` once per session per rule. It never blocks and costs zero tokens until a path matches.

Sample rules in the file:
- A `.md` file named like `prd`, `spec`, `brief`, or `pitch`: invoke a spec skill and cite real buyer evidence.
- A file under `~/.claude/hooks/`, `~/.claude/skills/*/SKILL.md`, or `settings.json`: name the predicate, the guardrail error, and the rollback.
- A `Write` that creates a new `.tsx/.jsx/.vue/.svelte/.html` file: state the evidence and the success metric before you build.

Replace these with your own skills. Each rule should name the false fire it accepts and a kill condition.

## Tests

```
bash tests/run-all.sh
```

This runs the secret-scan regression cases (19), the visual-gate cases (6), and the sleep-guard cases (8). After you change `secret-scan`, add the line that motivated the change to `clean.txt` or `dirty.enc` (ROT13 plus line reversal; see `run.sh`, so the fake secrets do not trip push protection) before you change the regex.

## Design rules these hooks follow

- A predicate, not a classifier. Every hook here is a regex or a file check, so the regex itself is the ground truth for its behavior.
- Name the guardrail error. Each gate says whether it refuses false passes or false blocks and what each costs. The sleep guard accepts an occasional false block (one retry) to avoid a missed sleep (hours of wall clock).
- Say what to do instead. Every deny message names the working alternative, because a block with no alternative makes the model retry the same command.
- Measure the hook after it ships. Two hooks here changed after their first week of fires.

## License

MIT
