# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo is a single self-contained Bash script, `run_plan.bash` (~1400 lines, Ubuntu/GNU-tool oriented, `set -euo pipefail`). It is an orchestrator that drives the `claude -p` CLI in a loop: it turns requirements into a `plan.md` checklist, then runs one unchecked item per `claude` invocation until all are `- [x]`. All user-facing strings and prompts are in Korean; keep new messages/prompts in Korean to match.

There is no build, lint, or test setup and no git repo. To validate changes:

```bash
bash -n run_plan.bash                 # syntax check
shellcheck run_plan.bash              # if installed
./run_plan.bash --dry-run -q "req"    # prints the claude command + prompts without calling claude
./run_plan.bash --check-env           # diagnose environment, then exit
./run_plan.bash --init-sample         # write a sample plan.md and exit
./run_plan.bash --help
```

`--dry-run` is the safest way to exercise prompt construction; note it exits after printing the first step's prompt.

## Architecture

Flow of the script, top to bottom:

1. **Config + arg parsing** — every setting is an env var with a default (`PLAN_FILE`, `ON_CONFLICT`, `PERMISSION_STRATEGY`, `MAX_STEPS`, …) that a CLI flag overrides. New options need a default at the top, a `case` arm in the parser, and a line in `usage()`.
2. **Preflight** — optional `--tmux` re-exec (strips `--tmux [name]` from `ORIGINAL_ARGS` and relaunches in a detached tmux session), requirements gathering (positional/`-q`, `-i` file, stdin — concatenated in that order), root→`auto` permission downgrade, and an `flock` on `$LOG_DIR/run_plan.lock` to prevent concurrent runs in the same directory.
3. **Phase 1 (`generate_plan_from_requirements`)** — asks Claude to write `plan.md` at an *absolute* path. Plan format contract: executable steps are `- [ ] Step N: short title` lines (≤80 chars, no ` — ` detail), with detail in separate `### Step N` sections that step prompts grep for. `locate_or_recover_plan_file` handles the common failure where Claude only prints the plan: it searches for a misplaced plan.md (git root, or depth ≤3 modified in last 30 min), then falls back to a `--continue` prompt telling Claude to actually write the file. `ensure_checkbox_format` asks Claude to normalize plans that lack checkboxes.
4. **Phase 2 loop** — each iteration: `get_next_task` (first `- [ ]` line via grep) → build prompt → `run_claude_with_limit_guard` → success is judged by the script, not Claude: exit code 0, optional `--verify` command passing, **and** the same task no longer being the first unchecked item. Retries up to `MAX_RETRIES` with a reinforced prompt; then exits 1. Optional per-step `git commit` (`--auto-commit`).
5. **`run_claude_with_limit_guard`** — the core wrapper around `claude`. It tees output to a log in `$LOG_DIR` and then greps the log (not exit codes) for two conditions, looping on either:
   - **Usage/rate limit** (`is_usage_limit_reached` regex) → `calculate_limit_wait_seconds` (embedded Python3 heredoc parses epoch / retry-after / "resets 3pm (Zone)"; GNU `date` fallback if no python) → `wait_for_limit_reset` (countdown, `systemd-inhibit` sleep guard) → resume with `--continue` and a wrapped prompt.
   - **`[DECISION_REQUIRED]…[/DECISION_REQUIRED]` block** (spec conflict) → `handle_decision_required`: `pause` (or non-TTY) exits 4; `ask` reads from the terminal, appends the answer to `decisions.md`, and resumes via `--continue` with a short follow-up prompt (deliberately does *not* resend the original conflict instructions). With Slack configured (`SLACK_BOT_TOKEN`+`SLACK_CHANNEL`, or notify-only `SLACK_WEBHOOK_URL`), it also posts the block via `slack_post`; with a bot token (and not `pause` mode) it polls the message thread via `slack_fetch_reply` (`conversations.replies`, first non-bot reply) racing against terminal input, so non-TTY runs are answered from Slack instead of exiting 4. Replies use the same `1`/`2`/free-text/`q` grammar; helpers use `curl` + `python3`. `auto` mode instead instructs Claude (via `get_conflict_policy_instruction`) to decide itself and write an ADR to `decisions.md`.
6. **`build_claude_args`** — the single place that assembles `CLAUDE_ARGS` (`-p`, `--max-turns`, permission flags, model/fallback/budget, `--continue`). It sets a global array, so call it right before `claude`.

## Conventions and gotchas

- The script's control flow depends on Claude editing `plan.md` checkboxes and on log-text markers (`[DECISION_REQUIRED]`, limit-message regexes). Changing prompt wording, marker names, or the checkbox grep patterns (`^[[:space:]]*[-*][[:space:]]+\[...\]`) must be done consistently across the prompt text and the detection functions.
- Exit codes: 0 done, 1 error/step failed after retries, 2 `MAX_STEPS` reached, 3 limit hit with `--no-limit-wait`, 4 paused for a decision.
- Functions that return values via globals: `CLAUDE_ARGS`, `LAST_CLAUDE_EXIT_CODE`, `USER_DECISION_INPUT`. Under `set -e`, `claude` calls are wrapped in `set +e`/`set -e` and use `PIPESTATUS[0]` because of the `| tee`.
- `trap '' HUP` is intentional so SSH disconnects don't kill long waits.
- Default permission strategy is `bypass` (`--dangerously-skip-permissions`); runs as root are auto-switched to `auto`.
- Intended use: install `run_plan.bash` somewhere on `PATH` and run it from inside the target project folder. The base path is the caller's cwd (`WORK_DIR`), never the script's location: `plan.md`, `decisions.md`, `.claude-plan-logs/` (step logs, plan backups, lock) and the `claude` working dir all live in the project. Don't `cd` away or resolve paths relative to the script; use `SCRIPT_PATH` (symlink-resolved) only for self re-exec (`--tmux`, which starts the session in `WORK_DIR`).
