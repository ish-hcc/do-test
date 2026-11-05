#!/usr/bin/env bash
# 부트스트랩 tumblebug 의 infraDynamic 으로 VM 을 만든다.
#
#   02-create-vms.sh spec   <vcpu> <mem>      스펙·이미지 후보만 조회 (만들지 않음)
#   02-create-vms.sh cm     [--yes]           CM 플랫폼 VM 1대 (CM_VCPU/CM_MEM_GIB)
#   02-create-vms.sh source <ns> [--yes]      Source VM 묶음. nodeGroup 하나에 source-vms.conf 의 VM 전부
#
# --yes 없이 부르면 요청 본문과 infraDynamicReview 결과만 보인다. CSP 과금이 시작되는 생성은 --yes 가 있어야 한다.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
use_boot_tb

# 조건에 맞는 가장 싼 스펙 id
pick_spec() {
  local vcpu=$1 mem=$2 body
  body=$(jq -n --arg p "$SRC_CSP" --arg r "$SRC_REGION" --arg a "$SRC_ARCH" --arg c "$vcpu" --arg m "$mem" '{
    filter:{policy:[
      {metric:"providerName",condition:[{operator:"=",operand:$p}]},
      {metric:"regionName",condition:[{operator:"=",operand:$r}]},
      {metric:"architecture",condition:[{operator:"=",operand:$a}]},
      {metric:"vCPU",condition:[{operator:">=",operand:$c},{operator:"<=",operand:$c}]},
      {metric:"memoryGiB",condition:[{operator:">=",operand:$m},{operator:"<=",operand:$m}]}]},
    priority:{policy:[{metric:"cost",weight:1.0}]},
    limit:5}')
  tb POST /recommendSpec "$body"
}
# 그 스펙에 맞는 OS 이미지 id
pick_image() {
  local spec=$1 body
  body=$(jq -n --arg s "$spec" --arg o "$SRC_OS" '{matchedSpecId:$s, osType:$o, isGPUImage:false, isKubernetesImage:false, includeDeprecatedImage:false}')
  tb POST /ns/system/resources/searchImage "$body"
}

resolve() { # vcpu mem -> "specId imageId"
  local specs spec imgs img
  specs=$(pick_spec "$1" "$2")
  spec=$(jq -r '.[0].id // empty' <<<"$specs")
  [ -n "$spec" ] || die "${SRC_CSP}/${SRC_REGION} 에 ${1}vCPU/${2}GiB 스펙이 없습니다. test.env 값을 바꿉니다"
  img=$SRC_IMAGE_ID
  if [ -z "$img" ]; then
    imgs=$(pick_image "$spec")
    img=$(jq -r '[.imageList[] | select(.isBasicImage==true)] | sort_by(.id) | .[0].id // empty' <<<"$imgs")
  fi
  [ -n "$img" ] || die "$spec 에 맞는 '$SRC_OS' 이미지가 없습니다"
  log "스펙 $spec ($(jq -r '.[0] | "\(.vCPU)vCPU \(.memoryGiB)GiB $\(.costPerHour)/h"' <<<"$specs")), 이미지 $img"
  echo "$spec $img"
}

ensure_ns() {
  # 네임스페이스는 tumblebug 안의 기록이라 CSP 과금이 없다. Review 가 네임스페이스를 요구하므로 --yes 없이 만든다
  tb GET "/ns/$1" >/dev/null 2>&1 && return
  tb POST /ns "$(jq -n --arg n "$1" '{name:$n, description:"cm-migration-test"}')" >/dev/null
  log "네임스페이스 $1 생성"
}

create() { # ns infra size vcpu mem disk
  local ns=$1 infra=$2 size=$3 vcpu=$4 mem=$5 disk=$6 si spec img body review
  si=$(resolve "$vcpu" "$mem"); spec=${si% *}; img=${si#* }
  body=$(jq -n --arg n "$infra" --arg g "$SRC_NODEGROUP" --argjson s "$size" --arg sp "$spec" --arg im "$img" --argjson d "$disk" \
    '{name:$n, installMonAgent:"no", policyOnPartialFailure:"continue",
      nodeGroups:[{name:$g, nodeGroupSize:$s, specId:$sp, imageId:$im, rootDiskSize:$d}]}')
  log "요청 본문: $(jq -c . <<<"$body")"
  ensure_ns "$ns"
  review=$(tb POST "/ns/$ns/infraDynamicReview" "$body")
  log "검토: overallStatus=$(jq -r '.overallStatus' <<<"$review") creationViable=$(jq -r '.creationViable' <<<"$review")"
  jq '{overallStatus, creationViable, estimatedCost: (.estimatedCost // null), recommendations: (.recommendations // null)}' <<<"$review"
  [ "$(jq -r '.creationViable' <<<"$review")" = true ] || die "생성 불가 판정입니다. 스펙·이미지를 바꿉니다"
  require_yes "$ns/$infra 에 ${size}대 생성 (${spec})"
  TB_TIMEOUT=1800 tb POST "/ns/$ns/infraDynamic" "$body" > "$RUN_DIR/$ns-$infra.json"
  jq -r '.node[] | "\(.id)\t\(.status)\t\(.publicIP)\t\(.privateIP)\t\(.cspResourceId)"' "$RUN_DIR/$ns-$infra.json"
}

open_ports() { # ns infra cidr ports(공백구분)
  local ns=$1 infra=$2 cidr=$3 ports=$4 sg rules
  sg=$(tb GET "/ns/$ns/infra/$infra" | jq -r '.node[0].securityGroupIds[0]')
  rules=$(for p in $ports; do jq -n --arg p "$p" --arg c "$cidr" '{Ports:$p,Protocol:"TCP",Direction:"inbound",CIDR:$c}'; done | jq -s '{firewallRules:.}')
  tb POST "/ns/$ns/resources/securityGroup/$sg/rules" "$rules" >/dev/null
  log "$ns/$sg 에 TCP $(echo $ports) 를 $cidr 로 열었습니다"
}

case "${1:-}" in
  spec)
    resolve "${2:?vcpu}" "${3:?mem}" ;;
  cm)
    create "$CM_NS" "$CM_INFRA" 1 "$CM_VCPU" "$CM_MEM_GIB" "$CM_DISK_GB"
    open_ports "$CM_NS" "$CM_INFRA" "$(my_cidr)" "$CM_API_PORTS"
    ip=$(tb GET "/ns/$CM_NS/infra/$CM_INFRA" | jq -r '.node[0].publicIP')
    state_set CM_PUBLIC_IP "$ip"
    state_set CM_PRIVATE_IP "$(tb GET "/ns/$CM_NS/infra/$CM_INFRA" | jq -r '.node[0].privateIP')"
    log "CM VM 공인 IP $ip" ;;
  source)
    ns=${2:?네임스페이스 (onpremise 또는 csp)}
    create "$ns" "$SRC_INFRA" "$(source_vm_count)" "$SRC_VCPU" "$SRC_MEM_GIB" "$SRC_DISK_GB"
    # Source VM 포트는 CM VM 에서 오는 접근(honeybee 수집, 이관 확인)과 내 IP 에 연다
    ports=$(source_vms | awk '{print $4}' | tr ',' '\n' | sort -un | tr '\n' ' ')
    open_ports "$ns" "$SRC_INFRA" "$(my_cidr)" "$ports"
    cm_ip=$(state_get CM_PUBLIC_IP)
    [ -n "$cm_ip" ] && open_ports "$ns" "$SRC_INFRA" "$cm_ip/32" "22 $ports"
    ;;
  *) sed -n '2,9p' "$0"; exit 2 ;;
esac
