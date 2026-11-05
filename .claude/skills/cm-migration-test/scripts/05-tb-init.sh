#!/usr/bin/env bash
# CM 플랫폼의 cb-tumblebug 을 초기화한다: init/init.sh 를 INIT_OPTION(c = Azure 포함 전체) 으로.
# 로컬에서 돌리고 TUMBLEBUG_SERVER 로 CM VM 의 tumblebug 을 가리킨다 (init.py 가 읽는 env).
#
#   05-tb-init.sh run       init 실행. 10~40분 걸린다. 로그는 RUN_DIR/tb-init.log
#   05-tb-init.sh check     readyz, provider·connConfig 수, init 로그 끝 요약
#
# 선행: 01-credentials.sh 가 0 으로 끝남(키 파일 있음), 04-cm-platform.sh 로 플랫폼 기동됨.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
mode=${1:?run | check}
use_cm_tb
ip=$(state_get CM_PUBLIC_IP)
KEY_FILE="$RUN_DIR/cred.key"
want="v$CB_TUMBLEBUG"

# init 소스는 실행 중인 tumblebug 과 같은 태그여야 한다. TB_SRC 가 그 태그가 아니면
# TB_SRC 를 건드리지 않고 RUN_DIR 아래에 그 태그의 worktree 를 만들어 쓴다.
init_src() {
  local at; at=$(git -C "$TB_SRC" describe --tags --exact-match HEAD 2>/dev/null || true)
  if [ "$at" = "$want" ]; then echo "$TB_SRC"; return; fi
  local wt="$RUN_DIR/cb-tumblebug-$want"
  if [ ! -d "$wt" ]; then
    log "$TB_SRC 는 '${at:-태그 아님}' 입니다. $want worktree 를 $wt 에 만듭니다"
    git -C "$TB_SRC" fetch -q --tags https://github.com/cloud-barista/cb-tumblebug.git
    git -C "$TB_SRC" worktree add -q --detach "$wt" "$want" >&2
  fi
  echo "$wt"
}

case "$mode" in
run)
  [ -s "$KEY_FILE" ] || die "키 파일이 없습니다. 01-credentials.sh 먼저"
  running=$(tb GET /readyz | jq -c . ) || die "CM tumblebug 에 접속 못 함 ($TB_URL)"
  log "CM tumblebug readyz: $running"
  src=$(init_src)
  log "init 소스 $src ($(git -C "$src" describe --tags 2>/dev/null)), 옵션 $INIT_OPTION, 로그 $RUN_DIR/tb-init.log"
  start=$(date +%s)
  # 입력: 메뉴 선택만 stdin 으로. 복호화 비밀번호는 --key-file, API 계정은 env (출력 안 함)
  ( cd "$src" && export TUMBLEBUG_SERVER="$ip:1323" TB_API_USERNAME="$TB_USER" TB_API_PASSWORD="$TB_PASS" && \
    printf '%s\n' "$INIT_OPTION" | ./init/init.sh --key-file "$KEY_FILE" ) > "$RUN_DIR/tb-init.log" 2>&1 && rc=0 || rc=$?
  log "init 종료 rc=$rc, $(( ($(date +%s)-start)/60 ))분"
  "$0" check
  ;;
check)
  echo "readyz: $(tb GET /readyz | jq -c .)"
  echo "provider: $(tb GET /provider | jq -r '.output // . | if type=="array" then join(",") else tostring end')"
  echo "connConfig: $(tb GET /connConfig | jq '.connectionconfig | length')개"
  tb GET /connConfig | jq -r '.connectionconfig | group_by(.providerName)[] | "  \(.[0].providerName): \(length)개 (검증됨 \([.[] | select(.verified==true)] | length))"'
  if [ -f "$RUN_DIR/tb-init.log" ]; then
    echo "--- init 로그 끝 ---"
    grep -a -E 'Asset Summary|Provider |elapsed|Error|error|failed' "$RUN_DIR/tb-init.log" | tail -30
  fi
  ;;
*) die "모드는 run | check" ;;
esac
