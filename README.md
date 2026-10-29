# run_plan.bash

Claude Code CLI(`claude -p`)를 반복 호출해 **요구사항 → `plan.md` 체크리스트 → 단계별 구현**을 자동으로 진행하는 Ubuntu용 Bash 스크립트입니다.

1. **계획 수립**: 요구사항(텍스트 / 파일 / stdin)을 받아 코드베이스를 분석하고 `- [ ] Step N: ...` 체크리스트가 담긴 `plan.md`를 생성합니다.
2. **단계별 실행**: 미완료 항목을 위에서부터 하나씩 `claude`에게 맡기고, 체크박스가 `- [x]`로 바뀔 때까지(필요하면 재시도) 반복합니다.
3. **스펙 충돌 / 설계 결정**: 에이전트가 `[DECISION_REQUIRED]` 블록을 출력하면 터미널 또는 Slack으로 물어보고 답변을 받아 이어서 진행합니다.
4. **사용량 한도 자동 대기**: Usage/Rate Limit에 걸리면 해제 시각을 계산해 대기한 뒤 중단된 지점부터 재개합니다.
5. **plan.md 복구**: 에이전트가 파일을 저장하지 않고 텍스트로만 출력한 경우 자동으로 탐색·복구합니다.

## 요구사항

- Ubuntu / Linux, Bash 4+
- [Claude Code CLI](https://code.claude.com/docs/en/cli-reference) (`claude`)
- `python3` (한도 해제 시각 파싱, Slack 연동), `curl` (Slack)
- 선택: `tmux`, `systemd-inhibit`(절전 방지), `notify-send`(데스크톱 알림), `flock`, `git`(`--auto-commit`)

`run_plan.bash --check-env`로 설치 상태를 진단할 수 있습니다.

## 설치와 기준 경로

스크립트를 `PATH`에 두고 **작업할 프로젝트 폴더에서 실행**합니다. 기준 경로는 항상 호출한 현재 디렉터리이며, 아래 산출물이 모두 그곳에 생깁니다.

```bash
install -m 755 run_plan.bash ~/.local/bin/run_plan.bash
cd ~/project/my-app
run_plan.bash --req-file spec.md
```

| 산출물 | 설명 |
|---|---|
| `plan.md` | 실행 계획 체크리스트 (`--plan`으로 변경) |
| `decisions.md` | 스펙 충돌 결정 기록 / ADR (`--decisions`로 변경) |
| `.claude-plan-logs/` | 단계별 로그, 이전 `plan.md` 백업, 중복 실행 방지 락 |

프로젝트 `.gitignore`에 `.claude-plan-logs/`를 추가해 두는 것을 권장합니다.

## 사용 예

```bash
# 요구사항 텍스트 / 파일 / 파이프
run_plan.bash "로그인 API에 rate limit 추가"
run_plan.bash --req-file spec.md
cat spec.md | run_plan.bash

# 계획만 만들고 검토 후 실행
run_plan.bash --req-file spec.md --plan-only
run_plan.bash                     # 기존 plan.md의 미완료 단계부터 실행

# 계획 확인 후 진행, 테스트 검증, 자동 커밋
run_plan.bash --req-file spec.md --confirm-plan --verify "pytest -q" --auto-commit

# 무인 실행: tmux 백그라운드 + 충돌 시 자율 결정
run_plan.bash --tmux --on-conflict auto --req-file spec.md

# 계획 수립 세션에서 plan.md 저장이 누락됐을 때 복구
run_plan.bash --recover-plan

# 실제 호출 없이 명령어와 프롬프트만 확인 (첫 단계 프롬프트 출력 후 종료)
run_plan.bash --dry-run -q "요구사항"
```

모든 옵션은 `run_plan.bash --help`에서 확인할 수 있고, 대부분 같은 이름의 환경변수(`PLAN_FILE`, `MAX_STEPS`, `MODEL` …)로도 지정할 수 있습니다.

## 주요 옵션

| 옵션 | 설명 |
|---|---|
| `-q, --req` / `-i, --req-file` | 요구사항 텍스트 / 파일 |
| `--plan-only`, `--confirm-plan`, `--append-plan` | 계획만 생성 / 확인 후 실행 / 기존 계획에 추가 |
| `-f, --plan`, `--decisions` | `plan.md`, `decisions.md` 경로 |
| `-s, --max-steps`, `-t, --max-turns`, `-r, --max-retries` | 최대 단계 수(30) / 단계당 턴(25) / 재시도(2) |
| `-p, --perm` | 권한 방식: `bypass`(기본, `--dangerously-skip-permissions`) · `auto` · `acceptEdits` · `allowed` |
| `-m, --model`, `--plan-model`, `--fallback-model` | 구현 / 계획 / 대체 모델 |
| `-b, --max-budget` | 호출당 최대 비용(USD) |
| `-v, --verify` | 단계마다 실행할 검증 명령 (실패 시 재시도) |
| `-g, --auto-commit` | 계획 및 각 단계 완료 후 git 커밋 |
| `--on-conflict ask\|pause\|auto` | 스펙 충돌 처리 방식 |
| `--no-limit-wait`, `-w`, `--limit-buffer` | 한도 도달 시 대기 안 함 / 기본 대기(분) / 여유(초) |
| `--tmux [세션명]`, `--no-inhibit`, `--check-env` | Ubuntu 전용 |

> 기본 권한 방식 `bypass`는 모든 도구 호출을 확인 없이 허용합니다. 신뢰할 수 있는 프로젝트에서만 사용하고, 불안하면 `--perm acceptEdits` 또는 `--perm allowed`를 쓰세요. root로 실행하면 자동으로 `auto`로 전환됩니다.

## 스펙 충돌 처리 (`--on-conflict`)

| 모드 | 동작 |
|---|---|
| `ask` (기본) | 선택지를 보여주고 답을 받아 즉시 재개. 터미널이 없으면 Slack 답변을 기다리고, Slack도 없으면 `pause` |
| `pause` | `decisions.md`에 기록하고 종료 코드 4로 정지. 이후 다시 실행하면 이어서 진행 |
| `auto` | 하위 호환성·보수적 기준으로 에이전트가 스스로 결정하고 `decisions.md`에 근거를 기록 |

답변 형식: `Enter`(Slack에서는 `1`) = 권장안, `2` = 선택지 2, `q` = 일시정지, 그 외 텍스트 = 직접 지침. 모든 결정은 `decisions.md`에 기록되어 이후 단계에서도 참조됩니다.

## Slack 연동

의사결정이 필요할 때 Slack으로 알림을 보내고 **스레드 답글**로 답변을 받습니다. 그 외에도 각 단계/Stage의 시작·종료와 전체 작업 완료(또는 중단) 시점마다 진행 상황을 Slack으로 단방향 알림(답글 불필요)으로 전달합니다 — `run_plan.bash`는 Phase 1(계획 수립)과 각 Step마다, `generate_spec.bash`는 Stage A~D와 각 문서(Step)마다 전송합니다. `SLACK_BOT_TOKEN`+`SLACK_CHANNEL` 또는 `SLACK_WEBHOOK_URL` 중 하나만 설정되어 있어도 동작하며, 전송에 실패해도 스크립트 흐름에는 영향을 주지 않습니다.

### 설정 방법 (Bot Token, 양방향)

1. **앱 만들기**: <https://api.slack.com/apps> → **Create New App** → **From scratch** → 앱 이름과 워크스페이스 선택
2. **권한 추가**: 왼쪽 **OAuth & Permissions** → **Bot Token Scopes**에 아래를 추가

   | Scope | 용도 |
   |---|---|
   | `chat:write` | 알림 및 확인 메시지 전송 |
   | `channels:history` | 공개 채널 스레드 답글 읽기 |
   | `groups:history` | 비공개 채널 스레드 답글 읽기 (비공개 채널을 쓸 때만) |

3. **설치**: 같은 페이지 위쪽 **Install to Workspace** → 허용. 발급된 **Bot User OAuth Token**(`xoxb-...`)을 복사합니다. (Scope를 나중에 바꾸면 **Reinstall**이 필요합니다.)
4. **봇 초대**: 알림을 받을 채널에서 `/invite @앱이름`
5. **채널 ID 확인**: 채널 이름 클릭 → **About** 탭 맨 아래의 `C0123456789` 형태 ID (채널 이름이 아니라 ID를 써야 합니다)
6. **환경변수 설정** 후 실행:

   ```bash
   export SLACK_BOT_TOKEN=xoxb-...
   export SLACK_CHANNEL=C0123456789
   run_plan.bash --req-file spec.md
   ```

   매번 입력하기 번거로우면 `~/.bashrc` 등에 넣거나, 토큰이 든 파일을 `source`하세요. 토큰은 프로젝트 저장소에 커밋하지 마세요. `--slack-token` 옵션은 프로세스 목록(`ps`)에 노출되므로 환경변수를 권장합니다.

### 연결 테스트

스크립트를 돌리기 전에 토큰과 채널이 맞는지 확인합니다.

```bash
# 토큰 유효성 (ok: true 이면 정상)
curl -s -H "Authorization: Bearer $SLACK_BOT_TOKEN" https://slack.com/api/auth.test

# 채널에 테스트 메시지 전송 (ok: true 와 ts 값이 나오면 정상)
curl -s -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer $SLACK_BOT_TOKEN" -H "Content-Type: application/json" \
  --data "{\"channel\":\"$SLACK_CHANNEL\",\"text\":\"run_plan 연결 테스트\"}"
```

### 알림 전용 (Webhook)

답변 수신이 필요 없으면 Bot Token 대신 Incoming Webhook만 써도 됩니다: 앱 설정의 **Incoming Webhooks**를 켜고 **Add New Webhook to Workspace**로 채널을 고른 뒤, 발급된 URL을 `SLACK_WEBHOOK_URL`(또는 `--slack-webhook`)로 지정합니다. 이 경우 알림 후 `pause`(종료 코드 4)로 정지합니다.

### 동작과 옵션

- 알림 메시지의 스레드에 `1` / `2` / 지침 텍스트 / `q`로 답글을 달면 스크립트가 주기적으로(`SLACK_POLL_INTERVAL`, 기본 10초) 확인해 재개합니다. 터미널이 열려 있으면 터미널 입력과 먼저 도착한 쪽을 사용합니다.
- `--slack-timeout <분>`: 답변 대기 제한 (기본 0 = 무제한, 초과 시 종료 코드 4).
- `--slack-webhook <URL>`: Incoming Webhook은 알림 전용이라 답변을 받을 수 없고, 알림 후 `pause`로 동작합니다.
- Slack 전송이 실패해도 경고만 출력하고 터미널 입력 / `pause`로 진행합니다.
- `--tmux`로 실행할 때 환경변수가 세션에 전달되는지 확인하세요. 이미 tmux 서버가 떠 있으면 현재 셸의 환경변수가 새 세션에 넘어가지 않을 수 있습니다. 알림이 오지 않으면 `~/.bashrc`에 `export`를 넣고 새 셸에서 실행하거나 tmux 안에서 직접 실행하세요.

### 문제 해결

오류는 `Slack API 오류: <코드>`로 표시됩니다.

| 코드 | 원인 / 해결 |
|---|---|
| `invalid_auth`, `not_authed` | 토큰이 틀렸거나 `xoxb-` 봇 토큰이 아님 |
| `channel_not_found` | 채널 이름이 아닌 ID를 쓰고 있거나 비공개 채널에 봇이 없음 |
| `not_in_channel` | 채널에서 `/invite @앱이름` 필요 |
| `missing_scope` | 위 Scope 추가 후 **Reinstall to Workspace** |
| 알림은 오는데 답글을 못 읽음 | `channels:history`(또는 `groups:history`) 누락, 또는 채널 메인이 아니라 **스레드 답글**로 달아야 함 |

## 종료 코드

| 코드 | 의미 |
|---|---|
| 0 | 모든 단계 완료 |
| 1 | 오류 또는 재시도 후에도 단계 실패 |
| 2 | 최대 단계 수(`--max-steps`) 도달 |
| 3 | 사용량 한도 도달 (`--no-limit-wait`) |
| 4 | 의사결정 대기로 일시 정지 |

## plan.md 형식

실행 단계는 줄 시작이 체크박스인 한 줄 제목이어야 합니다. 상세 내용은 별도 `### Step N` 섹션에 적으면 각 단계 실행 시 해당 섹션만 읽습니다.

```markdown
- [ ] Step 1: 프로젝트 구조 초기화
- [ ] Step 2: 핵심 모델 작성

### Step 1
대상 파일, 구현 내용, 검증 기준 ...
```

`run_plan.bash --init-sample`로 예시 `plan.md`를 만들 수 있습니다.

## 한도 대기

로그에서 `usage limit reached|<epoch>`, `retry-after`, `resets 3pm (Asia/Seoul)` 같은 패턴을 찾아 해제 시각을 계산합니다(Python3, 없으면 GNU `date`). 대기 중에는 `systemd-inhibit`으로 절전을 막고, 해제되면 `--continue`로 이어서 진행합니다. 한국 시간 표시가 필요하면 `sudo timedatectl set-timezone Asia/Seoul`을 설정하세요.

---

# generate_spec.bash

개략적인 요구사항(한 줄 메모 수준)을 받아 Claude Code CLI로 코드베이스를 분석하고, **개발에 바로 착수할 수 있는 요구사항 사양서 "문서 세트"**를 `spec/` 폴더에 생성하는 스크립트입니다. Slack 연동, 사용량 한도 자동 대기, 파일 생성 복구 등 `run_plan.bash`의 핵심 메커니즘을 그대로 공유합니다.

1. **문서 계획 수립**: 요구사항과 코드베이스를 분석해 필요한 문서 목록(개요, 기능 요구사항, 데이터/API 설계, 비기능 요구사항, 테스트 계획 등 — 규모에 맞게 가변적)과 `spec/` 아래 폴더 구조를 정하고, `spec-plan.md` 체크리스트로 저장합니다.
2. **문서별 생성 + 자기 검증**: `spec-plan.md`의 미완료 문서를 하나씩 Claude에게 맡겨 실제 파일로 작성시키고, 같은 호출 안에서 그 문서 자체를 자기 검증·보완한 뒤 체크박스를 완료로 표시합니다. 모든 문서가 끝날 때까지 반복합니다.
3. **문서간 충돌 검증**: 모든 문서가 완성되면 `spec/` 전체를 다시 읽혀 문서 간 모순(동일 항목에 대한 서로 다른 설명, 용어/ID 불일치, 끊어진 참조 등)을 찾아 직접 수정하게 합니다.
4. **최종 중복/충돌 검사 및 최적화**: 마지막으로 전체 문서 세트를 한 번 더 검토해 중복 내용을 정리하고 남은 충돌을 해소하며, 문서 목록을 안내하는 `spec/README.md` 인덱스를 만듭니다.
5. **요구사항 모호성/충돌**: 위 모든 단계에서 요구사항 자체가 모순되거나 핵심 비즈니스 결정이 필요한 경우 `run_plan.bash`와 동일한 `[DECISION_REQUIRED]` + `decisions.md` + Slack 흐름으로 처리합니다.
6. **사용량 한도 자동 대기**: Usage/Rate Limit에 걸리면 해제 시각을 계산해 대기한 뒤 `--continue`로 재개합니다.
7. **계획/문서 복구**: 에이전트가 파일을 저장하지 않고 텍스트로만 출력한 경우 자동 탐색·복구하며, `--recover-plan`으로 직전 세션에서 즉시 복구할 수 있습니다.

## 사용 예

```bash
# 요구사항으로 전체 흐름 실행 (계획 → 문서별 생성/검증 → 충돌 검증 → 최적화)
./generate_spec.bash "모바일 앱에 푸시 알림 기능 추가"
./generate_spec.bash --req-file memo.md
cat memo.md | ./generate_spec.bash

# 계획(spec-plan.md + 폴더 구조)만 만들고 검토 후 생성 시작
./generate_spec.bash --req-file memo.md --plan-only
./generate_spec.bash                      # 기존 spec-plan.md의 미완료 문서부터 이어서 생성

# 계획 확인 후 진행, 완료 시 자동 커밋
./generate_spec.bash --req-file memo.md --confirm-plan --auto-commit

# 완전 무인 실행: 모호성 발생 시 보수적 기준으로 자율 결정
./generate_spec.bash --tmux --on-conflict auto --req-file memo.md

# 계획 파일 저장이 누락됐을 때 직전 세션에서 복구
./generate_spec.bash --recover-plan

# 실제 호출 없이 계획 수립 명령어/프롬프트만 확인
./generate_spec.bash --dry-run -q "요구사항"

# 생성된 문서 중 하나로 run_plan.bash 구현 시작
run_plan.bash --req-file spec/02-functional-requirements.md
```

## 주요 옵션

| 옵션 | 설명 |
|---|---|
| `-q, --req` / `-i, --req-file` | 요구사항 텍스트 / 파일 |
| `--spec-dir`, `-f, --plan` | 문서 저장 폴더(기본 `spec`) / 계획 체크리스트 파일(기본 `spec-plan.md`) |
| `--append-plan` | 기존 계획 끝에 새 요구사항에 대한 문서 항목 추가 (기본은 새 계획 생성) |
| `--plan-only`, `--confirm-plan`, `--plan-model` | 계획만 생성 후 종료 / 확인 후 진행 / 계획 수립용 모델 |
| `--recover-plan` | 직전 세션에서 계획 파일 복구 후 이어서 진행 |
| `-s, --max-steps`, `-r, --max-retries` | 1회 실행당 최대 문서 수(기본 20) / 문서별 재시도 횟수 |
| `--no-cross-check`, `--no-optimize` | 문서간 충돌 검증 / 최종 중복·충돌 검사+최적화 단계 생략 |
| `-m, --model`, `--fallback-model`, `-t, --max-turns` | 문서 생성/검증용 모델, 대체 모델, 호출당 최대 턴 |
| `-p, --perm`, `-b, --max-budget`, `-g, --auto-commit` | `run_plan.bash`와 동일 |
| `--on-conflict ask\|pause\|auto`, `--decisions` | 요구사항 모호성/충돌 처리 방식, 결정 기록 파일 |
| Slack / 한도 대기 / Ubuntu 옵션 | `--slack-token`, `--slack-channel`, `--slack-webhook`, `-w/--limit-wait`, `--tmux`, `--check-env` 등 `run_plan.bash`와 동일 |

전체 옵션은 `generate_spec.bash --help`에서 확인할 수 있습니다. Slack 연동 설정·문제 해결 방법은 위 [Slack 연동](#slack-연동) 절을 그대로 참고하세요(두 스크립트가 같은 환경변수를 씁니다).

## spec-plan.md 형식

`plan.md`와 같은 체크박스 규칙을 쓰되, 문서 단위를 가리킵니다. 각 `Step N`의 상세 섹션에는 저장할 **파일 경로**가 반드시 있어야 하며, 스크립트가 이 경로로 폴더를 만들고 문서 생성 결과를 검증합니다.

```markdown
- [ ] Step 1: 개요 및 범위
- [ ] Step 2: 기능 요구사항

### Step 1
- 파일 경로: spec/01-overview.md
- 목적: ...
- 포함할 내용(개요): ...
- 의존 문서: 없음
- 문서별 검증 기준: ...

### Step 2
- 파일 경로: spec/02-functional-requirements.md
- 의존 문서: Step 1
...
```

## 종료 코드

| 코드 | 의미 |
|---|---|
| 0 | 문서 세트 생성(계획 → 문서별 생성/검증 → 충돌 검증 → 최적화) 완료 |
| 1 | 오류 (요구사항 없음, 계획/문서 생성 실패, 재시도 소진 등) |
| 2 | 최대 문서 수(`--max-steps`) 도달 — 같은 명령으로 재실행하면 이어서 생성 |
| 3 | 사용량 한도 도달 (`--no-limit-wait`) |
| 4 | 의사결정 대기로 일시 정지 |

---

# loop_task.bash

`task/open/` 폴더를 계속 감시하다가 요구사항 md 문서가 들어오면 `run_plan.bash`에 전달해 자동으로 구현을 진행시키는 **데몬 스크립트**입니다. 문서를 큐에 넣어두기만 하면 되는 "요구사항 투입 → 자동 구현" 파이프라인을 만들어 줍니다.

1. **모니터링**: `task/open/`을 계속 감시합니다(`inotifywait` 설치 시 즉시 감지, 없으면 `--poll-interval`초 폴링).
2. **진행 중 표시**: 새 문서를 발견하면 `task/in-progress/`로 옮기고 `run_plan.bash --req-file <문서>`로 계획 수립부터 단계별 구현까지 맡깁니다.
3. **완료 처리**: `run_plan.bash`가 종료 코드 0(모든 단계 완료)으로 끝나면 문서를 `task/close/`로 옮깁니다. 그 외 종료 코드면 문서를 `task/in-progress/`에 그대로 두고 `--fail-retry-delay`초 후 다시 시도합니다.
4. **재개**: 데몬을 (재)시작할 때 `task/in-progress/`에 문서가 이미 있으면 완료되지 못한 이전 작업으로 간주해, 그 문서는 다시 옮기지 않고 `run_plan.bash`를 요구사항 없이 호출해 기존 `plan.md`를 이어서 진행합니다 (한 번에 한 작업만 진행 — `in-progress`가 비어 있어야 `open`의 다음 문서를 집어갑니다).
5. **비동기 실행**: 다른 두 스크립트와 동일한 `--tmux` 옵션으로 데몬을 detached tmux 세션에서 백그라운드로 띄울 수 있고, `--stop`/`--status`로 PID 파일 기준 제어가 가능합니다.

`run_plan.bash`가 자식 프로세스로 실행되므로, `SLACK_BOT_TOKEN`/`SLACK_CHANNEL` 등 환경변수를 export해 두면 각 작업의 Phase/Step 진행 상황과 의사결정 알림이 평소와 동일하게 Slack으로도 전달됩니다 — `loop_task.bash` 자체는 별도 Slack 연동이 필요 없습니다.

## 사용 예

```bash
# 포그라운드에서 데몬 실행 (Ctrl+C로 종료)
./loop_task.bash

# tmux 백그라운드 세션에서 시작, 작업마다 자동 커밋 + 충돌 시 자율 결정
# ('--' 뒤의 옵션은 매 작업마다 run_plan.bash 호출에 그대로 전달됩니다)
./loop_task.bash --tmux -- --auto-commit --on-conflict auto

# 상태 확인 / 종료
./loop_task.bash --status
./loop_task.bash --stop

# 대기/미완료 작업을 하나만 처리하고 종료 (cron, 디버깅)
./loop_task.bash --once

# 실제로 옮기거나 호출하지 않고 지금 상태에서 어떤 동작이 일어날지만 확인
./loop_task.bash --dry-run

# 요구사항 문서를 큐에 투입
echo "로그인 API에 rate limit 추가" > task/open/rate-limit.md
```

## 주요 옵션

| 옵션 | 설명 |
|---|---|
| `--task-dir` | 작업 큐 폴더 (기본 `task`; 하위 `open`/`in-progress`/`close` 자동 생성) |
| `--poll-interval` | `task/open` 확인 주기(초, 기본 10) — `inotifywait` 설치 시 더 빠르게 감지 |
| `--fail-retry-delay` | 실패/중단 후 재시도 전 대기 시간(초, 기본 60) |
| `--run-plan-bin` | `run_plan.bash` 경로 직접 지정 (기본: PATH 탐색 → 이 스크립트와 같은 폴더) |
| `--run-plan-log-dir` | `run_plan.bash`의 `LOG_DIR` 경로 (기본 `.claude-plan-logs`) — 락 파일 위치 확인용, 커스터마이즈했다면 맞춰야 함 |
| `--once` | 대기 중인 작업을 최대 1개(재개 포함)만 처리하고 종료 |
| `--tmux [세션명]`, `--stop`, `--status` | tmux 백그라운드 시작 / PID 파일 기준 종료·상태 확인 |
| `--check-env`, `--dry-run` | 환경 진단 / 실제 이동·호출 없이 동작 미리보기 |
| `-- <run_plan.bash 옵션...>` | 매 작업마다 `run_plan.bash` 호출에 그대로 추가되는 옵션 (예: `--auto-commit`, `--on-conflict auto`, `-m opus` 등 모든 옵션 가능) |

## 디렉터리 구조

```
task/
├── open/         # 요구사항 md 문서를 넣어두는 곳 (사용자가 채움)
├── in-progress/  # 현재 run_plan.bash가 작업 중인 문서 (최대 1개)
└── close/        # run_plan.bash가 모든 단계를 완료한 문서
```

같은 폴더에서 동시에 데몬이 두 개 뜨는 것은 `flock`(`.claude-loop-task-logs/loop_task.lock`)으로 막혀 있습니다. `run_plan.bash`도 자체적으로 작업 디렉터리당 하나의 인스턴스만 허용하므로, `loop_task.bash`는 언제나 "한 번에 하나의 작업"만 진행합니다.

### 재개 체크는 매번 돌지만, 중복 실행은 되지 않습니다

`task/in-progress/` 확인은 최초 1회가 아니라 **루프를 돌 때마다** 수행됩니다. 다만 `run_plan.bash` 호출이 동기(blocking)라서, 한 작업이 끝나기 전에는(`process_requirement_doc`가 리턴하기 전에는) 같은 데몬이 다음 반복으로 넘어가지 않으므로 같은 파일을 중복으로 처리하는 경로 자체가 없습니다.

유일하게 신경 쓸 부분은 데몬 자체가 비정상 종료(`kill -9` 등)된 경우입니다. `run_plan.bash`는 `trap '' HUP`으로 SIGHUP을 무시하므로, 부모(`loop_task.bash`)가 죽어도 그 자식 프로세스는 orphan으로 계속 살아있을 수 있습니다. 이 상태에서 데몬을 재시작하면, `run_plan.bash`를 다시 호출하기 전에 `run_plan.bash` 자신의 락 파일(`<RUN_PLAN_LOG_DIR>/run_plan.lock`, 기본 `.claude-plan-logs/run_plan.lock`)이 아직 잡혀 있는지 먼저 확인합니다. 잡혀 있으면 실패로 집계하지 않고 `--poll-interval`마다 조용히 재확인만 하다가, 락이 풀리는 즉시(orphan 프로세스가 끝나는 즉시) 이어서 진행합니다. `run_plan.bash`의 `LOG_DIR`을 환경변수로 커스터마이즈했다면 `--run-plan-log-dir`(또는 `RUN_PLAN_LOG_DIR` 환경변수)을 같은 값으로 맞춰야 이 감지가 정확히 동작합니다. `--check-env`로 현재 락 상태를 바로 확인할 수 있습니다.
