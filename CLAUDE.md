# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo holds two self-contained Bash scripts (Ubuntu/GNU-tool oriented, `set -euo pipefail`), both orchestrators that drive the `claude -p` CLI in a loop:

- `run_plan.bash` (~1600 lines) — turns requirements into a `plan.md` checklist, then runs one unchecked item per `claude` invocation until all are `- [x]`.
- `generate_spec.bash` (~1000 lines) — turns a rough requirement into a dev-ready, 10-section requirements spec document under `spec/`, then runs self-review/refine passes (`--refine-passes`) to elaborate it.

`generate_spec.bash` was written by copying `run_plan.bash`'s Slack notification/reply, usage-limit wait, and `[DECISION_REQUIRED]` decision-handling functions near-verbatim (see "Shared machinery" below) and replacing the step-loop (Phase 2) with a draft-then-refine flow over a single spec file. When changing that shared machinery in one script, check whether the other script needs the same fix.

All user-facing strings and prompts are in Korean; keep new messages/prompts in Korean to match.

There is no build, lint, or test setup and no git repo. To validate changes:

```bash
bash -n run_plan.bash                      # syntax check
bash -n generate_spec.bash
shellcheck run_plan.bash generate_spec.bash  # if installed
./run_plan.bash --dry-run -q "req"         # prints the claude command + prompts without calling claude
./generate_spec.bash --dry-run -q "req"    # same, for the spec generator
./run_plan.bash --check-env                # diagnose environment, then exit (generate_spec.bash has the same flag)
./run_plan.bash --init-sample              # write a sample plan.md and exit
./run_plan.bash --help                     # generate_spec.bash --help for the other script
```

`--dry-run` is the safest way to exercise prompt construction; note it exits after printing the first step's prompt (run_plan.bash) or the draft prompt (generate_spec.bash).

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
7. **`generate_spec.bash`'s flow** replaces steps 3–4 above with a single-target flow: `generate_spec_from_requirements` builds one draft prompt instructing Claude to write a fixed 10-section spec (`REQUIRED_SECTIONS`, numbered `## 1. 개요` … `## 10. 미결 이슈`) to an absolute `ABS_SPEC_FILE` under `spec/`, mirrors `locate_or_recover_plan_file` as `locate_or_recover_spec_file`, then `ensure_spec_sections` greps for each required `## N. 제목` and asks Claude (via `--continue`) to backfill any missing ones (bounded by `MAX_RETRIES`). It then runs `REFINE_PASSES` (default 1) self-review passes that re-diff the spec against the original requirements and codebase to fill gaps/edge cases before an optional `--auto-commit`. It reuses `run_claude_with_limit_guard`, `handle_decision_required`, and all Slack/limit functions verbatim from `run_plan.bash` (only user-facing labels/messages differ) — there is no `plan.md`-style checklist loop, so `MAX_STEPS`/exit code 2 don't apply here.

## Conventions and gotchas

- The script's control flow depends on Claude editing `plan.md` checkboxes and on log-text markers (`[DECISION_REQUIRED]`, limit-message regexes). Changing prompt wording, marker names, or the checkbox grep patterns (`^[[:space:]]*[-*][[:space:]]+\[...\]`) must be done consistently across the prompt text and the detection functions.
- Decision detection (`is_decision_required` / `extract_decision_block`) only accepts a *complete* block: opening and closing markers each alone on their own line, with at least one `선택지 N` line inside. A bare mention of the marker in prose must never trigger a prompt, so keep the marker string out of follow-up prompts, and keep the block format in `get_conflict_policy_instruction` in sync with this parser.
- Exit codes: 0 done, 1 error/step failed after retries, 2 `MAX_STEPS` reached (run_plan.bash only — generate_spec.bash has no step loop, so it never returns 2), 3 limit hit with `--no-limit-wait`, 4 paused for a decision.
- Functions that return values via globals: `CLAUDE_ARGS`, `LAST_CLAUDE_EXIT_CODE`, `USER_DECISION_INPUT`. Under `set -e`, `claude` calls are wrapped in `set +e`/`set -e` and use `PIPESTATUS[0]` because of the `| tee`.
- `trap '' HUP` is intentional so SSH disconnects don't kill long waits.
- Default permission strategy is `bypass` (`--dangerously-skip-permissions`); runs as root are auto-switched to `auto`.
- Intended use: install the script(s) somewhere on `PATH` and run from inside the target project folder. The base path is the caller's cwd (`WORK_DIR`), never the script's location: `plan.md`/`spec/`, `decisions.md`, `.claude-plan-logs/`|`.claude-spec-logs/` (logs, backups, lock) and the `claude` working dir all live in the project. Don't `cd` away or resolve paths relative to the script; use `SCRIPT_PATH` (symlink-resolved) only for self re-exec (`--tmux`, which starts the session in `WORK_DIR`).
- `generate_spec.bash`'s `REQUIRED_SECTIONS` array (the 10 section titles) is matched literally (`grep -qF "## ${sec}"`) in both the draft prompt and `ensure_spec_sections`/README's section list. If you rename or reorder a section, update all three together or the quality-check grep silently stops working.
