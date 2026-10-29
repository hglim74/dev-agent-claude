#!/usr/bin/env bash
# ==============================================================================
# loop_task.bash - task/open 폴더를 지속적으로 모니터링하여 요구사항 md 문서가
#                   발견되면 run_plan.bash에 전달해 자동으로 구현을 진행시키는
#                   데몬 스크립트 (Ubuntu/GNU-tool 지향).
#
# 설명:
#   1. [모니터링] 'task/open/' 폴더를 계속 감시한다(inotifywait가 있으면 즉시 감지,
#      없으면 폴링). 새 요구사항 문서(*.md)가 보이면 처리를 시작한다.
#   2. [진행 중 표시] 처리할 문서를 'task/in-progress/'로 옮긴 뒤, 그 문서를
#      'run_plan.bash --req-file <문서>'로 전달해 계획 수립부터 단계별 구현까지
#      맡긴다.
#   3. [완료 처리] run_plan.bash가 종료 코드 0(모든 단계 완료)으로 끝나면 문서를
#      'task/close/'로 옮긴다. 그 외 종료 코드(오류/최대 단계 도달/한도 대기 중단/
#      의사결정 대기 등)면 문서를 'task/in-progress/'에 그대로 두고, 잠시 대기 후
#      다시 시도한다.
#   4. [재개] 데몬을 실행(또는 재시작)할 때 'task/in-progress/'에 문서가 이미
#      있으면 완료되지 못한 이전 작업으로 간주하고, 그 문서를 다시 옮기지 않은 채
#      'run_plan.bash'를 (요구사항 없이) 호출해 기존 plan.md를 이어서 진행한다.
#   5. [비동기 실행] run_plan.bash/generate_spec.bash와 동일한 '--tmux' 옵션으로
#      데몬 자체를 detached tmux 세션에서 백그라운드로 띄울 수 있고, '--stop'/
#      '--status'로 PID 파일 기준 제어가 가능하다.
#
# 참고: run_plan.bash는 한 작업 디렉터리에서 동시에 하나의 인스턴스만 실행되도록
#       자체 flock을 걸어두므로, 이 데몬은 항상 "한 번에 하나의 작업"만 진행한다
#       (in-progress에 문서가 있으면 open은 쳐다보지 않는다).
# ==============================================================================

set -euo pipefail

# SSH 세션이 끊어져도(SIGHUP) 데몬이 죽지 않도록 보호
trap '' HUP

# 기본 설정값 (환경변수로도 오버라이드 가능)
TASK_DIR="${TASK_DIR:-task}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"          # task/open 확인 주기(초, inotifywait 없을 때 폴링 간격)
FAIL_RETRY_DELAY="${FAIL_RETRY_DELAY:-60}"    # run_plan.bash 실패 시 재시도 전 대기 시간(초)
RUN_PLAN_BIN="${RUN_PLAN_BIN:-}"              # run_plan.bash 실행 파일 경로 (비우면 자동 탐색)
LOG_DIR="${LOG_DIR:-.claude-loop-task-logs}"
ONCE="false"
DRY_RUN="false"
CHECK_ENV_ONLY="false"
DO_STOP="false"
DO_STATUS="false"

# Ubuntu 전용 설정
USE_TMUX="${USE_TMUX:-false}"
TMUX_SESSION_NAME="${TMUX_SESSION_NAME:-claude-loop-task}"
ENABLE_NOTIFY="${ENABLE_NOTIFY:-true}"

RUN_PLAN_EXTRA_ARGS=()   # '--' 뒤의 인자들: run_plan.bash 호출 시 그대로 전달

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
  $(basename "$0") [옵션] [-- run_plan.bash에 그대로 전달할 옵션...]

데몬 동작 옵션:
      --task-dir <경로>        작업 큐 폴더 (기본값: ${TASK_DIR}; 하위에 open/in-progress/close 자동 생성)
      --poll-interval <초>     task/open 확인 주기 (기본값: ${POLL_INTERVAL}초; inotifywait 설치 시 더 빠르게 감지)
      --fail-retry-delay <초>  run_plan.bash가 실패/중단으로 끝났을 때 재시도 전 대기 시간 (기본값: ${FAIL_RETRY_DELAY}초)
      --run-plan-bin <경로>    run_plan.bash 실행 파일 경로 (기본값: PATH에서 탐색, 없으면 이 스크립트와 같은 폴더)
      --once                   대기 중인 작업을 최대 1개(재개 포함)만 처리하고 종료 (테스트/cron용)

데몬 제어 옵션:
      --tmux [세션명]          tmux 백그라운드 세션에서 데몬을 시작 (기본 세션명: ${TMUX_SESSION_NAME})
      --stop                   PID 파일을 기준으로 실행 중인 데몬에 종료 신호를 보냄
      --status                 PID 파일을 기준으로 데몬 실행 여부 확인
      --check-env               필수/보조 도구 설치 상태 진단 후 종료

기타 옵션:
      --dry-run                 실제로 옮기거나 run_plan.bash를 호출하지 않고 수행할 동작만 출력
  -h, --help                    도움말 출력

run_plan.bash로 전달할 옵션 (예: --auto-commit --on-conflict auto 등 모든 run_plan.bash 옵션 가능):
  '--' 뒤에 적은 인자는 매 작업마다 run_plan.bash 호출에 그대로 추가됩니다.
  (SLACK_BOT_TOKEN 등 환경변수는 run_plan.bash 자식 프로세스에 자동으로 전달되므로 별도 설정이 필요 없습니다.)

디렉터리 구조 (기준 경로는 이 스크립트를 실행한 현재 폴더):
  ${TASK_DIR}/open/         요구사항 md 문서를 넣어두는 곳 (사용자가 채움)
  ${TASK_DIR}/in-progress/  현재 run_plan.bash가 작업 중인 문서 (최대 1개)
  ${TASK_DIR}/close/        run_plan.bash가 모든 단계를 완료한 문서

실행 예시:
  # 포그라운드에서 데몬 실행 (Ctrl+C로 종료)
  ./$(basename "$0")

  # tmux 백그라운드 세션에서 데몬 시작, 작업마다 자동 커밋 + 충돌 시 자율 결정
  ./$(basename "$0") --tmux -- --auto-commit --on-conflict auto

  # 백그라운드 데몬 상태 확인 / 종료
  ./$(basename "$0") --status
  ./$(basename "$0") --stop

  # 현재 대기/미완료 작업을 하나만 처리하고 종료 (디버깅, cron)
  ./$(basename "$0") --once

  # 실제 실행 없이 지금 상태에서 어떤 동작이 일어날지만 확인
  ./$(basename "$0") --dry-run
EOF
}

# Ubuntu 데스크톱 알림 전송 함수
send_ubuntu_notification() {
  local title="$1"
  local message="$2"
  local urgency="${3:-normal}"

  if [[ "$ENABLE_NOTIFY" == "true" ]] && command -v notify-send >/dev/null 2>&1; then
    if [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]]; then
      notify-send -u "$urgency" -a "Claude Loop Task" "$title" "$message" >/dev/null 2>&1 || true
    fi
  fi
}

# CLI 인자 파싱 ('--' 이후는 run_plan.bash로 그대로 전달)
while [[ $# -gt 0 ]]; do
  case "$1" in
    --task-dir)
      TASK_DIR="$2"
      shift 2
      ;;
    --poll-interval)
      POLL_INTERVAL="$2"
      shift 2
      ;;
    --fail-retry-delay)
      FAIL_RETRY_DELAY="$2"
      shift 2
      ;;
    --run-plan-bin)
      RUN_PLAN_BIN="$2"
      shift 2
      ;;
    --once)
      ONCE="true"
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
    --stop)
      DO_STOP="true"
      shift
      ;;
    --status)
      DO_STATUS="true"
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
    --)
      shift
      RUN_PLAN_EXTRA_ARGS=("$@")
      break
      ;;
    -*)
      echo -e "${RED}[오류] 알 수 없는 옵션입니다: $1${NC}" >&2
      usage
      exit 1
      ;;
    *)
      echo -e "${RED}[오류] 이 스크립트는 위치 인자를 받지 않습니다: $1 (run_plan.bash로 전달할 옵션은 '--' 뒤에 적어주세요)${NC}" >&2
      usage
      exit 1
      ;;
  esac
done

if ! [[ "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || [[ "$POLL_INTERVAL" -le 0 ]]; then
  echo -e "${RED}[오류] --poll-interval 값은 1 이상의 정수여야 합니다 (입력값: ${POLL_INTERVAL}).${NC}" >&2
  exit 1
fi
if ! [[ "$FAIL_RETRY_DELAY" =~ ^[0-9]+$ ]]; then
  echo -e "${RED}[오류] --fail-retry-delay 값은 0 이상의 정수여야 합니다 (입력값: ${FAIL_RETRY_DELAY}).${NC}" >&2
  exit 1
fi

# 기준 경로(Base Path): 다른 두 스크립트와 동일하게, 호출한 현재 디렉터리를 기준으로 한다.
WORK_DIR="$(pwd)"
if command -v realpath >/dev/null 2>&1; then
  ABS_TASK_DIR="$(realpath -m "$TASK_DIR")"
  ABS_LOG_DIR="$(realpath -m "$LOG_DIR")"
else
  [[ "$TASK_DIR" = /* ]] && ABS_TASK_DIR="$TASK_DIR" || ABS_TASK_DIR="${WORK_DIR}/${TASK_DIR}"
  [[ "$LOG_DIR" = /* ]] && ABS_LOG_DIR="$LOG_DIR" || ABS_LOG_DIR="${WORK_DIR}/${LOG_DIR}"
fi
OPEN_DIR="${ABS_TASK_DIR}/open"
IN_PROGRESS_DIR="${ABS_TASK_DIR}/in-progress"
CLOSE_DIR="${ABS_TASK_DIR}/close"
PID_FILE="${ABS_LOG_DIR}/loop_task.pid"
LOCK_FILE="${ABS_LOG_DIR}/loop_task.lock"

mkdir -p "$OPEN_DIR" "$IN_PROGRESS_DIR" "$CLOSE_DIR" "$ABS_LOG_DIR"

# --stop: PID 파일 기준으로 실행 중인 데몬에 SIGTERM을 보내고 종료될 때까지 대기
if [[ "$DO_STOP" == "true" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    pid="$(cat "$PID_FILE" 2>/dev/null || true)"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo -e "${YELLOW}[종료 요청] 데몬(PID ${pid})에 종료 신호를 보냅니다...${NC}"
      kill -TERM "$pid" 2>/dev/null || true
      for _ in $(seq 1 30); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 1
      done
      if kill -0 "$pid" 2>/dev/null; then
        echo -e "${RED}[강제 종료] 정상 종료되지 않아 SIGKILL을 보냅니다.${NC}"
        kill -KILL "$pid" 2>/dev/null || true
      fi
      rm -f "$PID_FILE"
      echo -e "${GREEN}[종료 완료] 데몬이 종료되었습니다.${NC}"
    else
      echo -e "${YELLOW}[안내] PID 파일은 있지만 해당 프로세스가 실행 중이지 않습니다. 정리합니다.${NC}"
      rm -f "$PID_FILE"
    fi
  else
    echo -e "${YELLOW}[안내] 실행 중인 데몬을 찾을 수 없습니다 (PID 파일 없음: ${PID_FILE}).${NC}"
  fi
  exit 0
fi

# --status: PID 파일 기준으로 데몬 실행 여부만 확인
if [[ "$DO_STATUS" == "true" ]]; then
  if [[ -f "$PID_FILE" ]] && kill -0 "$(cat "$PID_FILE" 2>/dev/null || echo -1)" 2>/dev/null; then
    echo -e "${GREEN}[실행 중]${NC} PID $(cat "$PID_FILE") (task 폴더: ${ABS_TASK_DIR})"
  else
    echo -e "${YELLOW}[실행 중 아님]${NC} (task 폴더: ${ABS_TASK_DIR})"
  fi
  exit 0
fi

# Ubuntu 환경 진단 함수 (--check-env)
check_environment() {
  echo -e "${BLUE}======================================================================${NC}"
  echo -e "${BOLD}${BLUE} loop_task.bash 실행 환경 진단${NC}"
  echo -e "${BLUE}======================================================================${NC}"

  for tool in bash find mv flock tmux notify-send; do
    if command -v "$tool" >/dev/null 2>&1; then
      echo -e " - 필수/보조 도구  : ${GREEN}✓ ${tool}${NC} ($(command -v "$tool"))"
    else
      echo -e " - 필수/보조 도구  : ${YELLOW}○ ${tool} (미설치 - 선택 사항)${NC}"
    fi
  done

  if command -v inotifywait >/dev/null 2>&1; then
    echo -e " - inotifywait     : ${GREEN}✓ 설치됨${NC} (즉시 감지 가능. 미설치 시 ${POLL_INTERVAL}초 폴링으로 동작)"
  else
    echo -e " - inotifywait     : ${YELLOW}○ 미설치${NC} (inotify-tools 설치 권장: sudo apt install inotify-tools; 미설치 시 ${POLL_INTERVAL}초 폴링)"
  fi

  local resolved=""
  if resolved="$(resolve_run_plan_bin 2>/dev/null)"; then
    echo -e " - run_plan.bash   : ${GREEN}✓ 발견 (${resolved})${NC}"
  else
    echo -e " - run_plan.bash   : ${RED}✗ 찾을 수 없음 (PATH에 설치하거나 --run-plan-bin으로 경로 지정)${NC}"
  fi

  echo -e " - task 폴더       : ${CYAN}${ABS_TASK_DIR}${NC} (open/in-progress/close)"
  echo -e "${BLUE}======================================================================${NC}"
}

# run_plan.bash 실행 파일 경로 탐색: 1) --run-plan-bin/환경변수  2) PATH  3) 이 스크립트와 같은 폴더
resolve_run_plan_bin() {
  if [[ -n "$RUN_PLAN_BIN" ]]; then
    if [[ -x "$RUN_PLAN_BIN" ]] || command -v "$RUN_PLAN_BIN" >/dev/null 2>&1; then
      echo "$RUN_PLAN_BIN"
      return 0
    fi
    return 1
  fi

  if command -v run_plan.bash >/dev/null 2>&1; then
    command -v run_plan.bash
    return 0
  fi

  local sibling
  sibling="$(dirname "$SCRIPT_PATH")/run_plan.bash"
  if [[ -x "$sibling" ]]; then
    echo "$sibling"
    return 0
  fi

  return 1
}

if [[ "$CHECK_ENV_ONLY" == "true" ]]; then
  check_environment
  exit 0
fi

# Ubuntu tmux 세션 내에서 데몬 실행 요청 시(--tmux) 자동으로 tmux 세션을 생성하고 재실행
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
  echo -e "${GREEN}[Ubuntu tmux 시작] 백그라운드 tmux 세션('${TMUX_SESSION_NAME}')에서 데몬을 시작했습니다.${NC}"
  echo -e " - 실시간 화면 접속 : ${CYAN}tmux attach -t ${TMUX_SESSION_NAME}${NC}"
  echo -e " - 화면에서 빠져나오기(세션 유지): ${CYAN}Ctrl+B 누른 후 D${NC}"
  echo -e " - 상태 확인/종료   : ${CYAN}$(basename "$0") --status${NC} / ${CYAN}$(basename "$0") --stop${NC}"
  exit 0
fi

if ! RUN_PLAN_BIN="$(resolve_run_plan_bin)"; then
  echo -e "${RED}[오류] 'run_plan.bash'를 찾을 수 없습니다. PATH에 설치하거나 --run-plan-bin으로 경로를 지정해 주세요.${NC}" >&2
  exit 1
fi

# Ubuntu flock을 이용한 단일 데몬 중복 실행 방지 락(Lock)
if command -v flock >/dev/null 2>&1 && [[ "$DRY_RUN" != "true" ]]; then
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    echo -e "${RED}[오류] 이 task 폴더에서 이미 다른 '$(basename "$0")' 데몬이 실행 중입니다 (${LOCK_FILE}).${NC}" >&2
    echo -e "확인: ${CYAN}$(basename "$0") --status${NC}" >&2
    exit 1
  fi
fi

# 대상 파일이 이미 존재하면 타임스탬프를 붙여 안전하게 이동 (덮어쓰기 방지). 최종 경로를 출력한다.
safe_move() {
  local src="$1"
  local dest="$2"
  if [[ -e "$dest" ]]; then
    local dir base stem
    dir="$(dirname "$dest")"
    base="$(basename "$dest")"
    stem="${base%.md}"
    dest="${dir}/${stem}.$(date +%Y%m%d_%H%M%S).md"
  fi
  mv "$src" "$dest"
  printf '%s' "$dest"
}

# task/open에서 가장 오래된(먼저 들어온) *.md 문서 경로를 출력 (없으면 빈 출력)
oldest_open_doc() {
  find "$OPEN_DIR" -maxdepth 1 -type f -name '*.md' -printf '%T@ %p\n' 2>/dev/null \
    | sort -n | head -n 1 | cut -d' ' -f2- || true
}

# task/in-progress의 (최대 1개여야 하는) 문서 경로를 출력 (없으면 빈 출력)
current_in_progress_doc() {
  find "$IN_PROGRESS_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | sort | head -n 1 || true
}

# task/open 폴더에 변화가 있을 때까지 대기 (inotifywait 있으면 즉시 감지, 없으면 폴링)
wait_for_open_dir_activity() {
  if command -v inotifywait >/dev/null 2>&1; then
    inotifywait -q -t "$POLL_INTERVAL" -e create -e moved_to -e close_write "$OPEN_DIR" >/dev/null 2>&1 || true
  else
    sleep "$POLL_INTERVAL"
  fi
}

# 문서 하나를 run_plan.bash에 전달해 처리한다.
# $1: task/in-progress에 있는 문서의 절대 경로, $2: 재개 여부("true"|"false")
# 반환값: run_plan.bash가 종료 코드 0으로 끝나면 0(및 문서를 close로 이동), 아니면 1
process_requirement_doc() {
  local doc_path="$1"
  local is_resume="$2"
  local base
  base="$(basename "$doc_path")"

  echo -e "\n${CYAN}----------------------------------------------------------------------${NC}"
  if [[ "$is_resume" == "true" ]]; then
    echo -e "${YELLOW}[재개] 미완료 작업을 이어서 진행합니다: ${base}${NC}"
  else
    echo -e "${YELLOW}[신규 작업] 요구사항 문서를 접수했습니다: ${base}${NC}"
  fi
  echo -e "${CYAN}----------------------------------------------------------------------${NC}"

  local run_plan_args=()
  if [[ "$is_resume" != "true" ]]; then
    run_plan_args+=("--req-file" "$doc_path")
  fi
  run_plan_args+=("${RUN_PLAN_EXTRA_ARGS[@]}")

  if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${YELLOW}[Dry-Run] 실행 예정 명령어:${NC} ${RUN_PLAN_BIN} ${run_plan_args[*]}"
    return 0
  fi

  send_ubuntu_notification "Claude Loop Task" "${base} 작업을 시작합니다 (재개: ${is_resume})." "normal"

  local task_log="${ABS_LOG_DIR}/task_$(basename "$base" .md)_$(date +%Y%m%d_%H%M%S).log"
  local rc
  set +e
  "$RUN_PLAN_BIN" "${run_plan_args[@]}" 2>&1 | tee "$task_log"
  rc=${PIPESTATUS[0]}
  set -e

  if [[ "$rc" -eq 0 ]]; then
    local closed_path
    closed_path=$(safe_move "$doc_path" "${CLOSE_DIR}/${base}")
    echo -e "${GREEN}[작업 완료] '${base}' → '${closed_path#"${WORK_DIR}"/}'${NC}"
    send_ubuntu_notification "Claude Loop Task 완료" "${base} 작업이 완료되어 task/close로 이동했습니다." "normal"
    return 0
  fi

  echo -e "${YELLOW}[작업 미완료] '${base}' (run_plan.bash 종료 코드: ${rc}). task/in-progress에 유지하고 ${FAIL_RETRY_DELAY}초 후 다시 시도합니다.${NC}"
  echo -e "${YELLOW}로그: ${task_log}${NC}"
  send_ubuntu_notification "Claude Loop Task 중단" "${base} 작업이 완료되지 못했습니다 (exit ${rc}). 재시도 대기 중." "critical"
  return 1
}

# ==============================================================================
# 메인 흐름: 데몬 시작 배너 + 종료 시 PID 파일 정리 + 모니터링 루프
# ==============================================================================

echo -e "${BLUE}======================================================================${NC}"
echo -e "${BOLD}${BLUE} Claude Loop Task 데몬${NC}"
echo -e "${BLUE}======================================================================${NC}"
echo -e " - task 폴더   : ${CYAN}${ABS_TASK_DIR}${NC} (open/in-progress/close)"
echo -e " - run_plan.bash: ${CYAN}${RUN_PLAN_BIN}${NC}"
[[ ${#RUN_PLAN_EXTRA_ARGS[@]} -gt 0 ]] && echo -e " - 전달 옵션   : ${CYAN}${RUN_PLAN_EXTRA_ARGS[*]}${NC}"
echo -e " - 확인 주기   : ${CYAN}${POLL_INTERVAL}초${NC} ($(command -v inotifywait >/dev/null 2>&1 && echo "inotifywait 사용 가능, 즉시 감지" || echo "폴링"))"
echo -e " - 실패 재시도 : ${CYAN}${FAIL_RETRY_DELAY}초 후${NC}"
echo -e " - 로그 디렉터리: ${CYAN}${ABS_LOG_DIR}${NC}"
echo -e "${BLUE}======================================================================${NC}"

if [[ "$DRY_RUN" != "true" ]]; then
  echo "$$" > "$PID_FILE"
  trap 'rm -f "$PID_FILE" 2>/dev/null || true' EXIT
  send_ubuntu_notification "Claude Loop Task 시작" "데몬이 시작되었습니다 (PID $$)." "low"
fi

while true; do
  active_doc=""
  is_resume="false"

  existing="$(current_in_progress_doc)"
  if [[ -n "$existing" ]]; then
    active_doc="$existing"
    is_resume="true"
  else
    candidate="$(oldest_open_doc)"
    if [[ -n "$candidate" ]]; then
      if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${YELLOW}[Dry-Run] '$(basename "$candidate")'를 task/in-progress로 옮기고 처리할 예정입니다.${NC}"
        active_doc="$candidate"
      else
        active_doc="$(safe_move "$candidate" "${IN_PROGRESS_DIR}/$(basename "$candidate")")"
      fi
      is_resume="false"
    fi
  fi

  if [[ -z "$active_doc" ]]; then
    if [[ "$ONCE" == "true" ]]; then
      echo -e "${GREEN}[대기 작업 없음] task/open, task/in-progress가 모두 비어 있어 종료합니다 (--once).${NC}"
      exit 0
    fi
    wait_for_open_dir_activity
    continue
  fi

  if process_requirement_doc "$active_doc" "$is_resume"; then
    task_rc=0
  else
    task_rc=1
  fi

  if [[ "$ONCE" == "true" || "$DRY_RUN" == "true" ]]; then
    exit "$task_rc"
  fi

  if [[ "$task_rc" -ne 0 ]]; then
    sleep "$FAIL_RETRY_DELAY"
  fi
done
