# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo holds two self-contained Bash scripts (Ubuntu/GNU-tool oriented, `set -euo pipefail`), both orchestrators that drive the `claude -p` CLI in a loop:

- `run_plan.bash` (~1600 lines) — turns requirements into a `plan.md` checklist, then runs one unchecked item per `claude` invocation until all are `- [x]`.
- `generate_spec.bash` (~1800 lines) — turns a rough requirement into a dev-ready requirements spec **document set** under `spec/`: it plans which documents are needed and where they live (`spec-plan.md`), generates + self-validates each one in a `plan.md`-style checklist loop, then runs two whole-set passes (cross-document conflict check, final dedup/optimize).

`generate_spec.bash` was written by copying `run_plan.bash`'s Slack notification/reply, usage-limit wait, `build_claude_args`, and `[DECISION_REQUIRED]` decision-handling functions near-verbatim, and reshaping its own Phase 1/Phase 2 split to operate on a document-plan file (`spec-plan.md`) instead of `plan.md`, plus two extra whole-set stages after the loop. When changing that shared machinery in one script, check whether the other script needs the same fix.

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

`generate_spec.bash` reuses steps 2, 5, 6 above verbatim (Slack, usage-limit wait, `build_claude_args`) but replaces steps 3–4 with its own four-stage flow, all driven by the same `run_claude_with_limit_guard`:

- **Stage A — `generate_spec_plan`** mirrors Phase 1: it asks Claude to decide how many documents are needed (variable, not fixed) and write `spec-plan.md` as a `plan.md`-style checklist (`- [ ] Step N: <document title>`), but each `### Step N` detail section must also carry a `파일 경로:` line (relative path under `spec/`), plus `목적`/`포함할 내용`/`의존 문서`/`문서별 검증 기준`. `locate_or_recover_spec_plan_file` mirrors `locate_or_recover_plan_file`. `ensure_plan_checkbox_format` mirrors `ensure_checkbox_format` but also re-requests any `### Step N` missing its `파일 경로:` line. `create_spec_folder_structure` then walks every Step's path (via `get_all_step_numbers` + `get_step_filepath`, both parsing `spec-plan.md` with `awk`) and `mkdir -p`s each one up front.
- **Stage B — `run_document_step`** mirrors Phase 2's loop body: for the first unchecked Step, it resolves the Step's file path (`get_step_filepath` → `resolve_step_abs_path`, relative to `WORK_DIR`), then sends one prompt that asks Claude to (1) write that one document, (2) self-validate it against its own `### Step N` section in the same turn (this *is* "문서별 검증" — no separate call), and (3) flip only that Step's checkbox in `spec-plan.md`. Success is judged by the script exactly like Phase 2: exit 0, doc file non-empty, and the Step no longer first-unchecked; retried up to `MAX_RETRIES` with a reinforced prompt.
- **Stage C — `cross_document_conflict_check`** (skippable via `--no-cross-check`) runs once, after every Step is checked: one call that hands Claude the full `find spec/ -name '*.md'` listing and has it read everything and fix cross-document contradictions/inconsistent terminology/broken references directly.
- **Stage D — `final_optimize_documents`** (skippable via `--no-optimize`) runs last: a second whole-set pass that removes duplication across documents, re-checks for any remaining conflicts, and writes `spec/README.md` as a reading-order index.

Both Stage C and Stage D can themselves hit `[DECISION_REQUIRED]` or a usage limit, since they also go through `run_claude_with_limit_guard`. `get_conflict_policy_instruction` takes a `target_desc` argument (e.g. `"'${doc_abs}'"` or `"'${ABS_SPEC_DIR}' 내 관련 문서들"`) instead of hardcoding one file, since the "작업 대상" differs per stage. Because there *is* a checklist loop again (over documents, not code steps), `MAX_STEPS`/exit code 2 apply here too, same as `run_plan.bash` — re-running after a `MAX_STEPS` stop resumes mid-checklist and only runs Stage C/D once `spec-plan.md` has zero remaining items.

## Conventions and gotchas

- The script's control flow depends on Claude editing `plan.md` checkboxes and on log-text markers (`[DECISION_REQUIRED]`, limit-message regexes). Changing prompt wording, marker names, or the checkbox grep patterns (`^[[:space:]]*[-*][[:space:]]+\[...\]`) must be done consistently across the prompt text and the detection functions.
- Decision detection (`is_decision_required` / `extract_decision_block`) only accepts a *complete* block: opening and closing markers each alone on their own line, with at least one `선택지 N` line inside. A bare mention of the marker in prose must never trigger a prompt, so keep the marker string out of follow-up prompts, and keep the block format in `get_conflict_policy_instruction` in sync with this parser.
- Exit codes: 0 done, 1 error/step failed after retries, 2 `MAX_STEPS` reached (both scripts — for generate_spec.bash this means documents, and Stage C/D are skipped until a later run finishes the checklist), 3 limit hit with `--no-limit-wait`, 4 paused for a decision.
- Functions that return values via globals: `CLAUDE_ARGS`, `LAST_CLAUDE_EXIT_CODE`, `USER_DECISION_INPUT`. Under `set -e`, `claude` calls are wrapped in `set +e`/`set -e` and use `PIPESTATUS[0]` because of the `| tee`.
- `trap '' HUP` is intentional so SSH disconnects don't kill long waits.
- Default permission strategy is `bypass` (`--dangerously-skip-permissions`); runs as root are auto-switched to `auto`.
- Intended use: install the script(s) somewhere on `PATH` and run from inside the target project folder. The base path is the caller's cwd (`WORK_DIR`), never the script's location: `plan.md`/`spec/`, `decisions.md`, `.claude-plan-logs/`|`.claude-spec-logs/` (logs, backups, lock) and the `claude` working dir all live in the project. Don't `cd` away or resolve paths relative to the script; use `SCRIPT_PATH` (symlink-resolved) only for self re-exec (`--tmux`, which starts the session in `WORK_DIR`).
- `generate_spec.bash`'s `get_step_filepath` parses `### Step N` → `파일 경로:` with `awk`, using mawk (Ubuntu's default `/usr/bin/awk`), not gawk. mawk mishandles multi-byte UTF-8 characters inside bracket expressions (`[^:：]` silently matches wrong byte offsets); the fix was to find the colon with `index()` instead of a `[^:：]` regex. Avoid introducing new `[^...]`/`[...]` character classes containing non-ASCII characters anywhere in this file's `awk` scripts — test with plain `/usr/bin/awk`, not just gawk, since gawk won't reproduce the bug.
- `generate_spec.bash`'s `spec-plan.md` checkbox/Step-number grep patterns (`^[[:space:]]*[-*][[:space:]]+\[...\]`, `Step[[:space:]]+[0-9]+:`) are the same family as `run_plan.bash`'s `plan.md` patterns — kept deliberately so `count_remaining_tasks`/`count_completed_tasks`/`get_next_task` work unchanged on either file (they just take the file path as an argument now instead of reading a global). The one new format rule is the `### Step N` section's `파일 경로:` line, which must stay literally spelled that way (or `get_step_filepath`'s `grab`/match logic and the planning/normalize prompts need to change together).
