#!/usr/bin/env bash
# ==============================================================================
# run_plan.sh - Ubuntu 환경 최적화 Claude Code CLI 자동 계획 수립 및 단계별 실행 스크립트
#
# 설명:
#   1. [계획 수립 단계] 사용자 요구사항(문자열, 파일, 표준입력)을 전달받아 현재 코드베이스를
#      분석하고, 실행 가능한 체크리스트(- [ ])가 포함된 plan.md를 자동으로 생성합니다.
#   2. [단계별 실행 단계] 생성된 plan.md의 미완료 항목(- [ ])을 위에서부터 하나씩 감지하여,
#      모든 항목이 완료(- [x])될 때까지 Claude Code CLI(claude -p)를 반복 실행합니다.
#   3. [스펙 충돌 및 의사결정 처리] 요구사항(Spec)과 기존 코드가 충돌하거나 설계 결정이 필요한
#      상황이 발생하면 [DECISION_REQUIRED] 마커와 decisions.md 파일을 통해:
#      - ask   : 터미널에서 사용자에게 선택지를 제시하고 답변을 받아 즉시 이어서 진행
#      - pause : decisions.md에 질문과 선택지를 기록하고 안전하게 일시 정지 (종료 코드 4)
#      - auto  : 하위 호환성과 보수적 기준에 따라 자율 결정 후 decisions.md에 근거(ADR) 기록
#   4. [토큰 한도 자동 대기 및 재개] 실행 중 토큰 소진(Usage Limit / 429 Rate Limit)이
#      발생하면 해제 시각을 자동 계산(Python3 + Ubuntu GNU date 이중 파서)하여 대기한 뒤
#      중단된 단계부터 이어서 진행합니다.
#   5. [파일 생성 검증 및 자동 복구] Claude가 텍스트로만 계획을 출력하고 실제 디스크에
#      plan.md를 저장하지 않았거나 하위/상위 폴더에 저장한 경우 이를 자동 탐색·복구합니다.
#
# 참고 문서:
#   - Claude Code CLI Reference: https://code.claude.com/docs/en/cli-reference
#   - Permission Modes: https://code.claude.com/docs/en/permission-modes
#   - Best Practices: https://code.claude.com/docs/en/best-practices
#   - Usage Limit Reference: https://github.com/anthropics/claude-code/issues/2087
# ==============================================================================

set -euo pipefail

# SSH 세션이 끊어져도(SIGHUP) 대기 루프나 실행 중인 작업이 중단되지 않도록 보호
trap '' HUP

# 기본 설정값 (환경변수로도 오버라이드 가능)
PLAN_FILE="${PLAN_FILE:-plan.md}"
DECISIONS_FILE="${DECISIONS_FILE:-decisions.md}"
REQUIREMENTS="${REQUIREMENTS:-}"
REQ_FILE="${REQ_FILE:-}"
PLAN_MODE_ACTION="${PLAN_MODE_ACTION:-overwrite}" # overwrite | append
PLAN_ONLY="${PLAN_ONLY:-false}"
CONFIRM_PLAN="${CONFIRM_PLAN:-false}"
RECOVER_LAST_PLAN="${RECOVER_LAST_PLAN:-false}"
ON_CONFLICT="${ON_CONFLICT:-ask}"                 # ask | pause | auto
MAX_STEPS="${MAX_STEPS:-30}"
MAX_TURNS="${MAX_TURNS:-25}"
PLAN_MAX_TURNS="${PLAN_MAX_TURNS:-60}"            # Phase 1(계획 수립) 전용 최대 턴 수
MAX_RETRIES="${MAX_RETRIES:-2}"
PERMISSION_STRATEGY="${PERMISSION_STRATEGY:-bypass}" # bypass | auto | acceptEdits | allowed
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Edit,Write}"
MODEL="${MODEL:-}"
PLAN_MODEL="${PLAN_MODEL:-}"
FALLBACK_MODEL="${FALLBACK_MODEL:-}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"
CONTINUE_SESSION="${CONTINUE_SESSION:-false}"
AUTO_COMMIT="${AUTO_COMMIT:-false}"
VERIFY_CMD="${VERIFY_CMD:-}"
LOG_DIR="${LOG_DIR:-.claude-plan-logs}"
DRY_RUN="false"

# Slack 연동 설정 (의사결정 필요 시 알림 + 스레드 답글로 답변 수신)
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"                 # xoxb-... (scopes: chat:write, channels:history 또는 groups:history)
SLACK_CHANNEL="${SLACK_CHANNEL:-}"                     # 채널 ID (예: C0123456789). 봇이 채널에 초대되어 있어야 함
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"             # 알림 전용(답변 수신 불가). 토큰/채널 미설정 시 사용
SLACK_POLL_INTERVAL="${SLACK_POLL_INTERVAL:-10}"       # 답글 확인 주기(초)
SLACK_REPLY_TIMEOUT="${SLACK_REPLY_TIMEOUT:-0}"        # 답변 대기 제한(분). 0 = 무제한, 초과 시 pause(종료 코드 4)

# 토큰/사용량 한도(Usage Limit) 대기 관련 설정
WAIT_ON_LIMIT="${WAIT_ON_LIMIT:-true}"
LIMIT_FALLBACK_MINUTES="${LIMIT_FALLBACK_MINUTES:-15}" # 해제 시각 파싱 불가 시 기본 대기(분)
LIMIT_BUFFER_SECONDS="${LIMIT_BUFFER_SECONDS:-60}"     # 해제 시각 이후 안전 여유 시간(초)
MAX_LIMIT_WAITS="${MAX_LIMIT_WAITS:-24}"               # 단계당 최대 한도 대기 횟수
RESUME_ON_LIMIT_WAKE="${RESUME_ON_LIMIT_WAKE:-true}"   # 한도 해제 후 재개 시 --continue 활용 여부

# Ubuntu 전용 설정
USE_TMUX="${USE_TMUX:-false}"
TMUX_SESSION_NAME="${TMUX_SESSION_NAME:-claude-plan}"
INHIBIT_SLEEP="${INHIBIT_SLEEP:-true}"                 # systemd-inhibit 절전 방지 사용 여부
ENABLE_NOTIFY="${ENABLE_NOTIFY:-true}"                 # Ubuntu notify-send 데스크톱 알림 여부
CHECK_ENV_ONLY="false"

# 색상 출력 설정
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

ORIGINAL_ARGS=("$@")

# 기준 경로(Base Path): 스크립트를 호출한 현재 디렉터리(프로젝트 폴더).
# 스크립트 자체는 PATH 어디에 있어도 되며, plan.md / decisions.md / 로그 / claude 작업 디렉터리는
# 모두 호출 위치 기준이다. (SCRIPT_PATH는 --tmux 재실행용 스크립트 실제 경로)
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
사용법:
  $(basename "$0") [옵션] ["요구사항 텍스트"]

요구사항 및 계획 수립 옵션:
  -q, --req <요구사항>          구현할 요구사항 텍스트 (위치 인자로도 전달 가능)
  -i, --req-file <파일경로>     요구사항이 적힌 문서/명세서 파일 경로 (예: spec.md)
      --append-plan             기존 ${PLAN_FILE} 끝에 새 요구사항에 대한 단계들을 추가
      --plan-only               요구사항을 분석해 ${PLAN_FILE}만 생성하고 실행 전 종료
      --confirm-plan            ${PLAN_FILE} 생성 후 내용을 출력하고 사용자 확인(Y/n) 후 실행
      --plan-model <모델명>     계획 수립 단계에 사용할 모델 지정 (예: opus)
      --recover-plan            직전 세션(--continue)에서 작성된 계획을 ${PLAN_FILE}로 즉시 복구 후 진행
      --init-sample             예시 ${PLAN_FILE} 파일을 생성하고 종료

스펙 충돌 및 의사결정(Decision) 제어 옵션:
      --on-conflict <모드>      스펙 충돌이나 설계 결정이 필요할 때의 처리 방식 (기본값: ask)
                                  - ask   : 터미널에서 선택지를 보여주고 사용자 입력을 받아 즉시 재개
                                            (비대화형 백그라운드 실행 시에는 자동으로 pause로 동작)
                                  - pause : ${DECISIONS_FILE}에 충돌 내용과 선택지를 기록하고 일시 정지
                                  - auto  : 하위 호환성·보수적 설계를 기준으로 자율 결정 후
                                            ${DECISIONS_FILE}에 결정 근거(ADR)를 남기고 계속 진행
      --decisions <파일경로>    의사결정 기록 및 지침 파일 경로 (기본값: decisions.md)

단계별 실행 및 제어 옵션:
  -f, --plan <파일경로>         계획 파일 경로 (기본값: plan.md)
  -s, --max-steps <숫자>        최대 단계 반복 횟수 (기본값: 30)
  -t, --max-turns <숫자>        단계당 최대 에이전트 턴 수 (--max-turns, 기본값: 25)
      --plan-turns <숫자>       계획 수립(Phase 1) 최대 턴 수 (기본값: 60)
  -r, --max-retries <숫자>      단계 미완료/오류 시 최대 재시도 횟수 (기본값: 2)
  -p, --perm <모드>             권한 승인 방식 선택 (기본값: bypass)
                                  - bypass      : --dangerously-skip-permissions 사용
                                  - auto        : --permission-mode auto 사용
                                  - acceptEdits : --permission-mode acceptEdits 사용
                                  - allowed     : --allowedTools "${ALLOWED_TOOLS}" 사용
  -m, --model <모델명>          단계별 구현에 사용할 Claude 모델 지정 (예: sonnet, opus)
      --fallback-model <모델들> 기본 모델 과부하 시 대체할 모델 목록 (예: sonnet,haiku)
  -b, --max-budget <USD>        호출당 최대 API 비용 한도 (--max-budget-usd, 예: 5.00)
  -c, --continue                이전 단계 세션을 이어서 실행 (--continue)
  -g, --auto-commit             계획 수립 및 각 단계 완료 후 자동으로 Git 커밋 생성
  -v, --verify <명령어>         각 단계 후 검증할 쉘 명령어 (예: "npm test", "pytest -q")

Slack 연동 옵션 (의사결정 필요 시 Slack 알림 → 스레드 답글로 답변 수신 → 즉시 재개):
      --slack-token <토큰>      Slack Bot Token (환경변수 SLACK_BOT_TOKEN, xoxb-...)
      --slack-channel <채널ID>  알림/답변 채널 ID (환경변수 SLACK_CHANNEL, 봇 초대 필요)
      --slack-webhook <URL>     알림 전용 Incoming Webhook (답변 수신 불가 → 알림 후 pause)
      --slack-timeout <분>      Slack 답변 대기 제한 (기본값: 0=무제한, 초과 시 pause)
                                  답글 형식: 1/Enter 상당(ok) = 선택지 1, 2 = 선택지 2, q = 일시정지, 그 외 = 직접 지침

토큰/사용량 한도(Usage Limit) 대기 옵션:
  -w, --limit-wait <분>         해제 시각 미표시 시 기본 재시도 대기 시간(분) (기본값: 15)
      --limit-buffer <초>       파싱된 해제 시각에 추가할 안전 여유 시간(초) (기본값: 60)
      --no-limit-wait           토큰 한도 도달 시 대기하지 않고 즉시 종료

Ubuntu 환경 전용 옵션:
      --tmux [세션명]           Ubuntu tmux 백그라운드 세션에서 스크립트를 시작 (기본 세션명: claude-plan)
      --no-inhibit              systemd-inhibit 절전 방지 기능 비활성화
      --check-env               Ubuntu 패키지, 타임존, Claude CLI 설치 상태 진단 후 종료

기타 옵션:
      --dry-run                 실제 실행 없이 호출될 명령어와 프롬프트만 확인
  -h, --help                    도움말 출력

Ubuntu 실행 예시:
  # 1) 스펙 충돌 시 터미널에서 직접 물어보도록 실행 (기본값 --on-conflict ask)
  ./$(basename "$0") --req-file spec.md

  # 2) 직전 계획 수립 세션에서 파일 저장이 누락되었을 때 처음부터 다시 분석하지 않고 즉시 복구 후 실행
  ./$(basename "$0") --recover-plan

  # 3) 완전 무인 실행: 충돌 발생 시 보수적 기준으로 자율 결정 후 decisions.md에 기록
  ./$(basename "$0") --tmux --on-conflict auto --req-file spec.md --auto-commit
EOF
}

# Ubuntu 데스크톱 알림 전송 함수 (GUI 환경 및 notify-send 존재 시 동작)
send_ubuntu_notification() {
  local title="$1"
  local message="$2"
  local urgency="${3:-normal}" # low | normal | critical

  if [[ "$ENABLE_NOTIFY" == "true" ]] && command -v notify-send >/dev/null 2>&1; then
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
      notify-send -u "$urgency" -a "Claude Plan Runner" "$title" "$message" >/dev/null 2>&1 || true
    fi
  fi
}

# Ubuntu 환경 진단 함수 (--check-env)
check_ubuntu_environment() {
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BOLD}${BLUE} Ubuntu 실행 환경 및 필수 도구 진단${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  if [[ -f /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    echo -e " - 운영체제        : ${GREEN}${PRETTY_NAME:-Ubuntu/Linux}${NC}"
  else
    echo -e " - 운영체제        : ${YELLOW}$(uname -srm)${NC}"
  fi

  echo -e " - 현재 사용자     : ${CYAN}$(whoami) (UID: ${EUID})${NC}"
  if [[ "$EUID" -eq 0 ]]; then
    echo -e "   ${YELLOW}⚠ 주의: root 계정에서는 Claude Code의 --dangerously-skip-permissions 사용이 제한될 수 있습니다.${NC}"
    echo -e "   ${YELLOW}  일반 사용자 계정으로 실행하거나 '--perm auto' 사용을 권장합니다.${NC}"
  fi

  local current_tz
  current_tz=$(date +"%Z (UTC%z)")
  echo -e " - 시스템 타임존   : ${CYAN}${current_tz}${NC}"
  if [[ "$(date +%Z)" == "UTC" ]]; then
    echo -e "   ${YELLOW}💡 팁: 한국 시간 기준 한도 리셋 시각 표시를 원하시면 'sudo timedatectl set-timezone Asia/Seoul'을 설정하세요.${NC}"
  fi

  if command -v claude >/dev/null 2>&1; then
    local claude_ver
    claude_ver=$(claude --version 2>/dev/null || echo "설치됨")
    echo -e " - Claude Code CLI : ${GREEN}정상 (${claude_ver} @ $(command -v claude))${NC}"
  else
    echo -e " - Claude Code CLI : ${RED}미설치 (설치 명령어: curl -fsSL https://claude.ai/install.sh | bash)${NC}"
  fi

  for tool in bash grep sed awk python3 date realpath find flock git tmux systemd-inhibit notify-send curl; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo -e " - 필수/보조 도구  : ${GREEN}✓ ${tool}${NC} ($(command -v "$tool"))"
    else
      echo -e " - 필수/보조 도구  : ${YELLOW}○ ${tool} (미설치 - 선택 사항)${NC}"
    fi
  done

  echo -e "${BLUE}======================================================================${NC}"
}

create_sample_plan() {
  if [[ -f "$PLAN_FILE" ]]; then
    echo -e "${YELLOW}[알림] 이미 '${PLAN_FILE}' 파일이 존재합니다.${NC}"
    exit 1
  fi

  cat <<'EOF' > "$PLAN_FILE"
# 프로젝트 구현 계획 (plan.md)

각 단계를 순서대로 진행하며, 완료된 항목은 `- [x]`로 업데이트합니다.

## Phase 1: 기본 구조 설정
- [ ] Step 1: 프로젝트 디렉터리 구조 및 기본 설정 파일 초기화
- [ ] Step 2: 핵심 데이터 모델 및 인터페이스 작성

## Phase 2: 기능 구현 및 검증
- [ ] Step 3: 비즈니스 로직 및 주요 모듈 구현
- [ ] Step 4: 단위 테스트 작성 및 전체 테스트 통과 확인
EOF
  echo -e "${GREEN}[완료] 샘플 '${PLAN_FILE}' 파일이 생성되었습니다.${NC}"
}

# CLI 인자 파싱
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -q|--req)
      REQUIREMENTS="$2"
      shift 2
      ;;
    -i|--req-file)
      REQ_FILE="$2"
      shift 2
      ;;
    --append-plan)
      PLAN_MODE_ACTION="append"
      shift
      ;;
    --plan-only)
      PLAN_ONLY="true"
      shift
      ;;
    --confirm-plan)
      CONFIRM_PLAN="true"
      shift
      ;;
    --plan-model)
      PLAN_MODEL="$2"
      shift 2
      ;;
    --recover-plan)
      RECOVER_LAST_PLAN="true"
      shift
      ;;
    --on-conflict)
      ON_CONFLICT="$2"
      shift 2
      ;;
    --decisions)
      DECISIONS_FILE="$2"
      shift 2
      ;;
    -f|--plan)
      PLAN_FILE="$2"
      shift 2
      ;;
    -s|--max-steps)
      MAX_STEPS="$2"
      shift 2
      ;;
    -t|--max-turns)
      MAX_TURNS="$2"
      shift 2
      ;;
    --plan-turns)
      PLAN_MAX_TURNS="$2"
      shift 2
      ;;
    -r|--max-retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    -p|--perm)
      PERMISSION_STRATEGY="$2"
      shift 2
      ;;
    -m|--model)
      MODEL="$2"
      shift 2
      ;;
    --fallback-model)
      FALLBACK_MODEL="$2"
      shift 2
      ;;
    -b|--max-budget)
      MAX_BUDGET_USD="$2"
      shift 2
      ;;
    -c|--continue)
      CONTINUE_SESSION="true"
      shift
      ;;
    -g|--auto-commit)
      AUTO_COMMIT="true"
      shift
      ;;
    -v|--verify)
      VERIFY_CMD="$2"
      shift 2
      ;;
    --slack-token)
      SLACK_BOT_TOKEN="$2"
      shift 2
      ;;
    --slack-channel)
      SLACK_CHANNEL="$2"
      shift 2
      ;;
    --slack-webhook)
      SLACK_WEBHOOK_URL="$2"
      shift 2
      ;;
    --slack-timeout)
      SLACK_REPLY_TIMEOUT="$2"
      shift 2
      ;;
    -w|--limit-wait)
      LIMIT_FALLBACK_MINUTES="$2"
      shift 2
      ;;
    --limit-buffer)
      LIMIT_BUFFER_SECONDS="$2"
      shift 2
      ;;
    --no-limit-wait)
      WAIT_ON_LIMIT="false"
      shift
      ;;
    --tmux)
      USE_TMUX="true"
      if [[ $# -gt 1 && ! "$2" =~ ^- ]]; then
        TMUX_SESSION_NAME="$2"
        shift 2
      else
        shift
      fi
      ;;
    --no-inhibit)
      INHIBIT_SLEEP="false"
      shift
      ;;
    --check-env)
      CHECK_ENV_ONLY="true"
      shift
      ;;
    --init-sample)
      create_sample_plan
      exit 0
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo -e "${RED}[오류] 알 수 없는 옵션입니다: $1${NC}" >&2
      usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      shift
      ;;
  esac
done

case "$ON_CONFLICT" in
  ask|pause|auto) ;;
  *)
    echo -e "${RED}[오류] --on-conflict 값은 ask, pause, auto 중 하나여야 합니다 (입력값: ${ON_CONFLICT}).${NC}" >&2
    exit 1
    ;;
esac

if [[ "$CHECK_ENV_ONLY" == "true" ]]; then
  check_ubuntu_environment
  exit 0
fi

# Claude가 다른 하위/상위 디렉터리에 파일을 만드는 문제를 방지하기 위해 절대 경로 계산
WORK_DIR="$(pwd)"
if command -v realpath >/dev/null 2>&1; then
  ABS_PLAN_FILE="$(realpath -m "$PLAN_FILE")"
  ABS_DECISIONS_FILE="$(realpath -m "$DECISIONS_FILE")"
else
  [[ "$PLAN_FILE" = /* ]] && ABS_PLAN_FILE="$PLAN_FILE" || ABS_PLAN_FILE="${WORK_DIR}/${PLAN_FILE}"
  [[ "$DECISIONS_FILE" = /* ]] && ABS_DECISIONS_FILE="$DECISIONS_FILE" || ABS_DECISIONS_FILE="${WORK_DIR}/${DECISIONS_FILE}"
fi

# Ubuntu tmux 세션 내에서 실행 요청 시(--tmux) 자동으로 tmux 세션을 생성하고 재실행
if [[ "$USE_TMUX" == "true" && -z "${TMUX:-}" && "$DRY_RUN" != "true" ]]; then
  if ! command -v tmux >/dev/null 2>&1; then
    echo -e "${RED}[오류] Ubuntu에 'tmux'가 설치되어 있지 않습니다. 'sudo apt update && sudo apt install -y tmux'로 설치해 주세요.${NC}" >&2
    exit 1
  fi

  FILTERED_ARGS=()
  skip_next="false"
  for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    if [[ "$skip_next" == "true" ]]; then
      skip_next="false"
      continue
    fi
    arg="${ORIGINAL_ARGS[$i]}"
    if [[ "$arg" == "--tmux" ]]; then
      if [[ $((i+1)) -lt ${#ORIGINAL_ARGS[@]} && ! "${ORIGINAL_ARGS[$((i+1))]}" =~ ^- ]]; then
        skip_next="true"
      fi
      continue
    fi
    FILTERED_ARGS+=("$arg")
  done

  SCRIPT_ABS_PATH="$SCRIPT_PATH"
  TMUX_CMD="$(printf '%q ' "$SCRIPT_ABS_PATH" "${FILTERED_ARGS[@]}")"

  if tmux has-session -t "$TMUX_SESSION_NAME" 2>/dev/null; then
    echo -e "${YELLOW}[알림] 이미 tmux 세션 '${TMUX_SESSION_NAME}'이 실행 중입니다.${NC}"
    echo -e "접속 명령어: ${CYAN}tmux attach -t ${TMUX_SESSION_NAME}${NC}"
    exit 1
  fi

  # 재실행 시에도 프로젝트 폴더(호출 위치)에서 시작해야 상대경로가 동일하게 해석된다
  tmux new-session -d -c "$WORK_DIR" -s "$TMUX_SESSION_NAME" "bash -c ${TMUX_CMD}; exec bash"
  echo -e "${GREEN}[Ubuntu tmux 시작] 백그라운드 tmux 세션('${TMUX_SESSION_NAME}')에서 작업을 시작했습니다.${NC}"
  echo -e " - 실시간 화면 접속 : ${CYAN}tmux attach -t ${TMUX_SESSION_NAME}${NC}"
  echo -e " - 화면에서 빠져나오기(세션 유지): ${CYAN}Ctrl+B 누른 후 D${NC}"
  exit 0
fi

# 위치 인자로 전달된 요구사항 처리
if [[ ${#POSITIONAL_ARGS[@]} -gt 0 && -z "$REQUIREMENTS" ]]; then
  REQUIREMENTS="${POSITIONAL_ARGS[*]}"
fi

# 요구사항 파일(--req-file) 읽기
if [[ -n "$REQ_FILE" ]]; then
  if [[ ! -f "$REQ_FILE" ]]; then
    echo -e "${RED}[오류] 요구사항 파일을 찾을 수 없습니다: ${REQ_FILE}${NC}" >&2
    exit 1
  fi
  FILE_CONTENT=$(cat "$REQ_FILE")
  if [[ -n "$REQUIREMENTS" ]]; then
    REQUIREMENTS="${REQUIREMENTS}"$'\n\n'"${FILE_CONTENT}"
  else
    REQUIREMENTS="$FILE_CONTENT"
  fi
fi

# 파이프(stdin)로 전달된 요구사항 읽기 지원 (예: cat spec.md | ./run_plan.sh)
if [[ -z "$REQUIREMENTS" && ! -t 0 ]]; then
  STDIN_CONTENT=$(cat)
  if [[ -n "$STDIN_CONTENT" ]]; then
    REQUIREMENTS="$STDIN_CONTENT"
  fi
fi

# 필수 요구사항 확인 (Dry-Run이 아닐 때만 claude 바이너리 체크)
if [[ "$DRY_RUN" != "true" ]] && ! command -v claude >/dev/null 2>&1; then
  echo -e "${RED}[오류] 'claude' CLI를 찾을 수 없습니다.${NC}" >&2
  echo -e "Ubuntu 설치 방법: ${CYAN}curl -fsSL https://claude.ai/install.sh | bash${NC}" >&2
  exit 1
fi

# Ubuntu root 사용자 실행 시 --dangerously-skip-permissions 제약 자동 방어
if [[ "$EUID" -eq 0 && "$PERMISSION_STRATEGY" == "bypass" ]]; then
  echo -e "${YELLOW}[Ubuntu 보안 안내] 현재 root 계정(UID 0)으로 실행 중입니다.${NC}"
  echo -e "${YELLOW}Claude Code CLI는 Linux root 계정에서 '--dangerously-skip-permissions' 실행을 차단할 수 있으므로 권한 모드를 'auto'(--permission-mode auto)로 자동 전환합니다.${NC}"
  PERMISSION_STRATEGY="auto"
fi

mkdir -p "$LOG_DIR"

# Ubuntu flock을 이용한 단일 프로세스 중복 실행 방지 락(Lock)
LOCK_FILE="${LOG_DIR}/run_plan.lock"
if command -v flock >/dev/null 2>&1 && [[ "$DRY_RUN" != "true" ]]; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo -e "${RED}[오류] 현재 디렉터리에서 이미 다른 '$(basename "$0")' 프로세스가 실행 중입니다 (${LOCK_FILE}).${NC}" >&2
    exit 1
  fi
fi

# Ubuntu 절전(Suspend) 모드 진입 방지를 위한 sleep 래퍼 함수
ubuntu_safe_sleep() {
  local seconds="$1"
  if [[ "$INHIBIT_SLEEP" == "true" ]] && command -v systemd-inhibit >/dev/null 2>&1; then
    systemd-inhibit \
      --what=idle:sleep \
      --who="run_plan.sh" \
      --why="Waiting for Claude Code token limit reset" \
      --mode=block \
      sleep "$seconds" 2>/dev/null || sleep "$seconds"
  else
    sleep "$seconds"
  fi
}

# 남은 미완료 항목(- [ ] 또는 * [ ]) 개수 계산
count_remaining_tasks() {
  if [[ ! -f "$ABS_PLAN_FILE" ]]; then
    echo 0
    return
  fi
  grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$ABS_PLAN_FILE" || true
}

# 완료된 항목(- [x] 또는 - [X]) 개수 계산
count_completed_tasks() {
  if [[ ! -f "$ABS_PLAN_FILE" ]]; then
    echo 0
    return
  fi
  grep -cE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$ABS_PLAN_FILE" || true
}

# 다음 진행할 첫 번째 미완료 항목 추출
get_next_task() {
  grep -m 1 -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$ABS_PLAN_FILE" \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\][[:space:]]*//' || true
}

# 단계 텍스트를 짧은 제목으로 축약 (첫 " — " 앞, 최대 80자). 프롬프트 반복·커밋 메시지용
short_task() {
  local t="${1%% — *}"
  t="${t%% - *}"
  printf '%s' "${t:0:80}"
}

# Claude CLI 공통 실행 인자 구성 함수
# $1: 사용할 모델명 (비어있으면 기본값), $2: 세션 이어하기 여부 ("true" | "false")
build_claude_args() {
  local target_model="${1:-}"
  local use_continue="${2:-false}"

  CLAUDE_ARGS=("-p" "--max-turns" "$MAX_TURNS")

  case "$PERMISSION_STRATEGY" in
    bypass)
      CLAUDE_ARGS+=("--dangerously-skip-permissions")
      ;;
    auto)
      CLAUDE_ARGS+=("--permission-mode" "auto")
      ;;
    acceptEdits)
      CLAUDE_ARGS+=("--permission-mode" "acceptEdits")
      ;;
    allowed)
      CLAUDE_ARGS+=("--allowedTools" "$ALLOWED_TOOLS")
      ;;
    *)
      echo -e "${RED}[오류] 지원하지 않는 권한 모드입니다: ${PERMISSION_STRATEGY}${NC}" >&2
      exit 1
      ;;
  esac

  if [[ -n "$target_model" ]]; then
    CLAUDE_ARGS+=("--model" "$target_model")
  fi

  if [[ -n "$FALLBACK_MODEL" ]]; then
    CLAUDE_ARGS+=("--fallback-model" "$FALLBACK_MODEL")
  fi

  if [[ -n "$MAX_BUDGET_USD" ]]; then
    CLAUDE_ARGS+=("--max-budget-usd" "$MAX_BUDGET_USD")
  fi

  if [[ "$use_continue" == "true" ]]; then
    CLAUDE_ARGS+=("--continue")
  fi
}

# ==============================================================================
# 스펙 충돌 및 아키텍처 의사결정(Decision) 처리 함수들
# ==============================================================================

# 현재 설정된 --on-conflict 모드에 따라 프롬프트에 주입할 지침 생성
get_conflict_policy_instruction() {
  local decisions_context=""
  if [[ -f "$ABS_DECISIONS_FILE" ]]; then
    decisions_context="참고: 프로젝트에 이미 기록된 '${ABS_DECISIONS_FILE}' 파일이 존재하므로, 먼저 해당 파일의 기존 의사결정 내역을 확인하고 일관되게 준수해."
  fi

  if [[ "$ON_CONFLICT" == "auto" ]]; then
    cat <<EOF
[스펙 충돌 및 의사결정 지침 (--on-conflict auto)]
${decisions_context}
- 작업 중 요구사항(Spec)과 현재 코드베이스가 충돌하거나 여러 설계 선택지 중 결정이 필요한 사항이 발생하면 멈추지 말고 다음 우선순위에 따라 자율적으로 결정해:
  1순위: 사용자가 전달한 요구사항 원문 및 '${ABS_DECISIONS_FILE}'의 기존 결정 사항
  2순위: 기존 코드베이스의 아키텍처 컨벤션 및 하위 호환성(Backward Compatibility) 유지
  3순위: 부작용이 가장 적은 보수적이고 표준적인 구현 방식 선택
- 자율 결정을 내린 경우 '${ABS_DECISIONS_FILE}' 파일에 (없으면 생성하여) [날짜/단계, 충돌 이슈, 선택한 방안 및 근거]를 ADR(Architecture Decision Record) 형식으로 기록하고 이번 단계를 끝까지 완료해.
EOF
  else
    cat <<EOF
[스펙 충돌 및 의사결정 지침 (--on-conflict ${ON_CONFLICT})]
${decisions_context}
- 사소한 구현 세부사항, 모호하지만 합리적인 기본값이 있는 사항, 기존 코드 컨벤션으로 정해지는 사항은 묻지 말고 스스로 판단해 진행해. 이런 판단은 '${ABS_DECISIONS_FILE}'에 한 줄만 남겨.
- 결정 요청은 최후의 수단이야. 아래 경우에만 해당해: 요구사항(Spec) 자체가 서로 모순되어 둘을 동시에 만족할 수 없거나, 기존 핵심 동작을 깨뜨리는 파괴적 변경(Breaking Change)이 불가피하거나, 사용자의 비즈니스 의사결정 없이는 어느 쪽으로도 진행할 수 없는 경우. 이때는 임의로 추측해서 소스 코드를 작성하지 마.
- 위 경우에 해당하지 않으면(충돌이 없으면) 아래 결정 요청 블록과 그 마커 문자열을 절대 출력하거나 언급하지 말고, 그냥 이번 작업을 끝까지 진행해.
- 중요: 계획 수립(Phase 1) 중 결정이 필요한 사항이 있더라도, 먼저 '${ABS_PLAN_FILE}' 파일 자체는 반드시 Write 도구로 디스크에 실제로 생성해 두고(미결정 단계도 '- [ ] Step N: ...' 체크박스로 포함), 그 다음에 질문을 출력해야 해! 파일을 생성하지 않고 텍스트로만 출력하면 안 돼.
- 중대한 충돌/결정이 필요한 경우:
  1. '${ABS_PLAN_FILE}' 파일이 디스크에 저장되어 있는지 확인하고, 해당 단계 체크박스를 미완료('- [ ]') 상태로 유지해.
  2. '${ABS_DECISIONS_FILE}' 파일에 충돌 원인과 선택지(권장안 포함)를 상세히 기록해.
  3. 출력 마지막에 반드시 아래 형식의 블록을 정확히 출력하고 턴을 종료해:
[DECISION_REQUIRED]
- 단계: (현재 단계명)
- 충돌/이슈 요약: (무엇이 스펙과 충돌하거나 모호한지 설명)
- 선택지 1 (권장): (방안 설명 및 장단점)
- 선택지 2: (대안 설명 및 장단점)
[/DECISION_REQUIRED]
EOF
  fi
}

# 로그 파일에서 [DECISION_REQUIRED] 블록이 출력되었는지 감지
#
# 오탐 방지: 마커를 문장 중간에서 언급만 한 경우는 무시한다. 다음 조건을 모두 만족하는
# '완결된 블록'이 있을 때만 결정 필요로 판단한다.
#   - 여는 마커와 닫는 마커가 각각 한 줄을 단독으로 차지 (앞뒤 공백/마크다운 장식 허용)
#   - 블록 안에 '- 선택지 N' 줄이 하나 이상 존재
is_decision_required() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi
  [[ -n "$(extract_decision_block "$log_file")" ]]
}

# 로그 파일에서 마지막 완결된 [DECISION_REQUIRED] ... [/DECISION_REQUIRED] 블록 추출 (없으면 빈 출력)
extract_decision_block() {
  local log_file="$1"
  awk '
    /^[[:space:]>*`_-]*\[DECISION_REQUIRED\][[:space:]*`_]*$/ { blk = 1; n = 0; buf = $0; next }
    /^[[:space:]>*`_-]*\[\/DECISION_REQUIRED\][[:space:]*`_]*$/ {
      if (blk && n > 0) last = buf "\n" $0
      blk = 0; next
    }
    blk { buf = buf "\n" $0; if ($0 ~ /선택지[[:space:]]*[0-9]/) n++ }
    END { if (last != "") print last }
  ' "$log_file" || true
}

# ------------------------------------------------------------------------------
# Slack 연동: 알림 전송 및 스레드 답글 수신 (curl + python3 사용)
# ------------------------------------------------------------------------------

# 양방향(알림 + 답변 수신) 가능 여부: Bot Token + 채널 ID 필요
slack_reply_enabled() {
  [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_CHANNEL" ]] \
    && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1
}

# 알림만 가능한지 여부 (Bot Token 또는 Webhook)
slack_notify_enabled() {
  slack_reply_enabled && return 0
  [[ -n "$SLACK_WEBHOOK_URL" ]] && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1
}

# Slack 메시지 전송. $1: 본문, $2: (선택) 스레드 ts. 성공 시 메시지 ts 출력 (Webhook은 "webhook" 출력)
slack_post() {
  local text="$1"
  local thread_ts="${2:-}"
  local payload resp

  if slack_reply_enabled; then
    payload=$(printf '%s' "$text" | python3 -c '
import json, sys
d = {"channel": sys.argv[1], "text": sys.stdin.read()}
if sys.argv[2]:
    d["thread_ts"] = sys.argv[2]
print(json.dumps(d))' "$SLACK_CHANNEL" "$thread_ts") || return 1
    resp=$(curl -sS --max-time 20 -X POST "https://slack.com/api/chat.postMessage" \
      -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "$payload" 2>/dev/null) || return 1
    printf '%s' "$resp" | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    sys.exit(1)
if not r.get("ok"):
    sys.stderr.write("Slack API 오류: %s\n" % r.get("error", "unknown"))
    sys.exit(1)
print(r.get("ts", ""))'
  else
    payload=$(printf '%s' "$text" | python3 -c '
import json, sys
print(json.dumps({"text": sys.stdin.read()}))') || return 1
    curl -sS --max-time 20 -X POST -H "Content-Type: application/json" \
      --data "$payload" "$SLACK_WEBHOOK_URL" >/dev/null 2>&1 || return 1
    echo "webhook"
  fi
}

# 스레드(ts)의 첫 번째 사용자 답글(봇 메시지 제외) 텍스트 출력. 답글이 없으면 빈 출력
slack_fetch_reply() {
  local thread_ts="$1"
  curl -sS --max-time 20 -G "https://slack.com/api/conversations.replies" \
    -H "Authorization: Bearer ${SLACK_BOT_TOKEN}" \
    --data-urlencode "channel=${SLACK_CHANNEL}" \
    --data-urlencode "ts=${thread_ts}" 2>/dev/null \
    | python3 -c '
import json, sys
try:
    r = json.load(sys.stdin)
except Exception:
    sys.exit(0)
if not r.get("ok"):
    sys.stderr.write("Slack API 오류: %s\n" % r.get("error", "unknown"))
    sys.exit(0)
root = sys.argv[1]
for m in r.get("messages", []):
    if m.get("ts") == root or m.get("bot_id") or m.get("subtype") == "bot_message":
        continue
    t = (m.get("text") or "").strip()
    if t:
        print(t)
        break' "$thread_ts" || true
}

# 의사결정 필요 상황 발생 시 사용자에게 묻거나(ask) 안전 정지(pause) 처리
# 반환값: 사용자 결정 텍스트가 전역 변수 USER_DECISION_INPUT에 저장됨
handle_decision_required() {
  local log_file="$1"
  local step_label="$2"
  local decision_block
  decision_block=$(extract_decision_block "$log_file")

  echo -e "\n${YELLOW}======================================================================${NC}"
  echo -e "${BOLD}${YELLOW} [의사결정 필요] 스펙 충돌 또는 설계 결정 사항이 감지되었습니다!${NC}"
  echo -e "${YELLOW}======================================================================${NC}"
  echo -e " - 발생 단계 : ${CYAN}${step_label}${NC}"
  echo -e " - 기록 파일 : ${CYAN}${ABS_DECISIONS_FILE}${NC}"
  echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
  if [[ -n "$decision_block" ]]; then
    echo "$decision_block"
  else
    tail -n 25 "$log_file"
  fi
  echo -e "${YELLOW}======================================================================${NC}"

  send_ubuntu_notification \
    "Claude Code 의사결정 필요" \
    "${step_label} 진행 중 스펙 충돌/결정 사항이 발생했습니다. 확인이 필요합니다." \
    "critical"

  # Slack 알림 전송 (실패해도 진행에는 영향 없음). 양방향 가능 시 스레드 ts 보관
  local slack_ts="" decision_source="터미널"
  if slack_notify_enabled; then
    local slack_msg
    slack_msg=":warning: *Claude Plan Runner — 의사결정 필요*
• 단계: ${step_label}
• 프로젝트: ${WORK_DIR}
• 기록 파일: ${ABS_DECISIONS_FILE}
\`\`\`
${decision_block:-$(tail -n 25 "$log_file")}
\`\`\`"
    if slack_reply_enabled && [[ "$ON_CONFLICT" != "pause" ]]; then
      slack_msg+=$'\n'"*이 메시지의 스레드에 답글로 답변해 주세요:* \`1\`(권장안) / \`2\` / 직접 지침 텍스트 / \`q\`(일시정지)"
    fi
    if slack_ts=$(slack_post "$slack_msg"); then
      echo -e "${BLUE}[Slack] 의사결정 요청을 전송했습니다.${NC}"
    else
      slack_ts=""
      echo -e "${YELLOW}[Slack] 알림 전송에 실패했습니다 (계속 진행).${NC}" >&2
    fi
  fi

  # Slack 답변 대기 가능 여부 (Bot Token 방식, ts 확보, pause 모드 아님)
  local use_slack_reply="false"
  if [[ -n "$slack_ts" && "$slack_ts" != "webhook" && "$ON_CONFLICT" != "pause" ]] && slack_reply_enabled; then
    use_slack_reply="true"
  fi

  # pause 모드이거나 비대화형 터미널(백그라운드/파이프)이면서 Slack 답변도 못 받는 경우 파일에 기록 후 안전 정지
  if [[ "$ON_CONFLICT" == "pause" || ( ! -t 0 && "$use_slack_reply" != "true" ) ]]; then
    echo -e "${RED}[일시 정지] '--on-conflict pause' (또는 비대화형 세션) 상태이므로 실행을 안전하게 일시 정지합니다.${NC}"
    echo -e "해결 방법:"
    echo -e "  1) '${CYAN}${ABS_DECISIONS_FILE}${NC}' 또는 '${CYAN}${ABS_PLAN_FILE}${NC}'에 원하시는 결정 방향을 작성/수정하세요."
    echo -e "  2) '${CYAN}./$(basename "$0") --plan ${PLAN_FILE}${NC}'를 다시 실행하면 해당 단계부터 이어서 진행됩니다."
    exit 4
  fi

  # ask 모드: 터미널 입력(대화형일 때)과 Slack 스레드 답글(활성화 시) 중 먼저 도착한 답변 사용
  local user_input=""
  if [[ "$use_slack_reply" == "true" ]]; then
    echo -e "${CYAN}Slack 스레드 답글을 기다리는 중입니다 (${SLACK_POLL_INTERVAL}초 간격 확인$([[ "$SLACK_REPLY_TIMEOUT" -gt 0 ]] && echo ", 제한 ${SLACK_REPLY_TIMEOUT}분")).${NC}"
  fi
  if [[ -t 0 ]]; then
    echo -e "${CYAN}어떻게 진행할지 결정 사항이나 지침을 입력해 주세요:${NC}"
  fi
  echo -e "  - 바로 ${BOLD}Enter${NC} 입력 시(Slack: ${BOLD}1${NC}): 위 '${BOLD}선택지 1 (권장)${NC}' 방안으로 채택하여 계속 진행"
  echo -e "  - ${BOLD}2${NC} 또는 ${BOLD}선택지 2${NC} 입력 시: '선택지 2' 방안으로 채택하여 계속 진행"
  echo -e "  - 직접 지침 텍스트 입력 가능"
  echo -e "  - ${BOLD}q${NC} 또는 ${BOLD}quit${NC} 입력 시: 현재 상태에서 스크립트 일시 정지"

  if [[ "$use_slack_reply" == "true" ]]; then
    local waited=0 buf="" part="" rc=0 slack_reply=""
    local timeout_sec=$((SLACK_REPLY_TIMEOUT * 60))
    [[ -t 0 ]] && printf "결정 입력 > "
    while true; do
      if [[ -t 0 ]]; then
        # 타임아웃 시 bash가 부분 입력을 변수에 남기므로 누적하여 입력 유실 방지
        part=""
        rc=0
        IFS= read -r -t "$SLACK_POLL_INTERVAL" part || rc=$?
        if [[ "$rc" -eq 0 ]]; then
          user_input="${buf}${part}"
          decision_source="터미널"
          echo
          break
        fi
        buf+="$part"
      else
        sleep "$SLACK_POLL_INTERVAL"
      fi
      waited=$((waited + SLACK_POLL_INTERVAL))

      slack_reply=$(slack_fetch_reply "$slack_ts")
      if [[ -n "$slack_reply" ]]; then
        user_input="$slack_reply"
        decision_source="Slack"
        [[ -t 0 ]] && echo
        echo -e "${GREEN}[Slack] 답변 수신: ${user_input}${NC}"
        break
      fi

      if [[ "$timeout_sec" -gt 0 && "$waited" -ge "$timeout_sec" ]]; then
        echo -e "\n${RED}[일시 정지] Slack 답변 대기 제한(${SLACK_REPLY_TIMEOUT}분)을 초과했습니다.${NC}"
        slack_post ":hourglass: 답변 대기 제한(${SLACK_REPLY_TIMEOUT}분) 초과로 실행을 일시 정지합니다. '${DECISIONS_FILE}' 확인 후 재실행해 주세요." "$slack_ts" >/dev/null 2>&1 || true
        exit 4
      fi
    done
  else
    read -r -p "결정 입력 > " user_input
  fi

  if [[ "$user_input" == "q" || "$user_input" == "quit" ]]; then
    echo -e "${YELLOW}[일시 정지] 사용자 요청으로 스크립트를 중단합니다. '${DECISIONS_FILE}' 또는 '${PLAN_FILE}' 수정 후 재실행하세요.${NC}"
    [[ "$use_slack_reply" == "true" ]] && { slack_post ":pause_button: 요청에 따라 실행을 일시 정지했습니다." "$slack_ts" >/dev/null 2>&1 || true; }
    exit 4
  fi

  if [[ -z "$user_input" || "$user_input" == "1" ]]; then
    USER_DECISION_INPUT="제시된 '선택지 1 (권장)' 방안을 채택하여 진행해줘."
  elif [[ "$user_input" == "2" ]]; then
    USER_DECISION_INPUT="제시된 '선택지 2' 방안을 채택하여 진행해줘."
  elif [[ "$user_input" == "3" ]]; then
    USER_DECISION_INPUT="제시된 '선택지 3' 방안을 채택하여 진행해줘."
  else
    USER_DECISION_INPUT="$user_input"
  fi

  # 사용자의 결정을 decisions.md에 영구 기록하여 이후 모든 단계에서도 참조되게 함
  {
    echo ""
    echo "## [$(date +"%Y-%m-%d %H:%M:%S")] ${step_label} 의사결정 기록"
    if [[ -n "$decision_block" ]]; then
      echo "### 감지된 이슈"
      echo '```'
      echo "$decision_block"
      echo '```'
    fi
    echo "### 최종 사용자 결정 (입력 경로: ${decision_source})"
    echo "- ${USER_DECISION_INPUT}"
  } >> "$ABS_DECISIONS_FILE"

  if [[ "$use_slack_reply" == "true" ]]; then
    slack_post ":white_check_mark: 결정을 반영하고 작업을 재개합니다: ${USER_DECISION_INPUT}" "$slack_ts" >/dev/null 2>&1 || true
  fi

  echo -e "${GREEN}[결정 반영] '${DECISIONS_FILE}'에 결정 사항을 기록했습니다. 작업을 즉시 재개합니다.${NC}"
}

# ==============================================================================
# 토큰/사용량 한도(Usage Limit / Rate Limit) 감지 및 해제 시각까지 대기하는 함수들
# ==============================================================================

# 로그 파일에서 토큰/사용량 한도 도달 여부 확인
is_usage_limit_reached() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi

  grep -qiE \
    'usage limit reached|limit will reset at|hit your limit|resets[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)|rate_limit_error|exceed your account'\''s rate limit|Error:[[:space:]]*429|too many requests|5-hour limit|weekly limit' \
    "$log_file"
}

# 로그 파일에서 해제 시각(Epoch, Retry-After, 또는 시각 문자열)을 파싱하여 대기할 초(seconds) 계산
calculate_limit_wait_seconds() {
  local log_file="$1"
  local fallback_sec=$((LIMIT_FALLBACK_MINUTES * 60))
  local buffer_sec="${LIMIT_BUFFER_SECONDS}"

  if command -v python3 >/dev/null 2>&1; then
    python3 - "$log_file" "$fallback_sec" "$buffer_sec" <<'PYEOF'
import datetime
import re
import sys
try:
    from zoneinfo import ZoneInfo
except ImportError:
    ZoneInfo = None

log_path = sys.argv[1]
fallback_sec = int(sys.argv[2])
buffer_sec = int(sys.argv[3])

try:
    with open(log_path, "r", encoding="utf-8", errors="ignore") as f:
        text = f.read()
except Exception:
    print(f"{fallback_sec}|기본 대기 시간 적용")
    sys.exit(0)

now_ts = int(datetime.datetime.now().timestamp())

# 1) "usage limit reached|1749924000" 형태의 Unix Epoch 타임스탬프 감지
m_epoch = re.search(r"usage limit reached\|(\d{10})", text, re.IGNORECASE)
if m_epoch:
    target_ts = int(m_epoch.group(1))
    wait_s = max(target_ts - now_ts, 0) + buffer_sec
    reset_str = datetime.datetime.fromtimestamp(target_ts).strftime("%Y-%m-%d %H:%M:%S")
    print(f"{wait_s}|Epoch 타임스탬프 ({reset_str})")
    sys.exit(0)

# 2) "retry-after: 120" 또는 "retry after 5 minutes" 형태 감지
m_retry = re.search(r"retry[- ]after[:\s]+(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m)?", text, re.IGNORECASE)
if m_retry:
    val = int(m_retry.group(1))
    unit = (m_retry.group(2) or "s").lower()
    if unit.startswith("m"):
        val *= 60
    wait_s = val + buffer_sec
    print(f"{wait_s}|Retry-After ({val}초)")
    sys.exit(0)

# 3) "reset(s) (at) [Month Day,] HH[:MM] [am/pm] [(Timezone)]" 형태 감지
pattern = re.compile(
    r"resets?(?:\s+at)?\s+"
    r"(?:([A-Za-z]{3,9})\s+(\d{1,2}),?\s+)?"
    r"(\d{1,2})(?::(\d{2}))?\s*(am|pm)?"
    r"(?:\s*\(([^)]+)\))?",
    re.IGNORECASE,
)

matches = list(pattern.finditer(text))
if matches:
    m = matches[-1]
    month_str, day_str, hour_str, min_str, ampm_str, tz_str = m.groups()
    hour = int(hour_str)
    minute = int(min_str) if min_str else 0

    if ampm_str:
        ampm = ampm_str.lower()
        if ampm == "pm" and hour < 12:
            hour += 12
        elif ampm == "am" and hour == 12:
            hour = 0

    tz_obj = None
    if tz_str and ZoneInfo is not None:
        try:
            tz_obj = ZoneInfo(tz_str.strip())
        except Exception:
            tz_obj = None

    if tz_obj is not None:
        now_dt = datetime.datetime.now(tz_obj)
    else:
        now_dt = datetime.datetime.now().astimezone()

    year = now_dt.year
    month = now_dt.month
    day = now_dt.day

    if month_str and day_str:
        month_map = {
            "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
            "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12
        }
        m_key = month_str[:3].lower()
        if m_key in month_map:
            month = month_map[m_key]
            day = int(day_str)

    try:
        target_dt = now_dt.replace(year=year, month=month, day=day, hour=hour, minute=minute, second=0, microsecond=0)
        if target_dt <= now_dt:
            if month_str and day_str:
                target_dt = target_dt.replace(year=year + 1)
            else:
                target_dt += datetime.timedelta(days=1)

        wait_s = int((target_dt - now_dt).total_seconds()) + buffer_sec
        local_target = target_dt.astimezone().strftime("%Y-%m-%d %H:%M:%S %Z")
        print(f"{wait_s}|해제 시각 ({local_target})")
        sys.exit(0)
    except Exception:
        pass

print(f"{fallback_sec}|기본 쿨다운 (${LIMIT_FALLBACK_MINUTES}분)")
PYEOF
    return 0
  fi

  # Ubuntu GNU date 기반 폴백 파서
  local now_epoch
  now_epoch=$(date +%s)

  local epoch_match
  epoch_match=$(grep -oiE 'usage limit reached\|[0-9]{10}' "$log_file" | tail -n 1 | cut -d'|' -f2 || true)
  if [[ -n "$epoch_match" ]]; then
    local diff=$((epoch_match - now_epoch))
    [[ "$diff" -lt 0 ]] && diff=0
    local reset_human
    reset_human=$(date -d "@${epoch_match}" +"%Y-%m-%d %H:%M:%S" 2>/dev/null || echo "$epoch_match")
    echo "$((diff + buffer_sec))|Epoch 타임스탬프 (${reset_human})"
    return 0
  fi

  local time_match
  time_match=$(grep -oiE 'resets?([[:space:]]+at)?[[:space:]]+[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)' "$log_file" \
    | tail -n 1 \
    | sed -E 's/^resets?([[:space:]]+at)?[[:space:]]+//I' || true)
  if [[ -n "$time_match" ]]; then
    local target_epoch
    target_epoch=$(date -d "today ${time_match}" +%s 2>/dev/null || echo 0)
    if [[ "$target_epoch" -gt 0 ]]; then
      if [[ "$target_epoch" -le "$now_epoch" ]]; then
        target_epoch=$(date -d "tomorrow ${time_match}" +%s 2>/dev/null || echo $((now_epoch + fallback_sec)))
      fi
      local wait_s=$((target_epoch - now_epoch + buffer_sec))
      local reset_human
      reset_human=$(date -d "@${target_epoch}" +"%Y-%m-%d %H:%M:%S %Z")
      echo "${wait_s}|해제 시각 (${reset_human})"
      return 0
    fi
  fi

  echo "${fallback_sec}|기본 쿨다운 (${LIMIT_FALLBACK_MINUTES}분)"
}

# 지정된 초(seconds) 동안 카운트다운을 표시하며 대기 (Ubuntu GNU date & systemd-inhibit 활용)
wait_for_limit_reset() {
  local log_file="$1"
  local context_label="$2"

  if [[ "$WAIT_ON_LIMIT" != "true" ]]; then
    echo -e "${RED}[중단] 토큰/사용량 한도에 도달했습니다 (--no-limit-wait 설정으로 즉시 종료합니다).${NC}" >&2
    exit 3
  fi

  local parsed_info
  parsed_info=$(calculate_limit_wait_seconds "$log_file")
  local wait_seconds="${parsed_info%%|*}"
  local reason_desc="${parsed_info#*|}"

  if [[ -z "$wait_seconds" || ! "$wait_seconds" =~ ^[0-9]+$ || "$wait_seconds" -le 0 ]]; then
    wait_seconds=$((LIMIT_FALLBACK_MINUTES * 60))
  fi

  local resume_time_str
  resume_time_str=$(date -d "+${wait_seconds} seconds" +"%Y-%m-%d %H:%M:%S %Z" 2>/dev/null || echo "${wait_seconds}초 후")

  send_ubuntu_notification \
    "Claude Code 토큰 한도 도달" \
    "${context_label} 중 한도에 도달했습니다. ${resume_time_str}에 자동 재개됩니다." \
    "normal"

  echo -e "\n${YELLOW}======================================================================${NC}"
  echo -e "${BOLD}${YELLOW} [토큰 한도 감지] Claude Code 사용량 한도(Usage/Rate Limit)에 도달했습니다.${NC}"
  echo -e "${YELLOW}======================================================================${NC}"
  echo -e " - 발생 위치      : ${CYAN}${context_label}${NC}"
  echo -e " - 감지 기준      : ${CYAN}${reason_desc}${NC} (여유 시간 +${LIMIT_BUFFER_SECONDS}초 포함)"
  echo -e " - 총 대기 시간   : ${BOLD}$((wait_seconds / 3600))시간 $(((wait_seconds % 3600) / 60))분 $((wait_seconds % 60))초${NC} (${wait_seconds}초)"
  echo -e " - 예상 재개 시각 : ${GREEN}${resume_time_str}${NC}"
  echo -e "${YELLOW}======================================================================${NC}"

  local remaining="$wait_seconds"
  while [[ "$remaining" -gt 0 ]]; do
    local hrs=$((remaining / 3600))
    local mins=$(((remaining % 3600) / 60))
    local secs=$((remaining % 60))

    if [[ -t 1 ]]; then
      printf "\r${CYAN}⏳ 한도 해제 대기 중... 남은 시간: %02d:%02d:%02d (재개 예정: %s)${NC}   " \
        "$hrs" "$mins" "$secs" "$resume_time_str"
      local sleep_chunk=1
      if [[ "$remaining" -gt 60 ]]; then
        sleep_chunk=10
      fi
      ubuntu_safe_sleep "$sleep_chunk"
      remaining=$((remaining - sleep_chunk))
    else
      echo "[대기 중] 남은 시간: ${hrs}시간 ${mins}분 ${secs}초 (재개 예정: ${resume_time_str})"
      local sleep_chunk=300
      if [[ "$remaining" -lt 300 ]]; then
        sleep_chunk="$remaining"
      fi
      ubuntu_safe_sleep "$sleep_chunk"
      remaining=$((remaining - sleep_chunk))
    fi
  done

  if [[ -t 1 ]]; then
    printf "\r${GREEN}✓ 한도 해제 대기 완료! 작업을 다시 재개합니다.                                        ${NC}\n"
  else
    echo -e "${GREEN}[대기 완료] 한도 해제 시각이 되어 작업을 다시 재개합니다.${NC}"
  fi

  send_ubuntu_notification \
    "Claude Code 작업 자동 재개" \
    "토큰 한도 대기가 끝나 '${context_label}' 작업을 다시 진행합니다." \
    "low"
}

# 토큰 한도 대기 및 스펙 충돌 의사결정 가드가 내장된 Claude 실행 래퍼 함수
# $1: 사용할 모델명, $2: 세션 이어하기 여부, $3: 프롬프트, $4: 로그 파일 경로, $5: 단계 설명 라벨
run_claude_with_limit_guard() {
  local target_model="$1"
  local use_continue="$2"
  local prompt_text="$3"
  local log_file="$4"
  local label="$5"

  local limit_wait_count=0
  local current_continue="$use_continue"
  local current_prompt="$prompt_text"

  while true; do
    build_claude_args "$target_model" "$current_continue"

    set +e
    claude "${CLAUDE_ARGS[@]}" "$current_prompt" 2>&1 | tee "$log_file"
    LAST_CLAUDE_EXIT_CODE=${PIPESTATUS[0]}
    set -e

    # 1) 출력 로그에서 토큰/사용량 한도 도달 여부 검사
    if is_usage_limit_reached "$log_file"; then
      limit_wait_count=$((limit_wait_count + 1))
      if [[ "$limit_wait_count" -gt "$MAX_LIMIT_WAITS" ]]; then
        echo -e "${RED}[오류] 최대 토큰 한도 대기 횟수(${MAX_LIMIT_WAITS}회)를 초과하여 종료합니다.${NC}" >&2
        return 1
      fi

      wait_for_limit_reset "$log_file" "$label (한도 대기 ${limit_wait_count}/${MAX_LIMIT_WAITS})"

      if [[ "$RESUME_ON_LIMIT_WAKE" == "true" ]]; then
        current_continue="true"
      fi
      current_prompt="이전 실행 중 토큰 사용량 한도(Usage Limit)에 도달해 일시 중단되었다가 방금 한도가 해제되었어. 현재까지 수정된 파일 상태와 '${ABS_PLAN_FILE}', '${ABS_DECISIONS_FILE}'을 확인하고, 중단되었던 아래 작업을 이어서 끝까지 완료해줘:

${prompt_text}"
      continue
    fi

    # 2) 출력 로그에서 스펙 충돌 / 의사결정 요청([DECISION_REQUIRED]) 감지
    if is_decision_required "$log_file"; then
      USER_DECISION_INPUT=""
      handle_decision_required "$log_file" "$label"

      # 사용자가 결정을 입력한 경우(ask 모드) 즉시 세션을 이어받아 해당 결정대로 수행
      # 주의: 원래 프롬프트의 [DECISION_REQUIRED] 지침을 다시 보내면 에이전트가 혼동하거나
      # 파일 쓰기를 생략할 수 있으므로, 명확한 후속 행동 지침만 전달합니다.
      current_continue="true"
      current_prompt="방금 질문한 스펙 충돌/의사결정 사항에 대해 사용자가 다음과 같이 최종 결정했어:
[사용자 최종 결정]: ${USER_DECISION_INPUT}

이제 결정 요청 블록을 다시 출력하지 말고(해당 마커 문자열을 언급하지도 마), 반드시 Write 또는 Edit 도구를 호출하여 다음 작업을 실제로 디스크에 반영해줘:
1. '${ABS_DECISIONS_FILE}' 파일에 위 최종 결정 사항을 반영해 저장해.
2. '${ABS_PLAN_FILE}' 파일이 디스크에 실제로 존재하는지 확인하고, 위 결정을 반영한 전체 단계별 체크리스트('- [ ] Step 1: ...' 형식)를 '${ABS_PLAN_FILE}'에 실제로 작성(Write)하거나 수정(Edit)해서 저장해.
3. 만약 현재 단계별 구현(Phase 2) 중이었다면 해당 단계의 코드 구현과 검증까지 마치고 '${ABS_PLAN_FILE}'의 해당 체크박스를 '- [x]'로 업데이트해."
      continue
    fi

    break
  done
}

# ==============================================================================
# plan.md 파일 누락 시 자동 탐색 및 세션 기반 강제 복구 함수
# ==============================================================================
locate_or_recover_plan_file() {
  local active_plan_model="${1:-}"

  # 1) 이미 정확한 경로에 파일이 존재하면 즉시 성공
  if [[ -f "$ABS_PLAN_FILE" && -s "$ABS_PLAN_FILE" ]]; then
    return 0
  fi

  echo -e "${YELLOW}[점검] 지정된 경로('${ABS_PLAN_FILE}')에서 파일을 찾지 못해 프로젝트 내 다른 위치를 탐색합니다...${NC}"

  # 2) Git 루트 또는 하위 디렉터리(깊이 3 이내)에 최근 30분 내 생성된 plan.md가 있는지 탐색
  local found_plan=""
  local git_root=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi

  if [[ -n "$git_root" && -f "${git_root}/$(basename "$PLAN_FILE")" && "${git_root}/$(basename "$PLAN_FILE")" != "$ABS_PLAN_FILE" ]]; then
    found_plan="${git_root}/$(basename "$PLAN_FILE")"
  else
    found_plan=$(find "$WORK_DIR" -maxdepth 3 -name "$(basename "$PLAN_FILE")" -mmin -30 2>/dev/null | head -n 1 || true)
  fi

  if [[ -n "$found_plan" && -f "$found_plan" && "$found_plan" != "$ABS_PLAN_FILE" ]]; then
    echo -e "${GREEN}[자동 감지] '${found_plan}' 위치에 생성된 계획 파일을 발견하여 '${ABS_PLAN_FILE}'로 복사합니다.${NC}"
    cp "$found_plan" "$ABS_PLAN_FILE"
    return 0
  fi

  # 3) Claude가 텍스트 응답으로만 계획을 설명하고 실제 Write 도구를 호출하지 않은 경우:
  #    직전 대화 세션(--continue)에 요청하여 디스크에 강제로 파일 생성
  echo -e "${YELLOW}[자동 복구] 에이전트가 텍스트로만 계획을 응답하고 디스크에 '${ABS_PLAN_FILE}'을 쓰지 않았습니다.${NC}"
  echo -e "${BLUE}[자동 복구] 직전 세션(--continue)을 이어받아 '${ABS_PLAN_FILE}' 파일로 즉시 저장을 요청합니다...${NC}"

  local recover_log="${LOG_DIR}/recover_plan_$(date +"%Y%m%d_%H%M%S").log"
  local recover_prompt="방금 네가 수립하고 설명한 계획 내용이 실제 디스크 경로 '${ABS_PLAN_FILE}'에 파일로 생성되지 않았어(또는 다른 경로에 있거나 텍스트로만 출력됨).
지금 즉시 Write 도구(또는 Bash cat << 'EOF' > '${ABS_PLAN_FILE}')를 실행해서, 방금 정리한 전체 계획과 모든 단계별 체크리스트('- [ ] Step 1: ...' 형식)를 정확한 절대 경로 '${ABS_PLAN_FILE}' 파일에 실제로 저장해줘.
소스 코드는 수정하지 말고 '${ABS_PLAN_FILE}'(및 필요한 경우 '${ABS_DECISIONS_FILE}') 파일만 디스크에 생성해."

  run_claude_with_limit_guard \
    "$active_plan_model" \
    "true" \
    "$recover_prompt" \
    "$recover_log" \
    "plan.md 디스크 파일 강제 생성 복구"

  if [[ -f "$ABS_PLAN_FILE" && -s "$ABS_PLAN_FILE" ]]; then
    echo -e "${GREEN}[복구 성공] '${ABS_PLAN_FILE}' 파일이 정상적으로 생성되었습니다!${NC}"
    return 0
  fi

  return 1
}

# plan.md에 체크박스가 하나도 없는 경우 마크다운 체크박스(- [ ])로 정규화
ensure_checkbox_format() {
  if [[ ! -f "$ABS_PLAN_FILE" ]]; then
    return 0
  fi
  local total_boxes
  total_boxes=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\]' "$ABS_PLAN_FILE" || true)
  if [[ "$total_boxes" -eq 0 ]]; then
    echo -e "${YELLOW}[안내] '${PLAN_FILE}'에 마크다운 체크박스(- [ ]) 형식이 감지되지 않았습니다.${NC}"
    if [[ "$DRY_RUN" == "true" ]]; then
      echo -e "${CYAN}[Dry-Run] 실제 실행 시 '${PLAN_FILE}'의 각 단계를 '- [ ]' 체크박스 형식으로 변환합니다.${NC}"
      return 0
    fi
    echo -e "${BLUE}[정규화] Claude Code를 사용해 '${PLAN_FILE}'의 작업 단계를 체크박스(- [ ]) 형식으로 변환합니다...${NC}"
    local active_plan_model="${PLAN_MODEL:-$MODEL}"
    local norm_log="${LOG_DIR}/normalize_plan_$(date +"%Y%m%d_%H%M%S").log"
    run_claude_with_limit_guard \
      "$active_plan_model" \
      "false" \
      "'${ABS_PLAN_FILE}' 파일의 기존 내용을 유지하면서 실행해야 할 각 단계나 작업 항목을 마크다운 체크박스('- [ ] Step N: ...') 형식으로 변환하여 '${ABS_PLAN_FILE}'에 실제로 저장해줘. 소스 코드는 수정하지 말고 '${ABS_PLAN_FILE}'만 업데이트해." \
      "$norm_log" \
      "plan.md 체크박스 정규화"
  fi
}

# ==============================================================================
# Phase 1: 요구사항 기반 계획 수립 (plan.md 자동 생성)
# ==============================================================================
generate_plan_from_requirements() {
  local req_text="$1"
  local active_plan_model="${PLAN_MODEL:-$MODEL}"

  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BOLD}${BLUE} [Phase 1] 요구사항 분석 및 '${PLAN_FILE}' 실행 계획 수립${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  # 기존 plan.md 백업 처리
  if [[ -f "$ABS_PLAN_FILE" && "$PLAN_MODE_ACTION" == "overwrite" && "$DRY_RUN" != "true" ]]; then
    local backup_file="${LOG_DIR}/$(basename "$PLAN_FILE").bak.$(date +"%Y%m%d_%H%M%S")"
    cp "$ABS_PLAN_FILE" "$backup_file"
    echo -e "${YELLOW}[백업] 기존 '${PLAN_FILE}' 파일을 '${backup_file}'에 백업했습니다.${NC}"
    # 이전 계획이 남아 있으면 생성 실패를 성공으로 오인하므로 제거
    rm -f "$ABS_PLAN_FILE"
  fi

  local mode_instruction=""
  if [[ -f "$ABS_PLAN_FILE" && "$PLAN_MODE_ACTION" == "append" ]]; then
    mode_instruction="기존 '${ABS_PLAN_FILE}' 파일의 내용을 유지한 채, 파일 하단에 새로운 요구사항을 위한 단계별 체크리스트 항목('- [ ] Step N: ...')을 추가하여 저장해줘."
  else
    mode_instruction="반드시 Write 도구를 사용하여 정확한 절대 경로 '${ABS_PLAN_FILE}'에 파일을 새로 작성(저장)해줘."
  fi

  local conflict_policy
  conflict_policy=$(get_conflict_policy_instruction)

  local plan_prompt="너는 수석 소프트웨어 아키텍트야. 다음 사용자 요구사항을 달성하기 위해 현재 프로젝트 디렉터리('${WORK_DIR}') 구조와 코드베이스를 먼저 탐색·분석한 뒤, 단계별 실행 계획 파일을 정확한 절대 경로 '${ABS_PLAN_FILE}'에 작성해줘.

[사용자 요구사항]
${req_text}

[계획 수립 지침]
1. 현재 프로젝트의 기술 스택, 디렉터리 구조, 기존 코드 컨벤션, 테스트 환경을 파악해.
2. 아직 실제 애플리케이션 소스 코드나 spec/ 폴더는 수정하지 말고, 오직 계획 수립과 '${ABS_PLAN_FILE}'(및 의사결정 기록용 '${ABS_DECISIONS_FILE}') 파일 생성만 수행해.
3. ${mode_instruction} (주의: 채팅 응답으로만 계획을 출력하고 실제 디스크 파일 '${ABS_PLAN_FILE}'을 쓰지 않으면 스크립트가 실패하므로 반드시 Write 도구를 호출해 파일로 저장해야 해!)
4. '${ABS_PLAN_FILE}' 파일은 다음 구조를 포함해야 해:
   - 요구사항 요약 및 핵심 아키텍처/설계 결정 사항
   - 논리적 순서에 따른 단계별 작업 체크리스트
5. 실행 가능한 모든 단계는 반드시 줄 시작이 마크다운 미완료 체크박스('- [ ] Step N: 짧은 제목') 형식이어야 해. 체크박스 줄은 제목 한 줄(80자 이내, 상세 설명·괄호·' — ' 이후 설명 금지)로만 쓰고, 대상 파일/모듈·구현 내용·검증 기준 같은 상세는 체크박스 목록 아래 별도 섹션 '### Step N' 에 적어(단계마다 하나, 체크박스 없음). 실행 단계가 해당 섹션만 골라 읽을 수 있어야 해.
6. 각 단계는 한 번의 에이전트 세션에서 독립적으로 구현하고 검증할 수 있는 적절한 크기로 쪼개고, 마지막 단계에는 통합 테스트 또는 빌드 검증 단계를 포함해.

${conflict_policy}"

  build_claude_args "$active_plan_model" "false"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[Dry-Run] 계획 수립 실행 예정 명령어:${NC}"
    echo "claude ${CLAUDE_ARGS[*]} \"<PLAN_PROMPT>\""
    echo -e "\n${YELLOW}[Dry-Run] 계획 수립 프롬프트:${NC}\n${plan_prompt}\n"
    return 0
  fi

  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local plan_log="${LOG_DIR}/phase1_planning_${timestamp}.log"

  echo -e "${CYAN}▶ 코드베이스를 분석하고 '${ABS_PLAN_FILE}'을 생성하고 있습니다... (최대 ${PLAN_MAX_TURNS}턴)${NC}"
  local saved_max_turns="$MAX_TURNS"
  MAX_TURNS="$PLAN_MAX_TURNS"
  run_claude_with_limit_guard \
    "$active_plan_model" \
    "false" \
    "$plan_prompt" \
    "$plan_log" \
    "Phase 1: 계획 수립 (${PLAN_FILE} 생성)"

  if grep -q "Reached max turns" "$plan_log" 2>/dev/null; then
    echo -e "${YELLOW}[경고] 계획 수립 중 최대 턴(${PLAN_MAX_TURNS})에 도달했습니다. --plan-turns 값을 늘려 보세요.${NC}"
  fi

  # 파일이 지정된 경로에 없으면 탐색 또는 직전 세션(--continue)을 통해 강제 저장 복구
  if ! locate_or_recover_plan_file "$active_plan_model"; then
    MAX_TURNS="$saved_max_turns"
    echo -e "${RED}[오류] 자동 복구 시도 후에도 '${ABS_PLAN_FILE}' 파일이 생성되지 않았습니다. 로그를 확인해 주세요: ${plan_log}${NC}" >&2
    exit 1
  fi
  MAX_TURNS="$saved_max_turns"

  ensure_checkbox_format

  local total_created
  total_created=$(count_remaining_tasks)
  if [[ "$total_created" -eq 0 ]]; then
    echo -e "${RED}[오류] 계획 수립 후 미완료 단계('- [ ]')가 0개입니다. 계획 생성이 중단되었을 수 있습니다(턴 부족 등). 로그를 확인해 주세요: ${plan_log}${NC}" >&2
    exit 1
  fi
  echo -e "\n${GREEN}[계획 수립 완료] '${PLAN_FILE}'에 총 ${total_created}개의 실행 단계가 준비되었습니다.${NC}"

  if [[ "$AUTO_COMMIT" == "true" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain "$ABS_PLAN_FILE" "$ABS_DECISIONS_FILE" 2>/dev/null)" ]]; then
      git add "$ABS_PLAN_FILE"
      [[ -f "$ABS_DECISIONS_FILE" ]] && git add "$ABS_DECISIONS_FILE"
      git commit -m "docs(plan): generate execution plan in ${PLAN_FILE}" || true
      echo -e "${BLUE}[Git] 생성된 '${PLAN_FILE}' 파일이 커밋되었습니다.${NC}"
    fi
  fi
}

# --recover-plan 옵션이 켜진 경우: 처음부터 다시 분석하지 않고 직전 세션에서 plan.md만 즉시 복구 후 Phase 2 진행
if [[ "$RECOVER_LAST_PLAN" == "true" ]]; then
  echo -e "${BLUE}[세션 복구 모드] 직전 Claude 세션(--continue)에서 수립된 계획을 '${ABS_PLAN_FILE}'로 복구합니다...${NC}"
  if ! locate_or_recover_plan_file "${PLAN_MODEL:-$MODEL}"; then
    echo -e "${RED}[오류] 직전 세션에서 '${ABS_PLAN_FILE}'을 복구하지 못했습니다.${NC}" >&2
    exit 1
  fi
elif [[ -n "$REQUIREMENTS" ]]; then
  # 요구사항이 전달되었으면 Phase 1(계획 수립) 실행
  generate_plan_from_requirements "$REQUIREMENTS"

  if [[ "$PLAN_ONLY" == "true" ]]; then
    echo -e "\n${GREEN}[종료] --plan-only 옵션이 지정되어 계획 수립 후 종료합니다. 생성된 '${PLAN_FILE}'을 확인해 보세요.${NC}"
    exit 0
  fi

  if [[ "$CONFIRM_PLAN" == "true" && "$DRY_RUN" != "true" && -t 0 ]]; then
    echo -e "\n${CYAN}==================== 생성된 ${PLAN_FILE} 내용 ====================${NC}"
    cat "$ABS_PLAN_FILE"
    echo -e "${CYAN}==================================================================${NC}"
    read -r -p "위 계획대로 단계별 실행을 시작할까요? [Y/n] " answer
    case "${answer:-Y}" in
      [Yy]*|"")
        echo -e "${GREEN}단계별 실행을 시작합니다.${NC}"
        ;;
      *)
        echo -e "${YELLOW}사용자 요청으로 실행을 중단했습니다. '${PLAN_FILE}'을 수정한 뒤 다시 실행할 수 있습니다.${NC}"
        exit 0
        ;;
    esac
  fi
elif [[ ! -f "$ABS_PLAN_FILE" ]]; then
  # 요구사항도 없고 현재 폴더에 plan.md도 없을 때:
  # 혹시 방금 전 실행에서 하위/상위 폴더에 plan.md가 만들어졌거나 직전 세션 로그가 있는지 먼저 확인
  if ls "${LOG_DIR}"/phase1_planning_*.log >/dev/null 2>&1 && [[ -t 0 ]]; then
    echo -e "${YELLOW}[안내] 현재 경로에 '${PLAN_FILE}'이 없지만, 이전 계획 수립 로그가 감지되었습니다.${NC}"
    read -r -p "직전 세션(--continue)에서 수립한 계획을 '${PLAN_FILE}'로 복구하여 이어서 진행할까요? [Y/n] " rec_ans
    if [[ "${rec_ans:-Y}" =~ ^[Yy]*$ ]]; then
      if ! locate_or_recover_plan_file "${PLAN_MODEL:-$MODEL}"; then
        echo -e "${RED}[오류] 직전 세션 복구에 실패했습니다.${NC}" >&2
        exit 1
      fi
    fi
  fi

  if [[ ! -f "$ABS_PLAN_FILE" ]]; then
    if [[ -t 0 ]]; then
      echo -e "${YELLOW}[안내] '${PLAN_FILE}' 파일이 없으며 전달된 요구사항도 없습니다.${NC}"
      echo -e "${CYAN}구현할 요구사항을 입력해 주세요 (입력 후 Enter, 취소는 Ctrl+C):${NC}"
      read -r -p "> " REQUIREMENTS
      if [[ -z "$REQUIREMENTS" ]]; then
        echo -e "${RED}[오류] 요구사항이 입력되지 않아 종료합니다.${NC}" >&2
        exit 1
      fi
      generate_plan_from_requirements "$REQUIREMENTS"
    else
      echo -e "${RED}[오류] '${PLAN_FILE}' 파일이 존재하지 않으며 요구사항(--req 또는 --req-file)도 전달되지 않았습니다.${NC}" >&2
      usage
      exit 1
    fi
  fi
fi

# Dry-Run 모드에서 아직 plan.md가 없는 경우 안내 후 종료
if [[ "$DRY_RUN" == "true" && ! -f "$ABS_PLAN_FILE" ]]; then
  echo -e "${YELLOW}[Dry-Run] 현재 '${PLAN_FILE}' 파일이 없으므로 Phase 1 실행 후 생성될 예정입니다.${NC}"
  exit 0
fi

# ==============================================================================
# Phase 2: plan.md 기준 단계별 자동 실행 루프
# ==============================================================================
ensure_checkbox_format

INITIAL_REMAINING=$(count_remaining_tasks)
INITIAL_COMPLETED=$(count_completed_tasks)
TOTAL_TASKS=$((INITIAL_REMAINING + INITIAL_COMPLETED))

echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${BOLD}${BLUE} [Phase 2] '${PLAN_FILE}' 기반 단계별 자동 구현 시작 (Ubuntu)${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e " - 계획 파일   : ${CYAN}${ABS_PLAN_FILE}${NC}"
echo -e " - 진행 현황   : 전체 ${BOLD}${TOTAL_TASKS}${NC}개 중 완료 ${GREEN}${INITIAL_COMPLETED}${NC}개 / 미완료 ${YELLOW}${INITIAL_REMAINING}${NC}개"
echo -e " - 권한 전략   : ${CYAN}${PERMISSION_STRATEGY}${NC}"
echo -e " - 충돌 처리   : ${CYAN}${ON_CONFLICT}${NC} (결정 기록: ${ABS_DECISIONS_FILE})"
echo -e " - 한도 대기   : ${CYAN}${WAIT_ON_LIMIT}${NC} (기본 쿨다운: ${LIMIT_FALLBACK_MINUTES}분, 여유 버퍼: +${LIMIT_BUFFER_SECONDS}초)"
echo -e " - 최대 단계수 : ${CYAN}${MAX_STEPS}${NC} (단계당 최대 ${MAX_TURNS}턴)"
echo -e " - 로그 디렉터리: ${CYAN}${LOG_DIR}${NC}"
echo -e "${BLUE}======================================================================${NC}"

if [[ "$INITIAL_REMAINING" -eq 0 ]]; then
  echo -e "${GREEN}[완료] '${PLAN_FILE}'의 모든 항목이 이미 완료(- [x])되었습니다!${NC}"
  exit 0
fi

STEP_COUNT=0
LAST_CLAUDE_EXIT_CODE=0

while [[ "$STEP_COUNT" -lt "$MAX_STEPS" ]]; do
  REMAINING_BEFORE=$(count_remaining_tasks)
  if [[ "$REMAINING_BEFORE" -eq 0 ]]; then
    echo -e "\n${GREEN}[성공] '${PLAN_FILE}'의 모든 단계가 완료되었습니다!${NC}"
    send_ubuntu_notification "Claude Plan 완료" "'${PLAN_FILE}'의 모든 단계가 성공적으로 완료되었습니다!" "normal"
    exit 0
  fi

  STEP_COUNT=$((STEP_COUNT + 1))
  NEXT_TASK=$(get_next_task)
  COMPLETED_NOW=$(count_completed_tasks)
  TOTAL_NOW=$((COMPLETED_NOW + REMAINING_BEFORE))

  echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
  echo -e "${CYAN}[Step ${STEP_COUNT}/${MAX_STEPS}] 전체 진행도: ${COMPLETED_NOW}/${TOTAL_NOW} 완료 (남은 단계: ${REMAINING_BEFORE}개)${NC}"
  echo -e "${YELLOW}▶ 현재 수행 단계:${NC} ${NEXT_TASK}"
  echo -e "${CYAN}----------------------------------------------------------------------${NC}"

  USE_CONT="false"
  if [[ "$CONTINUE_SESSION" == "true" && "$STEP_COUNT" -gt 1 ]]; then
    USE_CONT="true"
  fi
  build_claude_args "$MODEL" "$USE_CONT"

  VERIFY_INSTRUCTION=""
  if [[ -n "$VERIFY_CMD" ]]; then
    VERIFY_INSTRUCTION="4. 구현 후 반드시 '${VERIFY_CMD}' 명령어를 실행하여 테스트/검증을 통과하는지 확인하고 오류가 있다면 수정해."
  else
    VERIFY_INSTRUCTION="4. 변경 사항과 관련된 빌드, 린트, 테스트가 있다면 실행하여 정상 동작을 검증해."
  fi

  CONFLICT_POLICY=$(get_conflict_policy_instruction)

  NEXT_SHORT="$(short_task "$NEXT_TASK")"

  PROMPT="'${ABS_PLAN_FILE}'의 머리말(첫 '---' 앞)과 아래 단계 항목만 읽고(파일 전체를 읽지 말 것; 필요한 섹션만 grep/offset으로 읽어), 다음 지침에 따라 정확히 한 단계만 수행해줘:
1. '${ABS_PLAN_FILE}'에서 아직 완료되지 않은 첫 번째 미완료 항목('- [ ] ${NEXT_TASK}')을 확인해.
   상세 요구사항이 별도 '### Step N' 섹션에 있으면(grep -n 하여 '### Step N' 제목 위치 확인) 그 섹션만 읽어.
2. 해당 단계의 요구사항을 프로젝트 코드베이스에 완전히 구현해.
3. 다음 미완료 단계까지 미리 진행하지 말고, 오직 이번 단계('${NEXT_SHORT}')에만 집중해. (구현 중 새롭게 발견된 필수 세부 작업이 있다면 '${ABS_PLAN_FILE}'에 추가할 수 있어.)
${VERIFY_INSTRUCTION}
5. 작업과 검증이 성공적으로 끝나면 반드시 Edit/Write 도구를 사용해 '${ABS_PLAN_FILE}' 파일에서 해당 항목의 '- [ ]'를 '- [x]'로 업데이트하고 수행한 작업 요약을 출력해.

${CONFLICT_POLICY}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[Dry-Run] 단계 실행 예정 명령어:${NC}"
    echo "claude ${CLAUDE_ARGS[*]} \"<STEP_PROMPT>\""
    echo -e "\n${YELLOW}[Dry-Run] 단계 실행 프롬프트:${NC}\n${PROMPT}"
    exit 0
  fi

  ATTEMPT=0
  STEP_SUCCESS="false"

  while [[ "$ATTEMPT" -le "$MAX_RETRIES" ]]; do
    ATTEMPT=$((ATTEMPT + 1))
    TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
    LOG_FILE="${LOG_DIR}/step_${STEP_COUNT}_attempt_${ATTEMPT}_${TIMESTAMP}.log"

    if [[ "$ATTEMPT" -gt 1 ]]; then
      echo -e "${YELLOW}[재시도 ${ATTEMPT}/${MAX_RETRIES}] 이전 시도에서 '${PLAN_FILE}' 체크박스가 갱신되지 않았거나 검증에 실패했습니다.${NC}"
    fi

    # 토큰 한도 대기 및 스펙 충돌 의사결정 가드가 내장된 실행 함수 호출
    run_claude_with_limit_guard \
      "$MODEL" \
      "$USE_CONT" \
      "$PROMPT" \
      "$LOG_FILE" \
      "Step ${STEP_COUNT}: ${NEXT_TASK}"

    EXIT_CODE="$LAST_CLAUDE_EXIT_CODE"

    if grep -q "Reached max turns" "$LOG_FILE" 2>/dev/null; then
      echo -e "${YELLOW}[경고] '${NEXT_SHORT}' 단계 수행 중 최대 턴(${MAX_TURNS})에 도달했습니다. --max-turns 값을 늘려 보세요.${NC}"
    fi

    # 현재 작업 항목이 여전히 미완료(- [ ])로 남아있는지 확인
    STILL_UNCHECKED="false"
    if [[ "$(get_next_task)" == "$NEXT_TASK" ]]; then
      STILL_UNCHECKED="true"
    fi

    # 외부 검증 명령어가 지정된 경우 스크립트 차원에서도 재검증
    VERIFY_PASSED="true"
    if [[ -n "$VERIFY_CMD" ]]; then
      echo -e "${BLUE}[검증] '${VERIFY_CMD}' 실행 중...${NC}"
      if ! bash -c "$VERIFY_CMD"; then
        echo -e "${RED}[검증 실패] '${VERIFY_CMD}' 명령어가 실패했습니다.${NC}"
        VERIFY_PASSED="false"
      fi
    fi

    if [[ "$EXIT_CODE" -eq 0 && "$VERIFY_PASSED" == "true" && "$STILL_UNCHECKED" == "false" ]]; then
      STEP_SUCCESS="true"
      REMAINING_AFTER=$(count_remaining_tasks)
      echo -e "${GREEN}[단계 완료] '${NEXT_TASK}' 완료! (남은 항목: ${REMAINING_AFTER}개)${NC}"
      break
    fi

    # 재시도 시 프롬프트 보강
    PROMPT="이전 시도에서 '${NEXT_SHORT}' 단계('- [ ] ${NEXT_SHORT}…' 항목)가 완전히 마무리되지 않았거나 '${ABS_PLAN_FILE}'의 체크박스('- [ ]' -> '- [x]')가 실제 디스크 파일에 업데이트되지 않았어.
현재 코드 상태와 테스트/검증 오류를 점검하고 '${NEXT_SHORT}' 단계를 끝까지 완료한 뒤, 반드시 Edit/Write 도구로 '${ABS_PLAN_FILE}'에서 해당 항목을 '- [x]'로 변경해줘.

${CONFLICT_POLICY}"
  done

  if [[ "$STEP_SUCCESS" != "true" ]]; then
    echo -e "${RED}[중단] '${NEXT_TASK}' 단계를 $((MAX_RETRIES + 1))회 시도했으나 완료되지 않았습니다.${NC}" >&2
    echo -e "${RED}마지막 로그 파일을 확인해 주세요: ${LOG_FILE}${NC}" >&2
    send_ubuntu_notification "Claude Plan 오류 중단" "'${NEXT_TASK}' 단계에서 오류가 발생해 중단되었습니다." "critical"
    exit 1
  fi

  # 자동 Git 커밋 옵션 처리
  if [[ "$AUTO_COMMIT" == "true" ]]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [[ -n "$(git status --porcelain)" ]]; then
        git add -A
        git commit -m "chore(plan): complete step ${STEP_COUNT} - ${NEXT_SHORT}" || true
        echo -e "${BLUE}[Git] Step ${STEP_COUNT} 완료 체크포인트 커밋이 생성되었습니다.${NC}"
      fi
    fi
  fi
done

FINAL_REMAINING=$(count_remaining_tasks)
if [[ "$FINAL_REMAINING" -eq 0 ]]; then
  echo -e "\n${GREEN}[성공] 모든 단계(총 ${STEP_COUNT}단계)를 완료했습니다!${NC}"
  send_ubuntu_notification "Claude Plan 완료" "총 ${STEP_COUNT}단계를 모두 완료했습니다!" "normal"
  exit 0
else
  echo -e "\n${YELLOW}[종료] 최대 단계 횟수(${MAX_STEPS})에 도달하여 중단되었습니다. (남은 항목: ${FINAL_REMAINING}개)${NC}"
  send_ubuntu_notification "Claude Plan 최대 단계 도달" "최대 단계 횟수(${MAX_STEPS})에 도달하여 중단되었습니다." "normal"
  exit 2
fi