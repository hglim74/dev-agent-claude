#!/usr/bin/env bash
# ==============================================================================
# generate_spec.bash - 개략적인 요구사항을 받아 Claude Code CLI로
#                       개발에 바로 사용 가능한 사양서 "문서 세트"를
#                       spec/ 폴더 아래에 자동 생성하는 Ubuntu/GNU 환경용 스크립트
#
# 설명:
#   1. [문서 계획 수립] 요구사항을 분석해 필요한 문서 목록(개요/기능요구사항/
#      데이터·API 설계/비기능요구사항/테스트 계획 등, 프로젝트 규모에 맞게 가변적)과
#      저장할 폴더 구조를 정하고, 그 계획을 'spec-plan.md' 체크리스트로 저장합니다.
#   2. [문서별 생성 및 검증] spec-plan.md의 미완료 항목(문서)을 하나씩 Claude에게
#      맡겨 실제 파일로 작성시키고, 같은 호출 안에서 해당 문서 자체를 자기 검증·보완한
#      뒤 체크박스를 완료로 표시합니다. 모든 문서가 완료될 때까지 반복합니다.
#   3. [문서간 충돌 검증] 모든 문서가 완성되면 spec/ 전체를 다시 읽혀 문서 간
#      모순(동일 항목에 대한 서로 다른 설명, 용어/ID 불일치, 끊어진 참조 등)을 찾아
#      직접 수정하게 합니다.
#   4. [최종 중복/충돌 검사 및 최적화] 마지막으로 전체 문서 세트를 다시 검토해 중복
#      내용을 정리하고 남은 충돌을 해소하며, 문서 목록을 안내하는 인덱스를 만듭니다.
#   5. [요구사항 모호성/충돌 처리] 위 모든 단계에서 사람의 결정이 꼭 필요한 경우
#      run_plan.bash와 동일한 [DECISION_REQUIRED] + decisions.md + Slack 흐름으로
#      처리합니다 (ask/pause/auto).
#   6. [토큰 한도 자동 대기 및 재개] 사용량 한도(Usage Limit)에 도달하면 해제 시각을
#      계산해 대기한 뒤 '--continue'로 이어서 진행합니다.
#   7. [파일 생성 검증 및 자동 복구] Claude가 파일을 저장하지 않고 텍스트로만
#      출력한 경우 자동 탐색·복구합니다.
#
# 참고 문서:
#   - Claude Code CLI Reference: https://code.claude.com/docs/en/cli-reference
#   - Permission Modes: https://code.claude.com/docs/en/permission-modes
#   - Usage Limit Reference: https://github.com/anthropics/claude-code/issues/2087
# ==============================================================================

set -euo pipefail

# SSH 세션이 끊어져도(SIGHUP) 대기 루프나 실행 중인 작업이 중단되지 않도록 보호
trap '' HUP

# 기본 설정값 (환경변수로도 오버라이드 가능)
SPEC_DIR="${SPEC_DIR:-spec}"                       # 생성된 문서들이 저장될 폴더
SPEC_PLAN_FILE="${SPEC_PLAN_FILE:-spec-plan.md}"   # 문서 목록/계획 체크리스트 파일
DECISIONS_FILE="${DECISIONS_FILE:-decisions.md}"
REQUIREMENTS="${REQUIREMENTS:-}"
REQ_FILE="${REQ_FILE:-}"
PLAN_MODE_ACTION="${PLAN_MODE_ACTION:-overwrite}" # overwrite | append
PLAN_ONLY="${PLAN_ONLY:-false}"
CONFIRM_PLAN="${CONFIRM_PLAN:-false}"
RECOVER_LAST_PLAN="${RECOVER_LAST_PLAN:-false}"
ON_CONFLICT="${ON_CONFLICT:-ask}"                 # ask | pause | auto
MAX_STEPS="${MAX_STEPS:-20}"                      # 한 번 실행에서 생성할 최대 문서 수
MAX_TURNS="${MAX_TURNS:-30}"
MAX_RETRIES="${MAX_RETRIES:-2}"
PERMISSION_STRATEGY="${PERMISSION_STRATEGY:-bypass}" # bypass | auto | acceptEdits | allowed
ALLOWED_TOOLS="${ALLOWED_TOOLS:-Bash,Read,Edit,Write}"
MODEL="${MODEL:-}"
PLAN_MODEL="${PLAN_MODEL:-}"
FALLBACK_MODEL="${FALLBACK_MODEL:-}"
MAX_BUDGET_USD="${MAX_BUDGET_USD:-}"
AUTO_COMMIT="${AUTO_COMMIT:-false}"
SKIP_CROSS_CHECK="${SKIP_CROSS_CHECK:-false}"     # true면 문서간 충돌 검증(Stage C) 생략
SKIP_OPTIMIZE="${SKIP_OPTIMIZE:-false}"           # true면 최종 중복/충돌 검사·최적화(Stage D) 생략
LOG_DIR="${LOG_DIR:-.claude-spec-logs}"
DRY_RUN="false"

# Slack 연동 설정 (의사결정 필요 시 알림 + 스레드 답글로 답변 수신) - run_plan.bash와 동일
SLACK_BOT_TOKEN="${SLACK_BOT_TOKEN:-}"
SLACK_CHANNEL="${SLACK_CHANNEL:-}"
SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:-}"
SLACK_POLL_INTERVAL="${SLACK_POLL_INTERVAL:-10}"
SLACK_REPLY_TIMEOUT="${SLACK_REPLY_TIMEOUT:-0}"

# 토큰/사용량 한도(Usage Limit) 대기 관련 설정
WAIT_ON_LIMIT="${WAIT_ON_LIMIT:-true}"
LIMIT_FALLBACK_MINUTES="${LIMIT_FALLBACK_MINUTES:-15}"
LIMIT_BUFFER_SECONDS="${LIMIT_BUFFER_SECONDS:-60}"
MAX_LIMIT_WAITS="${MAX_LIMIT_WAITS:-24}"
RESUME_ON_LIMIT_WAKE="${RESUME_ON_LIMIT_WAKE:-true}"

# Ubuntu 전용 설정
USE_TMUX="${USE_TMUX:-false}"
TMUX_SESSION_NAME="${TMUX_SESSION_NAME:-claude-spec}"
INHIBIT_SLEEP="${INHIBIT_SLEEP:-true}"
ENABLE_NOTIFY="${ENABLE_NOTIFY:-true}"
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
SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"

usage() {
  cat <<EOF
사용법:
  $(basename "$0") [옵션] ["요구사항 텍스트"]

요구사항 옵션:
  -q, --req <요구사항>          구현할 개략적인 요구사항 텍스트 (위치 인자로도 전달 가능)
  -i, --req-file <파일경로>     요구사항이 적힌 메모/문서 파일 경로

문서 계획 수립 옵션:
      --spec-dir <폴더경로>     생성된 문서들을 저장할 폴더 (기본값: ${SPEC_DIR})
  -f, --plan <파일경로>         문서 목록/계획 체크리스트 파일 경로 (기본값: ${SPEC_PLAN_FILE})
      --append-plan             기존 ${SPEC_PLAN_FILE} 끝에 새 요구사항에 대한 문서 항목들을 추가
      --plan-only               문서 계획(${SPEC_PLAN_FILE})과 폴더 구조만 만들고 종료
      --confirm-plan             ${SPEC_PLAN_FILE} 생성 후 내용을 출력하고 사용자 확인(Y/n) 후 진행
      --plan-model <모델명>     문서 계획 수립 단계에 사용할 모델 지정 (예: opus)
      --recover-plan            직전 세션(--continue)에서 작성된 계획을 복구 후 이어서 진행

의사결정(Decision) 제어 옵션:
      --on-conflict <모드>      요구사항이 모순되거나 핵심 결정이 필요할 때 처리 방식 (기본값: ask)
                                  - ask   : 터미널에서 선택지를 보여주고 사용자 입력을 받아 즉시 재개
                                  - pause : ${DECISIONS_FILE}에 내용과 선택지를 기록하고 일시 정지
                                  - auto  : 보수적 기준으로 자율 결정 후 ${DECISIONS_FILE}에 기록 후 진행
      --decisions <파일경로>    의사결정 기록 파일 경로 (기본값: ${DECISIONS_FILE})

문서 생성 및 검증 단계 제어:
  -s, --max-steps <숫자>        1회 실행당 생성할 최대 문서 수 (기본값: ${MAX_STEPS})
  -t, --max-turns <숫자>        호출당 최대 에이전트 턴 수 (기본값: ${MAX_TURNS})
  -r, --max-retries <숫자>      문서 생성/검증 실패 시 최대 재시도 횟수 (기본값: ${MAX_RETRIES})
      --no-cross-check          모든 문서 생성 후 "문서간 충돌 검증" 단계를 건너뜀
      --no-optimize             마지막 "중복/충돌 검사 및 최적화" 단계를 건너뜀

실행 제어 옵션:
  -p, --perm <모드>             권한 승인 방식 (기본값: ${PERMISSION_STRATEGY})
                                  bypass | auto | acceptEdits | allowed
  -m, --model <모델명>          문서 생성/검증 단계에 사용할 모델
      --fallback-model <모델들> 기본 모델 과부하 시 대체할 모델 목록
  -b, --max-budget <USD>        호출당 최대 API 비용 한도
  -g, --auto-commit             문서별 생성 및 최종 단계 완료 후 자동으로 Git 커밋

Slack 연동 옵션:
      --slack-token <토큰>      Slack Bot Token (환경변수 SLACK_BOT_TOKEN)
      --slack-channel <채널ID>  알림/답변 채널 ID (환경변수 SLACK_CHANNEL)
      --slack-webhook <URL>     알림 전용 Incoming Webhook
      --slack-timeout <분>      Slack 답변 대기 제한 (기본값: 0=무제한)

토큰/사용량 한도(Usage Limit) 대기 옵션:
  -w, --limit-wait <분>         해제 시각 미표시 시 기본 재시도 대기 시간(분) (기본값: 15)
      --limit-buffer <초>       파싱된 해제 시각에 추가할 안전 여유 시간(초) (기본값: 60)
      --no-limit-wait           토큰 한도 도달 시 대기하지 않고 즉시 종료

Ubuntu 환경 전용 옵션:
      --tmux [세션명]           tmux 백그라운드 세션에서 시작 (기본 세션명: ${TMUX_SESSION_NAME})
      --no-inhibit              systemd-inhibit 절전 방지 기능 비활성화
      --check-env               환경 진단 후 종료

기타 옵션:
      --dry-run                 실제 실행 없이 계획 수립 호출 명령어/프롬프트만 확인
  -h, --help                    도움말 출력

실행 예시:
  # 1) 요구사항으로 문서 세트 생성 (계획 -> 문서별 생성/검증 -> 충돌검증 -> 최적화)
  ./$(basename "$0") "모바일 앱에 푸시 알림 기능 추가"

  # 2) 계획만 만들고 검토 후 생성 시작
  ./$(basename "$0") --req-file memo.md --plan-only
  ./$(basename "$0")                      # 기존 ${SPEC_PLAN_FILE}의 미완료 문서부터 이어서 생성

  # 3) 계획 확인 후 진행, 완료 시 자동 커밋
  ./$(basename "$0") --req-file memo.md --confirm-plan --auto-commit

  # 4) 완전 무인 실행: 모호성 발생 시 보수적 기준으로 자율 결정
  ./$(basename "$0") --tmux --on-conflict auto --req-file memo.md

  # 5) 생성된 문서 중 하나를 바탕으로 run_plan.bash로 구현 시작
  run_plan.bash --req-file ${SPEC_DIR}/02-functional-requirements.md
EOF
}

# Ubuntu 데스크톱 알림 전송 함수
send_ubuntu_notification() {
  local title="$1"
  local message="$2"
  local urgency="${3:-normal}"

  if [[ "$ENABLE_NOTIFY" == "true" ]] && command -v notify-send >/dev/null 2>&1; then
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
      notify-send -u "$urgency" -a "Claude Spec Generator" "$title" "$message" >/dev/null 2>&1 || true
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
    --spec-dir)
      SPEC_DIR="$2"
      shift 2
      ;;
    -f|--plan)
      SPEC_PLAN_FILE="$2"
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
    -s|--max-steps)
      MAX_STEPS="$2"
      shift 2
      ;;
    -t|--max-turns)
      MAX_TURNS="$2"
      shift 2
      ;;
    -r|--max-retries)
      MAX_RETRIES="$2"
      shift 2
      ;;
    --no-cross-check)
      SKIP_CROSS_CHECK="true"
      shift
      ;;
    --no-optimize)
      SKIP_OPTIMIZE="true"
      shift
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
    -g|--auto-commit)
      AUTO_COMMIT="true"
      shift
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

if ! [[ "$MAX_STEPS" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}[오류] --max-steps 값은 0 이상의 정수여야 합니다 (입력값: ${MAX_STEPS}).${NC}" >&2
  exit 1
fi

if [[ "$CHECK_ENV_ONLY" == "true" ]]; then
  check_ubuntu_environment
  exit 0
fi

# Claude가 다른 하위/상위 디렉터리에 파일을 만드는 문제를 방지하기 위해 절대 경로 계산
WORK_DIR="$(pwd)"
if command -v realpath >/dev/null 2>&1; then
  ABS_SPEC_DIR="$(realpath -m "$SPEC_DIR")"
  ABS_SPEC_PLAN_FILE="$(realpath -m "$SPEC_PLAN_FILE")"
  ABS_DECISIONS_FILE="$(realpath -m "$DECISIONS_FILE")"
else
  [[ "$SPEC_DIR" = /* ]] && ABS_SPEC_DIR="$SPEC_DIR" || ABS_SPEC_DIR="${WORK_DIR}/${SPEC_DIR}"
  [[ "$SPEC_PLAN_FILE" = /* ]] && ABS_SPEC_PLAN_FILE="$SPEC_PLAN_FILE" || ABS_SPEC_PLAN_FILE="${WORK_DIR}/${SPEC_PLAN_FILE}"
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

# 파이프(stdin)로 전달된 요구사항 읽기 지원
if [[ -z "$REQUIREMENTS" && "$RECOVER_LAST_PLAN" != "true" && ! -t 0 ]]; then
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
[[ "$DRY_RUN" != "true" ]] && mkdir -p "$ABS_SPEC_DIR"

# Ubuntu flock을 이용한 단일 프로세스 중복 실행 방지 락(Lock)
LOCK_FILE="${LOG_DIR}/generate_spec.lock"
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
      --who="generate_spec.bash" \
      --why="Waiting for Claude Code token limit reset" \
      --mode=block \
      sleep "$seconds" 2>/dev/null || sleep "$seconds"
  else
    sleep "$seconds"
  fi
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
# 요구사항 모호성/충돌 및 의사결정(Decision) 처리 함수들 (run_plan.bash와 동일한 체계)
# ==============================================================================

# 현재 설정된 --on-conflict 모드에 따라 프롬프트에 주입할 지침 생성
# $1: 사람이 읽을 "현재 작업 대상"에 대한 설명 (따옴표 포함해서 전달, 예: "'${ABS_SPEC_PLAN_FILE}'")
get_conflict_policy_instruction() {
  local target_desc="$1"
  local decisions_context=""
  if [[ -f "$ABS_DECISIONS_FILE" ]]; then
    decisions_context="참고: 프로젝트에 이미 기록된 '${ABS_DECISIONS_FILE}' 파일이 존재하므로, 먼저 해당 파일의 기존 의사결정 내역을 확인하고 일관되게 준수해."
  fi

  if [[ "$ON_CONFLICT" == "auto" ]]; then
    cat <<EOF
[요구사항 모호성/의사결정 지침 (--on-conflict auto)]
${decisions_context}
- 작업 중 요구사항이 서로 모순되거나, 핵심 비즈니스/설계 결정(예: 인증 방식, 과금 정책, 데이터 보존 기간) 없이는 진행할 수 없는 상황이 발생하면 멈추지 말고 다음 우선순위에 따라 자율적으로 결정해:
  1순위: 사용자가 전달한 요구사항 원문 및 '${ABS_DECISIONS_FILE}'의 기존 결정 사항
  2순위: 기존 코드베이스의 아키텍처 컨벤션 및 하위 호환성(Backward Compatibility) 유지
  3순위: 부작용이 가장 적은 보수적이고 표준적인 설계 방식 선택
- 자율 결정을 내린 경우 '${ABS_DECISIONS_FILE}' 파일에 (없으면 생성하여) [날짜, 이슈, 선택한 방안 및 근거]를 ADR(Architecture Decision Record) 형식으로 기록하고, 해당 결정을 반영해 작업을 끝까지 완료해.
EOF
  else
    cat <<EOF
[요구사항 모호성/의사결정 지침 (--on-conflict ${ON_CONFLICT})]
${decisions_context}
- 사소한 세부사항, 모호하지만 합리적인 기본값이 있는 사항, 기존 컨벤션으로 정해지는 사항은 묻지 말고 스스로 판단해 반영해. 이런 판단은 '${ABS_DECISIONS_FILE}'에 한 줄만 남겨.
- 결정 요청은 최후의 수단이야. 아래 경우에만 해당해: 요구사항 자체가 서로 모순되어 둘을 동시에 만족할 수 없거나, 기존 핵심 동작/정책을 깨뜨리는 파괴적 변경이 불가피하거나, 사용자의 비즈니스 의사결정 없이는 어느 쪽으로도 진행할 수 없는 경우. 이때는 임의로 추측해서 작성하지 마.
- 위 경우에 해당하지 않으면(모호성/충돌이 없으면) 아래 결정 요청 블록과 그 마커 문자열을 절대 출력하거나 언급하지 말고, 그냥 작업을 끝까지 진행해.
- 중요: 결정이 필요한 사항이 있더라도, 먼저 작업 대상(${target_desc})은 반드시 Write 또는 Edit 도구로 디스크에 실제로 반영해 두고(미결정 사항은 해당 부분에 '(결정 필요)'로 표시), 그 다음에 질문을 출력해야 해! 디스크에 반영하지 않고 텍스트로만 출력하면 안 돼.
- 중대한 모호성/충돌이 있는 경우:
  1. 작업 대상(${target_desc})이 디스크에 저장되어 있는지 확인해.
  2. '${ABS_DECISIONS_FILE}' 파일에 충돌 원인과 선택지(권장안 포함)를 상세히 기록해.
  3. 출력 마지막에 반드시 아래 형식의 블록을 정확히 출력하고 턴을 종료해:
[DECISION_REQUIRED]
- 단계: (무엇을 작업하던 중이었는지)
- 충돌/이슈 요약: (무엇이 모순되거나 모호한지 설명)
- 선택지 1 (권장): (방안 설명 및 장단점)
- 선택지 2: (대안 설명 및 장단점)
[/DECISION_REQUIRED]
EOF
  fi
}

# 로그 파일에서 [DECISION_REQUIRED] 블록이 출력되었는지 감지 (완결된 블록만 인정)
is_decision_required() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi
  [[ -n "$(extract_decision_block "$log_file")" ]]
}

# 로그 파일에서 마지막 완결된 [DECISION_REQUIRED] ... [/DECISION_REQUIRED] 블록 추출
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
# Slack 연동: 알림 전송 및 스레드 답글 수신 (curl + python3 사용) - run_plan.bash와 동일
# ------------------------------------------------------------------------------

slack_reply_enabled() {
  [[ -n "$SLACK_BOT_TOKEN" && -n "$SLACK_CHANNEL" ]] \
    && command -v curl >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1
}

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
  echo -e "${BOLD}${YELLOW} [의사결정 필요] 요구사항 모호성/충돌이 감지되었습니다!${NC}"
  echo -e "${YELLOW}======================================================================${NC}"
  echo -e " - 발생 위치 : ${CYAN}${step_label}${NC}"
  echo -e " - 기록 파일 : ${CYAN}${ABS_DECISIONS_FILE}${NC}"
  echo -e "${YELLOW}----------------------------------------------------------------------${NC}"
  if [[ -n "$decision_block" ]]; then
    echo "$decision_block"
  else
    tail -n 25 "$log_file"
  fi
  echo -e "${YELLOW}======================================================================${NC}"

  send_ubuntu_notification \
    "Claude Spec Generator 의사결정 필요" \
    "${step_label} 진행 중 요구사항 모호성/충돌이 발생했습니다. 확인이 필요합니다." \
    "critical"

  local slack_ts="" decision_source="터미널"
  if slack_notify_enabled; then
    local slack_msg
    slack_msg=":warning: *Claude Spec Generator — 의사결정 필요*
• 위치: ${step_label}
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

  local use_slack_reply="false"
  if [[ -n "$slack_ts" && "$slack_ts" != "webhook" && "$ON_CONFLICT" != "pause" ]] && slack_reply_enabled; then
    use_slack_reply="true"
  fi

  if [[ "$ON_CONFLICT" == "pause" || ( ! -t 0 && "$use_slack_reply" != "true" ) ]]; then
    echo -e "${RED}[일시 정지] '--on-conflict pause' (또는 비대화형 세션) 상태이므로 실행을 안전하게 일시 정지합니다.${NC}"
    echo -e "해결 방법:"
    echo -e "  1) '${CYAN}${ABS_DECISIONS_FILE}${NC}' 또는 '${CYAN}${ABS_SPEC_PLAN_FILE}${NC}'에 원하시는 결정 방향을 작성/수정하세요."
    echo -e "  2) 같은 명령으로 '${CYAN}./$(basename "$0")${NC}'를 다시 실행하면(필요하면 '${CYAN}--recover-plan${NC}') 이어서 진행됩니다."
    exit 4
  fi

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
    echo -e "${YELLOW}[일시 정지] 사용자 요청으로 스크립트를 중단합니다. '${DECISIONS_FILE}' 수정 후 다시 실행하면 이어서 진행됩니다.${NC}"
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
# 토큰/사용량 한도(Usage Limit / Rate Limit) 감지 및 해제 시각까지 대기 (run_plan.bash와 동일)
# ==============================================================================

is_usage_limit_reached() {
  local log_file="$1"
  if [[ ! -f "$log_file" ]]; then
    return 1
  fi
  grep -qiE \
    'usage limit reached|limit will reset at|hit your limit|resets[[:space:]]+(at[[:space:]]+)?[0-9]{1,2}(:[0-9]{2})?[[:space:]]*(am|pm)|rate_limit_error|exceed your account'\''s rate limit|Error:[[:space:]]*429|too many requests|5-hour limit|weekly limit' \
    "$log_file"
}

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

m_epoch = re.search(r"usage limit reached\|(\d{10})", text, re.IGNORECASE)
if m_epoch:
    target_ts = int(m_epoch.group(1))
    wait_s = max(target_ts - now_ts, 0) + buffer_sec
    reset_str = datetime.datetime.fromtimestamp(target_ts).strftime("%Y-%m-%d %H:%M:%S")
    print(f"{wait_s}|Epoch 타임스탬프 ({reset_str})")
    sys.exit(0)

m_retry = re.search(r"retry[- ]after[:\s]+(\d+)\s*(seconds?|secs?|s|minutes?|mins?|m)?", text, re.IGNORECASE)
if m_retry:
    val = int(m_retry.group(1))
    unit = (m_retry.group(2) or "s").lower()
    if unit.startswith("m"):
        val *= 60
    wait_s = val + buffer_sec
    print(f"{wait_s}|Retry-After ({val}초)")
    sys.exit(0)

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

# 토큰 한도 대기 및 의사결정 가드가 내장된 Claude 실행 래퍼 함수
# $1: 사용할 모델명, $2: 세션 이어하기 여부, $3: 프롬프트, $4: 로그 파일 경로, $5: 작업 설명 라벨
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
      current_prompt="이전 실행 중 토큰 사용량 한도(Usage Limit)에 도달해 일시 중단되었다가 방금 한도가 해제되었어. 현재까지 작성된 파일 상태와 '${ABS_SPEC_PLAN_FILE}', '${ABS_DECISIONS_FILE}'을 확인하고, 중단되었던 아래 작업을 이어서 끝까지 완료해줘:

${prompt_text}"
      continue
    fi

    if is_decision_required "$log_file"; then
      USER_DECISION_INPUT=""
      handle_decision_required "$log_file" "$label"

      current_continue="true"
      current_prompt="방금 질문한 요구사항 모호성/충돌 사항에 대해 사용자가 다음과 같이 최종 결정했어:
[사용자 최종 결정]: ${USER_DECISION_INPUT}

이제 결정 요청 블록을 다시 출력하지 말고(해당 마커 문자열을 언급하지도 마), 반드시 Write 또는 Edit 도구를 호출하여 다음 작업을 실제로 디스크에 반영해줘:
1. '${ABS_DECISIONS_FILE}' 파일에 위 최종 결정 사항을 반영해 저장해.
2. 방금 작업하던 대상 파일을 이 결정에 맞게 실제로 수정(Edit)하거나 새로 작성(Write)해서 저장해."
      continue
    fi

    break
  done
}

# ==============================================================================
# spec-plan.md 파싱 헬퍼: 체크리스트 상태 / Step 번호 / 각 Step의 저장 경로 추출
# ==============================================================================

# 남은 미완료 항목(- [ ] 또는 * [ ]) 개수 계산
count_remaining_tasks() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi
  grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$file" || true
}

# 완료된 항목(- [x] 또는 - [X]) 개수 계산
count_completed_tasks() {
  local file="$1"
  if [[ ! -f "$file" ]]; then
    echo 0
    return
  fi
  grep -cE '^[[:space:]]*[-*][[:space:]]+\[[xX]\]' "$file" || true
}

# 다음 진행할 첫 번째 미완료 항목 추출 (예: "Step 2: 기능 요구사항 명세")
get_next_task() {
  local file="$1"
  grep -m 1 -E '^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\]' "$file" \
    | sed -E 's/^[[:space:]]*[-*][[:space:]]+\[[[:space:]]\][[:space:]]*//' || true
}

# 계획 파일에 등장하는 모든 Step 번호를 오름차순/중복 제거하여 나열
get_all_step_numbers() {
  local file="$1"
  grep -oE 'Step[[:space:]]+[0-9]+:' "$file" 2>/dev/null | grep -oE '[0-9]+' | sort -n -u || true
}

# NEXT_TASK 텍스트("Step N: 제목")에서 Step 번호만 추출. 실패 시 빈 문자열
get_step_number() {
  local task_text="$1"
  if [[ "$task_text" =~ ^Step[[:space:]]+([0-9]+): ]]; then
    echo "${BASH_REMATCH[1]}"
  else
    echo ""
  fi
}

# 계획 파일의 "### Step N" 상세 섹션에서 "파일 경로:" 줄의 값만 추출 (없으면 빈 출력)
get_step_filepath() {
  local file="$1"
  local n="$2"
  awk -v n="$n" '
    {
      if ($0 ~ ("^###[[:space:]]+Step[[:space:]]+" n "([^0-9]|$)")) { grab = 1; next }
      if ($0 ~ /^###[[:space:]]+Step[[:space:]]+[0-9]+/) { grab = 0 }
      if (grab && $0 ~ /파일[[:space:]]*경로/) {
        line = $0
        idx = index(line, ":")
        if (idx == 0) idx = index(line, "：")
        if (idx > 0) line = substr(line, idx + 1)
        gsub(/`/, "", line)
        gsub(/^[[:space:]]+/, "", line)
        gsub(/[[:space:]]+$/, "", line)
        print line
        exit
      }
    }
  ' "$file" 2>/dev/null || true
}

# 계획 파일의 상대 경로 문자열을 WORK_DIR 기준 절대 경로로 변환
resolve_step_abs_path() {
  local rel="$1"
  if [[ -z "$rel" ]]; then
    echo ""
    return
  fi
  if [[ "$rel" = /* ]]; then
    echo "$rel"
  elif command -v realpath >/dev/null 2>&1; then
    realpath -m "${WORK_DIR}/${rel}"
  else
    echo "${WORK_DIR}/${rel}"
  fi
}

# 단계 텍스트를 짧은 제목으로 축약 (첫 " — " 앞, 최대 80자)
short_task() {
  local t="${1%% — *}"
  t="${t%% - *}"
  printf '%s' "${t:0:80}"
}

# 계획 파일에 체크박스가 하나도 없는 경우 정규화하고, 각 Step마다 "파일 경로:" 메타가
# 있는지도 확인해 누락되어 있으면 Claude에게 보완을 요청
ensure_plan_checkbox_format() {
  local active_plan_model="${1:-}"

  if [[ ! -f "$ABS_SPEC_PLAN_FILE" ]]; then
    return 0
  fi

  local total_boxes
  total_boxes=$(grep -cE '^[[:space:]]*[-*][[:space:]]+\[[[:space:]xX]\]' "$ABS_SPEC_PLAN_FILE" || true)

  local missing_path_steps=()
  local n fp
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    fp=$(get_step_filepath "$ABS_SPEC_PLAN_FILE" "$n")
    if [[ -z "$fp" ]]; then
      missing_path_steps+=("$n")
    fi
  done < <(get_all_step_numbers "$ABS_SPEC_PLAN_FILE")

  if [[ "$total_boxes" -ne 0 && ${#missing_path_steps[@]} -eq 0 ]]; then
    return 0
  fi

  echo -e "${YELLOW}[안내] '${SPEC_PLAN_FILE}'의 형식을 점검합니다 (체크박스: ${total_boxes}개, 파일경로 누락: ${#missing_path_steps[@]}개).${NC}"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${CYAN}[Dry-Run] 실제 실행 시 Claude에게 형식을 정규화하도록 요청합니다.${NC}"
    return 0
  fi

  local norm_log="${LOG_DIR}/normalize_plan_$(date +"%Y%m%d_%H%M%S").log"
  run_claude_with_limit_guard \
    "$active_plan_model" \
    "false" \
    "'${ABS_SPEC_PLAN_FILE}' 파일의 기존 내용을 유지하면서 다음을 정규화해서 '${ABS_SPEC_PLAN_FILE}'에 실제로 저장해줘:
1. 생성할 각 문서 항목이 마크다운 체크박스('- [ ] Step N: 문서 제목') 형식인지 확인하고, 아니면 변환해.
2. 각 'Step N' 체크박스 아래에 '### Step N' 상세 섹션이 있는지 확인하고, 없으면 추가해.
3. 각 '### Step N' 섹션에 '- 파일 경로: ${SPEC_DIR}/...' 형식의 줄이 반드시 있어야 해(저장할 문서의 프로젝트 루트 기준 상대 경로). 비어 있으면 적절한 파일명을 정해서 채워줘." \
    "$norm_log" \
    "계획 파일 형식 정규화"
}

# spec-plan.md에 적힌 모든 Step의 파일 경로를 바탕으로 폴더 구조를 미리 생성
create_spec_folder_structure() {
  if [[ ! -f "$ABS_SPEC_PLAN_FILE" ]]; then
    return 0
  fi

  echo -e "${BLUE}[폴더 구조] '${SPEC_DIR}' 아래 문서 저장 경로를 준비합니다...${NC}"

  local n fp abs_fp dir
  while IFS= read -r n; do
    [[ -z "$n" ]] && continue
    fp=$(get_step_filepath "$ABS_SPEC_PLAN_FILE" "$n")
    [[ -z "$fp" ]] && continue
    abs_fp=$(resolve_step_abs_path "$fp")
    [[ -z "$abs_fp" ]] && continue
    dir=$(dirname "$abs_fp")
    mkdir -p "$dir"
  done < <(get_all_step_numbers "$ABS_SPEC_PLAN_FILE")

  mkdir -p "$ABS_SPEC_DIR"
  if [[ -d "$ABS_SPEC_DIR" ]]; then
    echo -e "${CYAN}$(find "$ABS_SPEC_DIR" -maxdepth 3 -type d 2>/dev/null | sed "s#^${WORK_DIR}/##" | sort)${NC}"
  fi
}

# ==============================================================================
# spec-plan.md 파일 누락 시 자동 탐색 및 세션 기반 강제 복구 함수
# ==============================================================================
locate_or_recover_spec_plan_file() {
  local active_plan_model="${1:-}"

  if [[ -f "$ABS_SPEC_PLAN_FILE" && -s "$ABS_SPEC_PLAN_FILE" ]]; then
    return 0
  fi

  echo -e "${YELLOW}[점검] 지정된 경로('${ABS_SPEC_PLAN_FILE}')에서 계획 파일을 찾지 못해 프로젝트 내 다른 위치를 탐색합니다...${NC}"

  local found_plan=""
  local git_root=""
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi

  if [[ -n "$git_root" && -f "${git_root}/$(basename "$SPEC_PLAN_FILE")" && "${git_root}/$(basename "$SPEC_PLAN_FILE")" != "$ABS_SPEC_PLAN_FILE" ]]; then
    found_plan="${git_root}/$(basename "$SPEC_PLAN_FILE")"
  else
    found_plan=$(find "$WORK_DIR" -maxdepth 3 -name "$(basename "$SPEC_PLAN_FILE")" -mmin -30 2>/dev/null | head -n 1 || true)
  fi

  if [[ -n "$found_plan" && -f "$found_plan" && "$found_plan" != "$ABS_SPEC_PLAN_FILE" ]]; then
    echo -e "${GREEN}[자동 감지] '${found_plan}' 위치에 생성된 계획 파일을 발견하여 '${ABS_SPEC_PLAN_FILE}'로 복사합니다.${NC}"
    cp "$found_plan" "$ABS_SPEC_PLAN_FILE"
    return 0
  fi

  echo -e "${YELLOW}[자동 복구] 에이전트가 텍스트로만 계획을 응답하고 디스크에 '${ABS_SPEC_PLAN_FILE}'을 쓰지 않았습니다.${NC}"
  echo -e "${BLUE}[자동 복구] 직전 세션(--continue)을 이어받아 '${ABS_SPEC_PLAN_FILE}' 파일로 즉시 저장을 요청합니다...${NC}"

  local recover_log="${LOG_DIR}/recover_plan_$(date +"%Y%m%d_%H%M%S").log"
  local recover_prompt="방금 네가 정리하고 설명한 문서 생성 계획이 실제 디스크 경로 '${ABS_SPEC_PLAN_FILE}'에 파일로 생성되지 않았어(또는 다른 경로에 있거나 텍스트로만 출력됨).
지금 즉시 Write 도구를 실행해서, 방금 정리한 전체 계획(문서 목록 체크리스트 + 각 Step의 '파일 경로' 포함 상세 섹션)을 정확한 절대 경로 '${ABS_SPEC_PLAN_FILE}' 파일에 실제로 저장해줘. 아직 개별 문서 파일은 작성하지 말고 계획 파일만 저장해."

  run_claude_with_limit_guard \
    "$active_plan_model" \
    "true" \
    "$recover_prompt" \
    "$recover_log" \
    "spec-plan.md 디스크 파일 강제 생성 복구"

  if [[ -f "$ABS_SPEC_PLAN_FILE" && -s "$ABS_SPEC_PLAN_FILE" ]]; then
    echo -e "${GREEN}[복구 성공] '${ABS_SPEC_PLAN_FILE}' 파일이 정상적으로 생성되었습니다!${NC}"
    return 0
  fi

  return 1
}

# ==============================================================================
# Phase A: 요구사항 분석 → 필요한 문서 목록/폴더 구조 계획(spec-plan.md) 수립
# ==============================================================================
generate_spec_plan() {
  local req_text="$1"
  local active_plan_model="${PLAN_MODEL:-$MODEL}"

  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BOLD}${BLUE} [문서 계획 수립] 요구사항 분석 및 '${SPEC_PLAN_FILE}' 생성${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  if [[ -f "$ABS_SPEC_PLAN_FILE" && "$PLAN_MODE_ACTION" == "overwrite" && "$DRY_RUN" != "true" ]]; then
    local backup_file="${LOG_DIR}/$(basename "$SPEC_PLAN_FILE").bak.$(date +"%Y%m%d_%H%M%S")"
    cp "$ABS_SPEC_PLAN_FILE" "$backup_file"
    echo -e "${YELLOW}[백업] 기존 '${SPEC_PLAN_FILE}' 파일을 '${backup_file}'에 백업했습니다.${NC}"
  fi

  local mode_instruction=""
  if [[ -f "$ABS_SPEC_PLAN_FILE" && "$PLAN_MODE_ACTION" == "append" ]]; then
    mode_instruction="기존 '${ABS_SPEC_PLAN_FILE}' 파일의 내용(완료된 Step 포함)을 유지한 채, 기존 Step 번호와 겹치지 않는 번호부터 시작해 새로운 요구사항을 위한 문서 항목들을 파일 하단에 추가해줘."
  else
    mode_instruction="반드시 Write 도구를 사용하여 정확한 절대 경로 '${ABS_SPEC_PLAN_FILE}'에 파일을 새로 작성(저장)해줘."
  fi

  local conflict_policy
  conflict_policy=$(get_conflict_policy_instruction "'${ABS_SPEC_PLAN_FILE}'")

  local plan_prompt="너는 수석 프로덕트 매니저 겸 소프트웨어 아키텍트야. 다음은 개략적으로만 적힌 사용자 요구사항이야. 먼저 현재 프로젝트 디렉터리('${WORK_DIR}')의 코드베이스를 탐색·분석해 기술 스택, 아키텍처, 기존 컨벤션, 관련 기존 기능을 파악한 뒤, 이 요구사항을 개발에 바로 착수할 수 있는 수준으로 구체화하기 위해 어떤 '문서들'이 필요한지 결정하고, 그 계획을 '${ABS_SPEC_PLAN_FILE}'에 작성해줘. (실제 문서 내용은 아직 쓰지 마. 이번 단계는 계획 수립만 해.)

[사용자 요구사항 (개략적/원문)]
${req_text}

[계획 수립 지침]
1. 현재 프로젝트의 기술 스택, 디렉터리 구조, 기존 코드 컨벤션, 관련된 기존 기능/모듈을 먼저 파악해.
2. 요구사항의 규모와 성격에 맞게 필요한 문서 목록을 정해. 작은 기능이면 2~4개, 복잡한 기능/시스템이면 더 많아질 수 있어. 전형적으로 고려할 문서 종류(상황에 맞지 않으면 생략 가능):
   - 개요/배경 및 목표·범위 문서
   - 기능 요구사항 명세 (FR-N 형태)
   - 데이터 모델 및 API(또는 UI 컴포넌트/상태) 설계 문서
   - 비기능 요구사항(성능/보안/로깅/모니터링) 문서
   - 예외 처리·엣지 케이스 및 수용 기준 문서
   - 테스트 계획 문서
   - 마이그레이션/롤아웃 계획 문서 (기존 시스템에 영향이 있을 때만)
3. 각 문서를 '${ABS_SPEC_DIR}' 디렉터리 아래 어떤 상대 경로에 저장할지 정해(문서가 많으면 하위 폴더로 묶어도 됨. 예: '${SPEC_DIR}/01-overview.md', '${SPEC_DIR}/api/02-endpoints.md' 등). 실제로 폴더를 만들 필요는 없어(스크립트가 처리함).
4. 애플리케이션 소스 코드는 수정하지 말고, 오직 계획 수립과 '${ABS_SPEC_PLAN_FILE}'(및 필요 시 의사결정 기록용 '${ABS_DECISIONS_FILE}') 파일 생성만 수행해.
5. ${mode_instruction} (주의: 채팅 응답으로만 계획을 출력하고 실제 디스크 파일 '${ABS_SPEC_PLAN_FILE}'을 쓰지 않으면 스크립트가 실패하므로 반드시 Write 도구를 호출해 파일로 저장해야 해!)
6. '${ABS_SPEC_PLAN_FILE}' 파일은 다음 구조를 포함해야 해:
   - 머리말: 요구사항 요약과 전체 문서 구조를 이렇게 나눈 이유
   - 문서 목록 체크리스트: 각 문서마다 '- [ ] Step N: 문서 제목' 한 줄(80자 이내, 상세 설명이나 ' — ' 이후 설명 금지)
   - 각 Step마다 별도 '### Step N' 섹션(체크박스 아래, 체크박스 자체는 없음)에 아래 항목을 모두 포함:
     - 파일 경로: (프로젝트 루트 기준 상대 경로, 반드시 '${SPEC_DIR}/'로 시작)
     - 목적: (이 문서가 왜 필요한지)
     - 포함할 내용(개요): (이 문서에 들어갈 구체적인 섹션/항목 목록)
     - 의존 문서: (먼저 읽어야 할 다른 Step 번호, 없으면 '없음')
     - 문서별 검증 기준: (이 문서가 '완성됐다'고 판단할 기준 — 구체적이고 확인 가능하게)
7. 각 Step은 한 번의 에이전트 세션에서 작성·자기검증까지 끝낼 수 있는 적절한 크기로 나눠.

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
  local plan_log="${LOG_DIR}/phaseA_planning_${timestamp}.log"

  echo -e "${CYAN}▶ 코드베이스를 분석하고 문서 생성 계획을 세우고 있습니다...${NC}"
  run_claude_with_limit_guard \
    "$active_plan_model" \
    "false" \
    "$plan_prompt" \
    "$plan_log" \
    "문서 계획 수립 (${SPEC_PLAN_FILE} 생성)"

  if ! locate_or_recover_spec_plan_file "$active_plan_model"; then
    echo -e "${RED}[오류] 자동 복구 시도 후에도 '${ABS_SPEC_PLAN_FILE}' 파일이 생성되지 않았습니다. 로그를 확인해 주세요: ${plan_log}${NC}" >&2
    exit 1
  fi

  ensure_plan_checkbox_format "$active_plan_model"
  create_spec_folder_structure

  local total_created
  total_created=$(count_remaining_tasks "$ABS_SPEC_PLAN_FILE")
  echo -e "\n${GREEN}[계획 수립 완료] '${SPEC_PLAN_FILE}'에 총 ${total_created}개의 생성할 문서가 계획되었습니다.${NC}"

  if [[ "$AUTO_COMMIT" == "true" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain "$ABS_SPEC_PLAN_FILE" "$ABS_DECISIONS_FILE" 2>/dev/null)" ]]; then
      git add "$ABS_SPEC_PLAN_FILE"
      [[ -f "$ABS_DECISIONS_FILE" ]] && git add "$ABS_DECISIONS_FILE"
      git commit -m "docs(spec): generate document plan in ${SPEC_PLAN_FILE}" || true
      echo -e "${BLUE}[Git] 생성된 '${SPEC_PLAN_FILE}' 파일이 커밋되었습니다.${NC}"
    fi
  fi
}

# ==============================================================================
# Phase B: spec-plan.md의 미완료 문서를 하나씩 생성 + 자기검증 + 체크박스 갱신
# $1: NEXT_TASK 텍스트 ("Step N: 문서 제목"). 성공 시 0, 재시도 소진 시 1 반환.
# 성공/실패와 무관하게 LAST_STEP_LOG_FILE, LAST_STEP_DOC_PATH 전역 변수를 채운다.
# ==============================================================================
run_document_step() {
  local next_task="$1"
  local step_num
  step_num=$(get_step_number "$next_task")

  if [[ -z "$step_num" ]]; then
    echo -e "${RED}[오류] '${next_task}' 항목에서 Step 번호를 인식할 수 없습니다. '${SPEC_PLAN_FILE}' 형식을 확인해 주세요.${NC}" >&2
    return 1
  fi

  local doc_rel
  doc_rel=$(get_step_filepath "$ABS_SPEC_PLAN_FILE" "$step_num")
  if [[ -z "$doc_rel" ]]; then
    doc_rel="${SPEC_DIR}/doc-step-${step_num}.md"
    echo -e "${YELLOW}[경고] Step ${step_num}에 '파일 경로' 메타가 없어 '${doc_rel}'로 대체합니다.${NC}"
  fi
  local doc_abs
  doc_abs=$(resolve_step_abs_path "$doc_rel")
  mkdir -p "$(dirname "$doc_abs")"

  LAST_STEP_DOC_PATH="$doc_abs"

  local next_short
  next_short="$(short_task "$next_task")"

  local conflict_policy
  conflict_policy=$(get_conflict_policy_instruction "'${doc_abs}'")

  local prompt="'${ABS_SPEC_PLAN_FILE}'에서 'Step ${step_num}' 체크리스트 항목과 그 아래 '### Step ${step_num}' 상세 섹션만 읽어(grep으로 위치를 찾아서 필요한 부분만 읽을 것; 파일 전체를 읽지 말 것). 상세 섹션의 '의존 문서'에 다른 Step 번호가 적혀 있으면, 그 Step의 '파일 경로'에 적힌 문서를 먼저 읽고 용어·형식·ID를 일관되게 맞춰.

정확히 이번 문서(Step ${step_num})만 작업해:
1. 상세 섹션의 '목적'과 '포함할 내용'에 따라 문서를 작성해 정확한 절대 경로 '${doc_abs}'에 저장해(Write 도구). 모호한 표현(예: '적절히', '필요하면') 대신 구체적인 기준·수치·예시를 써.
2. 작성 후 반드시 스스로 검증(문서별 검증)해: 상세 섹션의 '문서별 검증 기준'을 모두 충족하는지, 의존 문서와 내용이 모순되지 않는지 다시 확인하고, 미흡한 부분이 있으면 즉시 고쳐서 같은 파일에 다시 저장해.
3. 검증까지 끝났으면 '${ABS_SPEC_PLAN_FILE}'을 Edit 도구로 열어 'Step ${step_num}' 체크박스만 '- [ ]'에서 '- [x]'로 바꿔. 다른 Step의 체크박스나 내용은 건드리지 마.
4. 다음 미완료 Step까지 미리 진행하지 말고, 오직 이번 Step(${next_short})에만 집중해.

${conflict_policy}"

  local attempt=0
  local success="false"
  local log_file=""

  while [[ "$attempt" -le "$MAX_RETRIES" ]]; do
    attempt=$((attempt + 1))
    local timestamp
    timestamp=$(date +"%Y%m%d_%H%M%S")
    log_file="${LOG_DIR}/step_${step_num}_attempt_${attempt}_${timestamp}.log"

    if [[ "$attempt" -gt 1 ]]; then
      echo -e "${YELLOW}[재시도 ${attempt}/$((MAX_RETRIES + 1))] 이전 시도에서 문서가 저장되지 않았거나 체크박스가 갱신되지 않았습니다.${NC}"
    fi

    run_claude_with_limit_guard \
      "$MODEL" \
      "false" \
      "$prompt" \
      "$log_file" \
      "Step ${step_num}: ${next_task}"

    local exit_code="$LAST_CLAUDE_EXIT_CODE"

    local still_unchecked="false"
    if [[ "$(get_next_task "$ABS_SPEC_PLAN_FILE")" == "$next_task" ]]; then
      still_unchecked="true"
    fi

    local doc_written="false"
    if [[ -f "$doc_abs" && -s "$doc_abs" ]]; then
      doc_written="true"
    fi

    if [[ "$exit_code" -eq 0 && "$doc_written" == "true" && "$still_unchecked" == "false" ]]; then
      success="true"
      break
    fi

    prompt="이전 시도에서 '${next_short}' 문서(Step ${step_num})가 완전히 마무리되지 않았어. 다음을 확인해:
- 문서 파일이 '${doc_abs}'에 실제로 저장되어 있는지 (현재 상태: $([[ "$doc_written" == "true" ]] && echo "존재함" || echo "존재하지 않음"))
- '${ABS_SPEC_PLAN_FILE}'에서 'Step ${step_num}' 체크박스가 '- [x]'로 바뀌었는지 (현재 상태: $([[ "$still_unchecked" == "true" ]] && echo "아직 미완료" || echo "완료됨"))
누락된 부분을 끝까지 완료하고, Write/Edit 도구로 반드시 디스크에 반영해줘.

${conflict_policy}"
  done

  LAST_STEP_LOG_FILE="$log_file"

  if [[ "$success" == "true" ]]; then
    echo -e "${GREEN}[문서 완료] Step ${step_num}: '${next_short}' → '${doc_rel}'${NC}"
    return 0
  fi

  echo -e "${RED}[중단] Step ${step_num}('${next_short}')을 $((MAX_RETRIES + 1))회 시도했으나 완료되지 않았습니다.${NC}" >&2
  echo -e "${RED}마지막 로그 파일을 확인해 주세요: ${log_file}${NC}" >&2
  return 1
}

# ==============================================================================
# Stage C: 문서간 충돌 검증 — 완성된 모든 문서를 함께 읽혀 모순/불일치를 찾아 수정
# ==============================================================================
cross_document_conflict_check() {
  local active_model="$MODEL"

  local doc_list
  doc_list=$(find "$ABS_SPEC_DIR" -type f -name "*.md" 2>/dev/null | sort)
  if [[ -z "$doc_list" ]]; then
    echo -e "${YELLOW}[안내] '${SPEC_DIR}' 아래 생성된 문서가 없어 문서간 충돌 검증을 건너뜁니다.${NC}"
    return 0
  fi

  echo -e "\n${BLUE}======================================================================${NC}"
  echo -e "${BOLD}${BLUE} [문서간 충돌 검증] 완성된 문서 세트의 모순/불일치를 검토합니다${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  local doc_list_rel
  doc_list_rel=$(echo "$doc_list" | sed "s#^${WORK_DIR}/##")

  local conflict_policy
  conflict_policy=$(get_conflict_policy_instruction "'${ABS_SPEC_DIR}' 내 관련 문서들")

  local prompt="너는 시니어 아키텍트 리뷰어야. '${ABS_SPEC_PLAN_FILE}'의 머리말(요구사항 요약)을 먼저 읽고, 아래 목록의 모든 문서를 전부 읽어 서로 충돌하거나 모순되는 부분이 있는지 검토해:

${doc_list_rel}

[검토 관점]
1. 두 개 이상의 문서가 같은 항목(동일 기능/필드/정책)에 대해 서로 다른 내용을 기술하고 있는가?
2. 문서 간에 용어나 식별자(예: FR 번호, 필드명, 엔드포인트 경로)가 일치하지 않는가?
3. 한 문서가 다른 문서를 참조하는데 그 내용이 실제로 존재하지 않거나 바뀌었는가(끊어진 참조)?
4. 어떤 문서가 다른 문서와 전제(가정)가 서로 다른가?

[처리 방법]
- 사소하거나 명백한 불일치는 코드베이스/요구사항과 더 부합하는 쪽을 기준으로 즉시 Edit 도구로 관련 문서들을 직접 고쳐.
- 비즈니스적으로 어느 쪽이 맞는지 사람이 결정해야 하는 충돌만 아래 의사결정 지침을 따라.
- 마지막에 발견한 충돌과 수정 내역을 간단히 요약해서 출력해(어떤 문서를 왜 고쳤는지).

${conflict_policy}"

  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local log_file="${LOG_DIR}/cross_check_${timestamp}.log"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  run_claude_with_limit_guard \
    "$active_model" \
    "false" \
    "$prompt" \
    "$log_file" \
    "문서간 충돌 검증"

  echo -e "${GREEN}[완료] 문서간 충돌 검증이 끝났습니다.${NC}"
}

# ==============================================================================
# Stage D: 최종 중복/충돌 검사 및 최적화 — 문서 세트 전체를 마지막으로 정리
# ==============================================================================
final_optimize_documents() {
  local active_model="$MODEL"

  local doc_list
  doc_list=$(find "$ABS_SPEC_DIR" -type f -name "*.md" 2>/dev/null | sort)
  if [[ -z "$doc_list" ]]; then
    echo -e "${YELLOW}[안내] '${SPEC_DIR}' 아래 생성된 문서가 없어 최종 최적화를 건너뜁니다.${NC}"
    return 0
  fi

  echo -e "\n${BLUE}======================================================================${NC}"
  echo -e "${BOLD}${BLUE} [최종 최적화] 문서 세트의 중복/잔여 충돌을 정리하고 인덱스를 만듭니다${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  local doc_list_rel
  doc_list_rel=$(echo "$doc_list" | sed "s#^${WORK_DIR}/##")

  local conflict_policy
  conflict_policy=$(get_conflict_policy_instruction "'${ABS_SPEC_DIR}' 내 관련 문서들")

  local index_file="${ABS_SPEC_DIR}/README.md"
  local prompt="너는 이 문서 세트의 마지막 편집자야. '${ABS_SPEC_PLAN_FILE}'의 머리말을 참고하고, 아래 모든 문서를 다시 한번 전체적으로 검토해:

${doc_list_rel}

[마지막 정리 작업]
1. 같은 내용이 둘 이상의 문서에 거의 그대로 반복되어 있으면, 가장 적절한 '단일 출처' 문서에만 남기고 다른 문서에서는 간단한 참조(문서명/섹션 언급)로 축약해.
2. Stage C 이후에도 남아있는 사양 충돌이나 중복이 있으면 해소해(비즈니스 결정이 필요한 경우만 아래 지침의 [DECISION_REQUIRED] 사용).
3. 문서 전체의 용어·번호 체계(FR-N 등)가 일관되는지 마지막으로 확인하고 다듬어.
4. '${index_file}' 파일을 새로 작성(또는 있으면 갱신)해서 전체 문서 목록, 각 문서 한 줄 요약, 추천 열람 순서를 안내해.
5. 이번 단계에서 수정한 문서와 그 이유를 요약해서 출력해.

${conflict_policy}"

  local timestamp
  timestamp=$(date +"%Y%m%d_%H%M%S")
  local log_file="${LOG_DIR}/final_optimize_${timestamp}.log"

  if [[ "$DRY_RUN" == "true" ]]; then
    return 0
  fi

  run_claude_with_limit_guard \
    "$active_model" \
    "false" \
    "$prompt" \
    "$log_file" \
    "최종 중복/충돌 검사 및 최적화"

  echo -e "${GREEN}[완료] 최종 최적화가 끝났습니다.${NC}"

  if [[ "$AUTO_COMMIT" == "true" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if [[ -n "$(git status --porcelain "$ABS_SPEC_DIR" "$ABS_DECISIONS_FILE" 2>/dev/null)" ]]; then
      git add "$ABS_SPEC_DIR"
      [[ -f "$ABS_DECISIONS_FILE" ]] && git add "$ABS_DECISIONS_FILE"
      git commit -m "docs(spec): cross-check and optimize generated document set" || true
      echo -e "${BLUE}[Git] 최종 문서 세트가 커밋되었습니다.${NC}"
    fi
  fi
}

# ==============================================================================
# 메인 흐름
# ==============================================================================

if [[ "$RECOVER_LAST_PLAN" == "true" ]]; then
  echo -e "${BLUE}[세션 복구 모드] 직전 Claude 세션(--continue)에서 수립된 계획을 '${ABS_SPEC_PLAN_FILE}'로 복구합니다...${NC}"
  if ! locate_or_recover_spec_plan_file "${PLAN_MODEL:-$MODEL}"; then
    echo -e "${RED}[오류] 직전 세션에서 '${ABS_SPEC_PLAN_FILE}'을 복구하지 못했습니다.${NC}" >&2
    exit 1
  fi
elif [[ -n "$REQUIREMENTS" ]]; then
  generate_spec_plan "$REQUIREMENTS"

  if [[ "$PLAN_ONLY" == "true" ]]; then
    echo -e "\n${GREEN}[종료] --plan-only 옵션이 지정되어 계획 수립 후 종료합니다. 생성된 '${SPEC_PLAN_FILE}'을 확인해 보세요.${NC}"
    exit 0
  fi

  if [[ "$CONFIRM_PLAN" == "true" && "$DRY_RUN" != "true" && -t 0 ]]; then
    echo -e "\n${CYAN}==================== 생성된 ${SPEC_PLAN_FILE} 내용 ====================${NC}"
    cat "$ABS_SPEC_PLAN_FILE"
    echo -e "${CYAN}======================================================================${NC}"
    read -r -p "위 계획대로 문서 생성을 시작할까요? [Y/n] " answer
    case "${answer:-Y}" in
      [Yy]*|"")
        echo -e "${GREEN}문서 생성을 시작합니다.${NC}"
        ;;
      *)
        echo -e "${YELLOW}사용자 요청으로 실행을 중단했습니다. '${SPEC_PLAN_FILE}'을 수정한 뒤 다시 실행할 수 있습니다.${NC}"
        exit 0
        ;;
    esac
  fi
elif [[ ! -f "$ABS_SPEC_PLAN_FILE" ]]; then
  if [[ -t 0 ]]; then
    echo -e "${YELLOW}[안내] '${SPEC_PLAN_FILE}' 파일이 없으며 전달된 요구사항도 없습니다.${NC}"
    echo -e "${CYAN}구현할 개략적인 요구사항을 입력해 주세요 (입력 후 Enter, 취소는 Ctrl+C):${NC}"
    read -r -p "> " REQUIREMENTS
    if [[ -z "$REQUIREMENTS" ]]; then
      echo -e "${RED}[오류] 요구사항이 입력되지 않아 종료합니다.${NC}" >&2
      exit 1
    fi
    generate_spec_plan "$REQUIREMENTS"
  else
    echo -e "${RED}[오류] '${SPEC_PLAN_FILE}' 파일이 존재하지 않으며 요구사항(-q/--req, -i/--req-file, 위치 인자, stdin)도 전달되지 않았습니다.${NC}" >&2
    usage
    exit 1
  fi
fi

if [[ "$DRY_RUN" == "true" && ! -f "$ABS_SPEC_PLAN_FILE" ]]; then
  echo -e "${YELLOW}[Dry-Run] 현재 '${SPEC_PLAN_FILE}' 파일이 없으므로 계획 수립 후 생성될 예정입니다.${NC}"
  exit 0
fi

if [[ "$DRY_RUN" == "true" ]]; then
  exit 0
fi

# 기존 spec-plan.md로 재개하는 경우(요구사항 없이 재실행)에도 형식/폴더가 준비되어 있는지 확인
ensure_plan_checkbox_format "${PLAN_MODEL:-$MODEL}"
create_spec_folder_structure

INITIAL_REMAINING=$(count_remaining_tasks "$ABS_SPEC_PLAN_FILE")
INITIAL_COMPLETED=$(count_completed_tasks "$ABS_SPEC_PLAN_FILE")
TOTAL_DOCS=$((INITIAL_REMAINING + INITIAL_COMPLETED))

echo -e "\n${BLUE}======================================================================${NC}"
echo -e "${BOLD}${BLUE} [문서 생성] '${SPEC_PLAN_FILE}' 기반 문서별 생성/검증 시작${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e " - 계획 파일   : ${CYAN}${ABS_SPEC_PLAN_FILE}${NC}"
echo -e " - 저장 폴더   : ${CYAN}${ABS_SPEC_DIR}${NC}"
echo -e " - 진행 현황   : 전체 ${BOLD}${TOTAL_DOCS}${NC}개 중 완료 ${GREEN}${INITIAL_COMPLETED}${NC}개 / 미완료 ${YELLOW}${INITIAL_REMAINING}${NC}개"
echo -e " - 충돌 처리   : ${CYAN}${ON_CONFLICT}${NC} (결정 기록: ${ABS_DECISIONS_FILE})"
echo -e " - 최대 문서수 : ${CYAN}${MAX_STEPS}${NC} (문서당 최대 ${MAX_TURNS}턴, 재시도 ${MAX_RETRIES}회)"
echo -e "${BLUE}======================================================================${NC}"

if [[ "$INITIAL_REMAINING" -eq 0 ]]; then
  echo -e "${GREEN}[완료] '${SPEC_PLAN_FILE}'의 모든 문서가 이미 완료(- [x])되었습니다!${NC}"
else
  STEP_COUNT=0
  while [[ "$STEP_COUNT" -lt "$MAX_STEPS" ]]; do
    REMAINING_BEFORE=$(count_remaining_tasks "$ABS_SPEC_PLAN_FILE")
    if [[ "$REMAINING_BEFORE" -eq 0 ]]; then
      echo -e "\n${GREEN}[성공] '${SPEC_PLAN_FILE}'의 모든 문서가 생성되었습니다!${NC}"
      break
    fi

    STEP_COUNT=$((STEP_COUNT + 1))
    NEXT_TASK=$(get_next_task "$ABS_SPEC_PLAN_FILE")
    COMPLETED_NOW=$(count_completed_tasks "$ABS_SPEC_PLAN_FILE")
    TOTAL_NOW=$((COMPLETED_NOW + REMAINING_BEFORE))

    echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
    echo -e "${CYAN}[문서 ${STEP_COUNT}/${MAX_STEPS}] 전체 진행도: ${COMPLETED_NOW}/${TOTAL_NOW} 완료 (남은 문서: ${REMAINING_BEFORE}개)${NC}"
    echo -e "${YELLOW}▶ 현재 작성 문서:${NC} ${NEXT_TASK}"
    echo -e "${CYAN}----------------------------------------------------------------------${NC}"

    if ! run_document_step "$NEXT_TASK"; then
      send_ubuntu_notification "Claude Spec Generator 오류 중단" "'${NEXT_TASK}' 문서 생성에서 오류가 발생해 중단되었습니다." "critical"
      exit 1
    fi

    if [[ "$AUTO_COMMIT" == "true" ]] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [[ -n "$(git status --porcelain "$LAST_STEP_DOC_PATH" "$ABS_SPEC_PLAN_FILE" 2>/dev/null)" ]]; then
        git add "$LAST_STEP_DOC_PATH" "$ABS_SPEC_PLAN_FILE"
        git commit -m "docs(spec): generate $(short_task "$NEXT_TASK")" || true
        echo -e "${BLUE}[Git] 문서 생성 체크포인트 커밋이 생성되었습니다.${NC}"
      fi
    fi
  done
fi

FINAL_REMAINING=$(count_remaining_tasks "$ABS_SPEC_PLAN_FILE")
if [[ "$FINAL_REMAINING" -gt 0 ]]; then
  echo -e "\n${YELLOW}[종료] 최대 문서 수(${MAX_STEPS})에 도달하여 중단되었습니다. (남은 문서: ${FINAL_REMAINING}개)${NC}"
  echo -e "${YELLOW}같은 명령으로 다시 실행하면 남은 문서부터 이어서 생성합니다. (문서간 충돌 검증/최종 최적화는 모든 문서가 완료된 뒤 실행됩니다.)${NC}"
  send_ubuntu_notification "Claude Spec Generator 최대 문서수 도달" "최대 문서 수(${MAX_STEPS})에 도달하여 중단되었습니다." "normal"
  exit 2
fi

# 모든 문서가 완료된 경우에만 Stage C/D 진행
if [[ "$SKIP_CROSS_CHECK" != "true" ]]; then
  cross_document_conflict_check
else
  echo -e "${YELLOW}[건너뜀] --no-cross-check 옵션으로 문서간 충돌 검증을 생략합니다.${NC}"
fi

if [[ "$SKIP_OPTIMIZE" != "true" ]]; then
  final_optimize_documents
else
  echo -e "${YELLOW}[건너뜀] --no-optimize 옵션으로 최종 최적화를 생략합니다.${NC}"
fi

echo -e "\n${GREEN}======================================================================${NC}"
echo -e "${BOLD}${GREEN} [완료] 요구사항 사양서 문서 세트가 생성되었습니다!${NC}"
echo -e "${GREEN}======================================================================${NC}"
echo -e " - 계획 파일   : ${CYAN}${ABS_SPEC_PLAN_FILE}${NC}"
echo -e " - 문서 폴더   : ${CYAN}${ABS_SPEC_DIR}${NC}"
echo -e " - 결정 기록   : ${CYAN}${ABS_DECISIONS_FILE}${NC} (없으면 모호성 없이 완료됨)"
echo -e "${CYAN}$(find "$ABS_SPEC_DIR" -type f -name "*.md" 2>/dev/null | sed "s#^${WORK_DIR}/##" | sort)${NC}"
echo -e " - 다음 단계   : ${CYAN}run_plan.bash --req-file <위 문서 중 하나>${NC} 로 구현을 시작할 수 있습니다."
echo -e "${GREEN}======================================================================${NC}"

send_ubuntu_notification "Claude Spec Generator 완료" "'${SPEC_DIR}' 문서 세트 생성이 완료되었습니다." "normal"

exit 0
