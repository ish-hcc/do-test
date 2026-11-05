#!/usr/bin/env bash
# Source VM 에 source-vms.conf 대로 소프트웨어를 설치한다. 노드 g1-<idx> 에 그 줄의 스크립트를 순서대로 돌린다.
#
#   03-install-sources.sh <ns>            전 노드 병렬 설치. 로그는 RUN_DIR/install-<ns>-<이름>.log
#   03-install-sources.sh <ns> check      설치 결과만 확인 (서비스·포트)
set -euo pipefail
. "$(dirname "$0")/lib.sh"
use_boot_tb
ns=${1:?네임스페이스}; mode=${2:-install}
GH_SCRIPTS=${GH_SCRIPTS:-$HOME/go/src/cloud-migrator/cm-grasshopper/examples/software-install-scripts}
[ -d "$GH_SCRIPTS" ] || die "$GH_SCRIPTS 가 없습니다"

infra=$(tb GET "/ns/$ns/infra/$SRC_INFRA")
key=$(node_ssh_key "$ns" "$SRC_INFRA")

node_field() { jq -r --arg id "$SRC_NODEGROUP-$1" ".node[] | select(.id==\$id) | .$2" <<<"$infra"; }

install_one() { # idx name scripts...
  local idx=$1 name=$2; shift 4
  local ip user f src rc=0
  ip=$(node_field "$idx" publicIP); user=$(node_field "$idx" nodeUserName)
  [ -n "$ip" ] && [ "$ip" != null ] || { echo "g1-$idx: 공인 IP 없음"; return 1; }
  for f in "$@"; do
    if [[ $f == @* ]]; then src="$SKILL_DIR/scripts/source/${f#@}"; else src="$GH_SCRIPTS/$f"; fi
    [ -f "$src" ] || { echo "$src 없음"; return 1; }
    echo "=== $(date +%T) $name($ip) $f"
    # 스크립트를 stdin 으로 넘긴다. -n 을 쓰지 않는 유일한 자리라 입력은 이 파일뿐이다.
    timeout 1800 ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=15 \
      -o LogLevel=ERROR "$user@$ip" 'sudo bash -s' < "$src" || { rc=$?; echo "!!! $f 실패 rc=$rc"; return $rc; }
  done
  echo "=== $(date +%T) $name 완료"
}

check_one() { # idx name purpose ports
  local idx=$1 name=$2 ports=$4 ip user out
  ip=$(node_field "$idx" publicIP); user=$(node_field "$idx" nodeUserName)
  out=$(ssh_node "$key" "$user" "$ip" "for p in ${ports//,/ }; do ss -ltnH \"sport = :\$p\" | grep -q . && printf '%s:열림 ' \$p || printf '%s:닫힘 ' \$p; done; command -v docker >/dev/null && sudo docker ps --format '{{.Names}}' | tr '\n' ' '" 2>&1) || true
  printf '%-15s %-15s %s\n' "$name" "$ip" "$out"
}

case "$mode" in
  install)
    log "$ns: $(source_vm_count)대에 병렬 설치. 진행은 $RUN_DIR/install-$ns-*.log"
    pids=()
    while read -r idx name purpose ports scripts; do
      # shellcheck disable=SC2086
      install_one "$idx" "$name" "$purpose" "$ports" $scripts > "$RUN_DIR/install-$ns-$name.log" 2>&1 &
      pids+=("$!:$name")
    done < <(source_vms)
    fail=0
    for p in "${pids[@]}"; do
      if wait "${p%%:*}"; then log "${p#*:} 성공"; else log "${p#*:} 실패 (로그 끝):"; tail -5 "$RUN_DIR/install-$ns-${p#*:}.log" >&2; fail=1; fi
    done
    [ $fail = 0 ] || die "설치 실패가 있습니다"
    ;;
  check)
    while read -r idx name purpose ports scripts; do check_one "$idx" "$name" "$purpose" "$ports"; done < <(source_vms) ;;
  *) die "모드는 install 또는 check" ;;
esac
