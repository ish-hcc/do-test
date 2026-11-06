#!/usr/bin/env bash
# 정리. terminate 만 쓴다 (force 는 CSP 에 과금되는 VM 을 남길 수 있어 쓰지 않는다).
# 같은 CSP 계정을 다른 사람도 쓰므로 "남은 자원 0" 이 아니라 "시험 전 기준선 대비 늘어난 것 0" 으로 판정한다.
#
#   08-cleanup.sh baseline <boot|cm> <csp> [csp...]   시험 전에 연결별 자원 수를 RUN_DIR/baseline-*.json 에 기록
#   08-cleanup.sh targets  [--yes]                    CM tumblebug 의 MIG_NS infra 전부 terminate + 공용 자원 삭제
#   08-cleanup.sh sources  <ns> [--yes]               부트스트랩 tumblebug 의 Source infra terminate + 공용 자원 삭제
#   08-cleanup.sh cm       [--yes]                    CM VM terminate (마지막에)
#   08-cleanup.sh residual <boot|cm> <csp> [csp...]   기준선과 비교해 늘어난 자원을 출력
# targets·sources·cm 은 실패가 있거나 ns 에 infra·vNet·SG·sshKey 가 남으면 그 목록을 내고 1 로 끝난다.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TYPES="node vNet securityGroup sshKey"
pick_tb() { case "$1" in boot) use_boot_tb;; cm) use_cm_tb;; *) die "boot 또는 cm";; esac; }
# csp 의 리전으로 연결 이름 찾기. boot(Source 쪽)는 SRC_REGION, cm(대상 쪽)은 TARGET_REGION_<csp>
conns_for() {
  local csp=$1 rv="TARGET_REGION_$1" region
  if [ "$SIDE" = boot ]; then region=$SRC_REGION; else region=${!rv:-$SRC_REGION}; fi
  tb GET /connConfig | jq -r --arg p "$csp" --arg r "$(tr 'A-Z' 'a-z' <<<"$region")" \
    '.connectionconfig[] | select(.providerName==$p) | select(.regionRepresentative==true) | select((.regionZoneInfo.assignedRegion // .regionDetail.regionId // "" | ascii_downcase)==$r) | .configName'
}
inspect() { # conn type -> overview json
  TB_TIMEOUT=300 tb POST /inspectResources "$(jq -n --arg c "$1" --arg t "$2" '{connectionName:$c, resourceType:$t}')" | jq -c '.resourceOverview'
}
# 실패는 FAILS 에 모으고 끝에 ns 에 남은 것과 함께 요약한다. 하나라도 남으면 terminate_all 이 1 을 돌려준다.
FAILS=()
fail() { FAILS+=("$*"); log "실패: $* (위 메시지). force 로 넘어가지 말고 원인을 본다"; }
ns_ids() { # ns type -> id 목록 (infra 또는 resources/<type>)
  if [ "$2" = infra ]; then tb GET "/ns/$1/infra?option=id" | jq -r '.output[]? // .idList[]? // empty'
  else tb GET "/ns/$1/resources/$2?option=id" | jq -r '.output[]? // empty'; fi
}
terminate_all() { # ns
  local ns=$1 id ids t r q left
  FAILS=()
  ids=$(ns_ids "$ns" infra) || fail "목록 조회 $ns/infra"
  for id in $ids; do
    log "terminate $ns/$id"
    TB_TIMEOUT=1800 tb DELETE "/ns/$ns/infra/$id?option=terminate" | jq -c '.message // .' || fail "terminate $ns/$id"
  done
  log "$ns 공용 자원(vNet·SG·sshKey) 삭제"
  # 실패해도 세지 않는다. 아래에서 같은 자원을 하나씩 다시 지우고, 끝에 남은 것을 센다
  TB_TIMEOUT=900 tb DELETE "/ns/$ns/sharedResources" | jq -c '.' || log "공용 자원 일괄 삭제 실패 (위 메시지). 하나씩 지운다"
  # beetle 이 이관하며 만든 자원(<seed>-vnet-01, -sg-NN, -sshkey-01)은 sharedResources 가 지우지 않는다 (2026-11-06 실측: total 0)
  local vnet_retry=()
  for t in sshKey securityGroup vNet; do
    q=""; [ "$t" = vNet ] && q="?action=withSubnets"
    ids=$(ns_ids "$ns" "$t") || fail "목록 조회 $ns/$t"
    for r in $ids; do
      log "삭제 $ns/$t/$r"
      if TB_TIMEOUT=600 tb DELETE "/ns/$ns/resources/$t/$r$q" | jq -c '.message // .'; then continue; fi
      if [ "$t" = vNet ]; then vnet_retry+=("$r"); log "$ns/vNet/$r 삭제 실패. 재시도 대기열에 넣는다"
      else fail "삭제 $ns/$t/$r"; fi
    done
  done
  # NCP vNet 은 비동기로 지워져서, 직전에 지운 서브넷·SG 가 남아 있으면 "still exists" 로 실패한다 (2026-11-06 실측). 1회만 다시 한다
  if [ "${#vnet_retry[@]}" -gt 0 ]; then
    log "vNet ${#vnet_retry[@]}개 ${VNET_RETRY_WAIT:-75}초 뒤 다시 삭제"; sleep "${VNET_RETRY_WAIT:-75}"
    for r in "${vnet_retry[@]}"; do
      log "재삭제 $ns/vNet/$r"
      TB_TIMEOUT=600 tb DELETE "/ns/$ns/resources/vNet/$r?action=withSubnets" | jq -c '.message // .' || fail "삭제 $ns/vNet/$r (재시도 포함 2회)"
    done
  fi
  # 응답이 성공이어도 레코드가 남는 경우가 있다 (Azure: "deletion unconfirmed; record retained", pitfalls.md). 목록으로 다시 본다
  left=()
  for t in infra vNet securityGroup sshKey; do
    ids=$(ns_ids "$ns" "$t") || ids="<조회실패>"
    for r in $ids; do left+=("$t/$r"); done
  done
  if [ "${#FAILS[@]}" -eq 0 ] && [ "${#left[@]}" -eq 0 ]; then log "$ns 정리 끝: 실패 0, 남은 것 0"; return 0; fi
  log "$ns 정리 미완: 실패 ${#FAILS[@]}건, ns 에 남은 것 ${#left[@]}건"
  for r in "${FAILS[@]}"; do log "  실패  $r"; done
  for r in "${left[@]}"; do log "  남음  $ns/$r"; done
  return 1
}

case "${1:-}" in
baseline|residual)
  mode=$1; SIDE=${2:?boot|cm}; pick_tb "$SIDE"; shift 2
  for csp in "$@"; do
    for c in $(conns_for "$csp"); do
      for t in $TYPES; do
        # 같은 연결 이름이 boot·cm 양쪽에 있으므로 파일 이름에 쪽을 넣는다
        f="$RUN_DIR/baseline-$SIDE-$c-$t.json"
        now=$(inspect "$c" "$t" 2>/dev/null || echo '{"error":true}')
        if [ "$mode" = baseline ]; then echo "$now" > "$f"; printf '%-28s %-14s %s\n' "$c" "$t" "$now"; continue; fi
        before=$(cat "$f" 2>/dev/null || echo '{"onCspTotal":0}')
        delta=$(jq -n --argjson a "$before" --argjson b "$now" '($b.onCspTotal // 0) - ($a.onCspTotal // 0)')
        printf '%-28s %-14s 전 %-3s 후 %-3s 증가 %s %s\n' "$c" "$t" "$(jq -r '.onCspTotal' <<<"$before")" "$(jq -r '.onCspTotal' <<<"$now")" "$delta" \
          "$([ "$delta" -gt 0 ] && echo '<- 남은 자원' || true)"
      done
    done
  done ;;
targets)
  use_cm_tb; require_yes "CM tumblebug $MIG_NS 의 infra 전부 terminate"; terminate_all "$MIG_NS" ;;
sources)
  ns=${2:?ns}; use_boot_tb; require_yes "부트스트랩 tumblebug $ns 의 infra terminate"; terminate_all "$ns" ;;
cm)
  use_boot_tb; require_yes "CM VM terminate (플랫폼과 그 안의 데이터가 사라진다)"; terminate_all "$CM_NS" ;;
*) sed -n '2,10p' "$0"; exit 2 ;;
esac
