#!/usr/bin/env bash
# 공통 함수. 다른 스크립트가 source 한다. 단독 실행하지 않는다.
# 비밀값(API 비밀번호, 개인키, credential)은 화면에 찍지 않는다.

SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/test.env
. "$SKILL_DIR/config/test.env"
# shellcheck source=../config/versions.env
. "$SKILL_DIR/config/versions.env"
mkdir -p "$RUN_DIR" && chmod 700 "$RUN_DIR"
STATE="$RUN_DIR/state.env"
touch "$STATE" && chmod 600 "$STATE"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
die() { log "중단: $*"; exit 1; }
need() { for c in "$@"; do command -v "$c" >/dev/null || die "$c 이(가) 없습니다"; done; }
need curl jq

# state.env 에 key=value 를 남기고 읽는다. 다음 단계 스크립트가 이어 받는다.
state_set() { local k=$1 v=$2; grep -v "^$k=" "$STATE" > "$STATE.tmp" || true; printf '%s=%q\n' "$k" "$v" >> "$STATE.tmp"; mv "$STATE.tmp" "$STATE"; chmod 600 "$STATE"; }
# shellcheck disable=SC1090
state_get() { ( . "$STATE"; eval "printf '%s' \"\${$1:-}\"" ); }

# 비용이 들거나 되돌리기 어려운 동작은 --yes 가 있어야 실행한다.
# 승인은 대화에서 받고, 스크립트에는 --yes 로 넘긴다.
YES=0
for a in "$@"; do [ "$a" = "--yes" ] && YES=1; done
require_yes() { [ "$YES" = 1 ] || { log "계획만 보였습니다. 실행하려면 승인받은 뒤 --yes 를 붙입니다: $*"; exit 3; }; }

# --- tumblebug 호출 ---
# TB_URL·TB_USER·TB_PASS 를 정한 뒤 tb 를 부른다.
use_boot_tb() {
  TB_URL=$BOOT_TB_URL
  if [ -z "${TB_USER:-}" ]; then
    local envs
    envs=$(timeout 10 docker inspect "$BOOT_TB_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null) \
      || die "부트스트랩 tumblebug 컨테이너($BOOT_TB_CONTAINER)를 찾지 못했습니다"
    TB_USER=$(sed -n 's/^TB_API_USERNAME=//p' <<<"$envs")
    TB_PASS=$(sed -n 's/^TB_API_PASSWORD=//p' <<<"$envs")
  fi
  [ -n "$TB_USER" ] && [ -n "$TB_PASS" ] || die "tumblebug API 계정을 못 읽었습니다"
}
use_cm_tb() {
  local ip; ip=$(state_get CM_PUBLIC_IP); [ -n "$ip" ] || die "CM VM IP 가 state 에 없습니다 (03 단계 먼저)"
  TB_URL="http://$ip:1323/tumblebug"
  TB_USER=$(state_get CM_TB_USER); TB_PASS=$(state_get CM_TB_PASS)
  [ -n "$TB_USER" ] || die "CM tumblebug 계정이 state 에 없습니다 (04 단계 먼저)"
}
# tb METHOD PATH [JSON]  -> 응답 본문. HTTP 4xx/5xx 면 본문을 stderr 로 내고 실패한다.
tb() {
  local m=$1 p=$2 body=${3:-} out code
  out=$(mktemp)
  if [ -n "$body" ]; then
    code=$(curl -sS -m "${TB_TIMEOUT:-900}" -o "$out" -w '%{http_code}' -u "$TB_USER:$TB_PASS" -X "$m" \
      -H 'Content-Type: application/json' "$TB_URL$p" --data-binary "$body")
  else
    code=$(curl -sS -m "${TB_TIMEOUT:-900}" -o "$out" -w '%{http_code}' -u "$TB_USER:$TB_PASS" -X "$m" "$TB_URL$p")
  fi
  if [ "${code:0:1}" != 2 ]; then log "$m $p -> HTTP $code"; head -c 2000 "$out" >&2; echo >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}

# 내 공인 IP/32
my_cidr() { [ -n "$ADMIN_CIDR" ] && { echo "$ADMIN_CIDR"; return; }; echo "$(curl -sS -m 10 https://checkip.amazonaws.com | tr -d '[:space:]')/32"; }

# source-vms.conf 를 "idx name purpose ports scripts..." 로 읽는다 (주석·빈 줄 제외)
source_vms() { grep -v -E '^\s*(#|$)' "$SKILL_DIR/config/source-vms.conf"; }
source_vm_count() { source_vms | wc -l | tr -d ' '; }

# 노드의 SSH 접속 정보: 개인키 파일 경로와 사용자명. 키는 RUN_DIR 에 600 으로 둔다.
node_ssh_key() { # ns infra -> 키 파일 경로 출력
  local ns=$1 infra=$2 kid key f
  kid=$(tb GET "/ns/$ns/infra/$infra" | jq -r '.node[0].sshKeyId')
  f="$RUN_DIR/$ns-$kid.pem"
  if [ ! -s "$f" ]; then
    key=$(tb GET "/ns/$ns/resources/sshKey/$kid" | jq -r '.privateKey')
    [ -n "$key" ] && [ "$key" != null ] || die "$ns/$kid 개인키를 못 받았습니다"
    ( umask 077; printf '%s\n' "$key" > "$f" )
  fi
  echo "$f"
}
ssh_node() { # key user ip cmd...
  local key=$1 user=$2 ip=$3; shift 3
  timeout "${SSH_TIMEOUT:-1800}" ssh -n -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 -o LogLevel=ERROR "$user@$ip" "$@"
}
