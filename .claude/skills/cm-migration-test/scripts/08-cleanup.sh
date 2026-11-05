#!/usr/bin/env bash
# 정리. terminate 만 쓴다 (force 는 CSP 에 과금되는 VM 을 남길 수 있어 쓰지 않는다).
# 같은 CSP 계정을 다른 사람도 쓰므로 "남은 자원 0" 이 아니라 "시험 전 기준선 대비 늘어난 것 0" 으로 판정한다.
#
#   08-cleanup.sh baseline <boot|cm> <csp> [csp...]   시험 전에 연결별 자원 수를 RUN_DIR/baseline-*.json 에 기록
#   08-cleanup.sh targets  [--yes]                    CM tumblebug 의 MIG_NS infra 전부 terminate + 공용 자원 삭제
#   08-cleanup.sh sources  <ns> [--yes]               부트스트랩 tumblebug 의 Source infra terminate + 공용 자원 삭제
#   08-cleanup.sh cm       [--yes]                    CM VM terminate (마지막에)
#   08-cleanup.sh residual <boot|cm> <csp> [csp...]   기준선과 비교해 늘어난 자원을 출력
set -euo pipefail
. "$(dirname "$0")/lib.sh"
TYPES="node vNet securityGroup sshKey"
pick_tb() { case "$1" in boot) use_boot_tb;; cm) use_cm_tb;; *) die "boot 또는 cm";; esac; }
# csp 의 리전으로 연결 이름 찾기 (Source 는 SRC_REGION, 대상은 TARGET_REGION_<csp>)
conns_for() {
  local csp=$1 rv="TARGET_REGION_$1" region; region=${!rv:-$SRC_REGION}
  tb GET /connConfig | jq -r --arg p "$csp" --arg r "$(tr 'A-Z' 'a-z' <<<"$region")" \
    '.connectionconfig[] | select(.providerName==$p) | select(.regionRepresentative==true) | select((.regionZoneInfo.assignedRegion // .regionDetail.regionId // "" | ascii_downcase)==$r) | .configName'
}
inspect() { # conn type -> overview json
  TB_TIMEOUT=300 tb POST /inspectResources "$(jq -n --arg c "$1" --arg t "$2" '{connectionName:$c, resourceType:$t}')" | jq -c '.resourceOverview'
}
terminate_all() { # ns
  local ns=$1 ids
  ids=$(tb GET "/ns/$ns/infra?option=id" | jq -r '.output[]? // .idList[]? // empty')
  for id in $ids; do
    log "terminate $ns/$id"
    TB_TIMEOUT=1800 tb DELETE "/ns/$ns/infra/$id?option=terminate" | jq -c '.message // .' || log "$ns/$id 삭제 실패. force 로 넘어가지 말고 원인을 본다"
  done
  log "$ns 공용 자원(vNet·SG·sshKey) 삭제"
  TB_TIMEOUT=900 tb DELETE "/ns/$ns/sharedResources" | jq -c '.' || log "공용 자원 삭제 실패 (위 메시지)"
}

case "${1:-}" in
baseline|residual)
  mode=$1; pick_tb "${2:?boot|cm}"; shift 2
  for csp in "$@"; do
    for c in $(conns_for "$csp"); do
      for t in $TYPES; do
        f="$RUN_DIR/baseline-$c-$t.json"
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
*) sed -n '2,12p' "$0"; exit 2 ;;
esac
