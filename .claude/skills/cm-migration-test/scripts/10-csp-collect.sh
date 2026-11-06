#!/usr/bin/env bash
# cm-honeybee CSP 소스 그룹 수집 시험. CSP 마다 VM 1대 + data disk 1개를 부트스트랩 tumblebug 으로 만들고,
# honeybee 에 type csp 소스 그룹으로 등록해 import/infra 로 수집한 뒤, tumblebug 이 아는 실제 값과 대조해
# "Cloud-Migrator 세부 목표" CM-Honeybee 1~8행(Image Spec VPC Subnet SG KeyPair VM Disk)을 O/△/X 로 판정한다.
#
#   10-csp-collect.sh create   <csp> [region] [--yes]   스펙·이미지 고르기 → Review → (--yes) infraDynamic + data disk
#   10-csp-collect.sh register <csp> [--yes]            --yes 없으면 dry-run: 바디의 key 목록과 값이 비었는지만 보인다
#   10-csp-collect.sh collect  <csp> [csp...]           discover → import/infra?count_objects=false → csp 섹션 저장
#   10-csp-collect.sh judge    [csp...]                 (상태 안 바꿈) honeybee 의 csp 섹션과 tumblebug 값을 대조해 표로 낸다
#   10-csp-collect.sh cleanup  [--yes]                  honeybee 소스 그룹 <ns>-* 삭제 → 08-cleanup.sh sources <ns> → data disk 삭제
#
# 대상: tumblebug 은 BOOT_TB_URL, honeybee 는 HBC_HB_URL, credential 원본은 tumblebug OpenBao(HBC_BAO_ADDR,
# secret/data/csp/<csp>, 토큰은 BOOT_TB_CONTAINER 의 VAULT_TOKEN). 이름은 infra·소스 그룹 모두 <HBC_NS>-<csp>.
# credential 값은 OpenBao 응답 -> jq -> curl stdin 파이프로만 흐른다 (argv·파일·화면에 안 남음).
# 기준: cm-honeybee bfe9cbe 이상. 그 전 honeybee 는 aws·alibaba·ncp 에서 VPC 등이 빈다 (references/pitfalls.md).
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need python3 docker
use_boot_tb
NS=$HBC_NS
HB=$HBC_HB_URL

hb() { # METHOD PATH [stdin]
  local m=$1 p=$2 out code; out=$(mktemp)
  if [ "${3:-}" = stdin ]; then
    code=$(curl -sS -m "${HB_TIMEOUT:-600}" -o "$out" -w '%{http_code}' -X "$m" -H 'Content-Type: application/json' "$HB$p" --data-binary @-)
  else
    code=$(curl -sS -m "${HB_TIMEOUT:-600}" -o "$out" -w '%{http_code}' -X "$m" "$HB$p")
  fi
  if [ "${code:0:1}" != 2 ]; then log "$m $p -> HTTP $code"; head -c 2000 "$out" >&2; echo >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}

# honeybee credential 키 <- tumblebug OpenBao 키. honeybee 쪽 키는 GET /honeybee/csp/<csp> 의 credential_keys 와 맞춰 본다.
# kt: tumblebug kt 는 kt-driver (cloudinfo.yaml "KT Cloud (VPC)") = honeybee kt(KT VPC). honeybee ktclassic(API_Key/Secret_Key)은
#     tumblebug OpenBao 에 대응 키가 없다 (2026-11-06 확인).
cred_map() { # csp -> {"<honeybee 키>":"<OpenBao 키>"}
  local pairs
  case "$1" in
    aws)       pairs='aws_access_key_id<-AWS_ACCESS_KEY_ID aws_secret_access_key<-AWS_SECRET_ACCESS_KEY' ;;
    azure)     pairs='clientId<-ARM_CLIENT_ID clientSecret<-ARM_CLIENT_SECRET tenantId<-ARM_TENANT_ID subscriptionId<-ARM_SUBSCRIPTION_ID' ;;
    gcp)       pairs='private_key<-private_key project_id<-project_id client_email<-client_email' ;;
    alibaba)   pairs='AccessKeyId<-ALIBABA_CLOUD_ACCESS_KEY_ID AccessKeySecret<-ALIBABA_CLOUD_ACCESS_KEY_SECRET' ;;
    ibm)       pairs='ApiKey<-IC_API_KEY' ;;
    ncp)       pairs='ncloud_access_key<-NCLOUD_ACCESS_KEY ncloud_secret_key<-NCLOUD_SECRET_KEY' ;;
    nhn)       pairs='IdentityEndpoint<-NHN_IDENTITY_ENDPOINT Username<-NHN_USERNAME Password<-NHN_PASSWORD DomainName<-NHN_DOMAIN_NAME TenantId<-NHN_TENANT_ID' ;;
    openstack) pairs='IdentityEndpoint<-OS_AUTH_URL Username<-OS_USERNAME Password<-OS_PASSWORD DomainName<-OS_DOMAIN_NAME ProjectID<-OS_PROJECT_ID' ;;
    tencent)   pairs='SecretId<-TENCENTCLOUD_SECRET_ID SecretKey<-TENCENTCLOUD_SECRET_KEY' ;;
    kt)        pairs='IdentityEndpoint<-KT_IDENTITY_ENDPOINT Username<-KT_USERNAME Password<-KT_PASSWORD DomainName<-KT_DOMAIN_NAME ProjectID<-KT_PROJECT_ID' ;;
    *) die "모르는 csp: $1 (aws azure gcp alibaba ibm ncp nhn openstack tencent kt)" ;;
  esac
  jq -cn --arg p "$pairs" '$p | split(" ") | map(split("<-") | {(.[0]): .[1]}) | add'
}

region_of() { local v="HBC_REGION_$1"; [ -n "${!v:-}" ] || die "$1 리전을 정하지 못했습니다 ($v)"; echo "${!v}"; }
conn_of() { echo "$1-$(tr 'A-Z' 'a-z' <<<"$2")"; }

# 소스 그룹·연결 id: state 에 없으면 honeybee 에서 이름 <ns>-<csp> 로 찾는다 (state 없이 만든 그룹도 판정할 수 있게)
sg_of() {
  local csp=$1 v; v=$(state_get "HBC_${csp}_SG")
  [ -n "$v" ] || v=$(hb GET /source_group | jq -r --arg n "$NS-$csp" '[.source_group[]? | select(.name == $n)][0].id // empty')
  echo "$v"
}
conn_json_of() { # sg -> 첫 vm 연결 {id, resource_id}
  hb GET "/source_group/$1/connection_info" | jq -c '[.connection_info[]? | select(.resource_type == "vm")][0] // empty | {id, resource_id}'
}

# tumblebug 의 ns 안에서 CSP 리소스 id 가 맞는 노드를 찾는다. infra 이름이 바뀐 경우(예: hbcheck-aws2)도 잡는다.
# infra 단건 GET 은 tumblebug 이 초당 5회로 막아(429) 목록 GET 한 번을 RUN_DIR 에 두고 찾는다
tb_node_by_csp_id() { # rid -> {infra, node}
  local f="$RUN_DIR/hbc-tb-infra-list.json"
  [ -s "$f" ] || tb GET "/ns/$NS/infra" > "$f"
  jq -c --arg r "$1" '[.infra[]? | .id as $i | .node[]? | select(.cspResourceId == $r or .cspResourceName == $r) | {infra: $i, node: .}][0] // empty' "$f"
}

# OpenBao credential -> honeybee 소스 그룹 바디 (stdout). 값은 이 파이프 밖으로 나가지 않는다.
build_body() { # csp region_name
  local csp=$1 rn=$2 map tok envs
  map=$(cred_map "$csp")
  envs=$(timeout 10 docker inspect "$BOOT_TB_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}') \
    || die "$BOOT_TB_CONTAINER env 를 못 읽었습니다"
  tok=$(sed -n 's/^VAULT_TOKEN=//p' <<<"$envs"); envs=""
  [ -n "$tok" ] || die "$BOOT_TB_CONTAINER env 에 VAULT_TOKEN 이 없습니다"
  # printf 는 셸 내장이라 토큰이 프로세스 argv 에 안 뜬다
  curl -sSf -m 10 -H @<(printf 'X-Vault-Token: %s\n' "$tok") "$HBC_BAO_ADDR/v1/secret/data/csp/$csp" |
    jq -ce --argjson m "$map" --arg csp "$csp" --arg rn "$rn" --arg n "$NS-$csp" '
      .data.data as $d
      | ($m | to_entries | map({key: .key, value: ($d[.value] // "" | tostring)})) as $cred
      | if any($cred[]; .value == "") then
          error("OpenBao 에 비었거나 없는 키: " + ([$cred[] | select(.value == "") | .key] | join(",")))
        else
          {name: $n, description: "cm-migration-test csp collect", type: "csp", provider_name: $csp, region_name: $rn, credential: $cred}
        end'
}

cmd=${1:-}; shift || true
args=(); for a in "$@"; do [ "$a" = --yes ] || args+=("$a"); done

case "$cmd" in
create)
  csp=${args[0]:-}; [ -n "$csp" ] || die "csp 를 줍니다"
  region=${args[1]:-$(region_of "$csp")}; conn=$(conn_of "$csp" "$region"); infra="$NS-$csp"
  tb GET "/connConfig/$conn" >/dev/null || die "tumblebug 에 연결 $conn 이 없습니다"
  specs=$(tb POST /recommendSpec "$(jq -n --arg p "$csp" --arg r "$(tr 'A-Z' 'a-z' <<<"$region")" --arg c "$HBC_VCPU" --arg m "$HBC_MEM_GIB" '{
    filter:{policy:[
      {metric:"providerName",condition:[{operand:$p,operator:"=="}]},
      {metric:"regionName",condition:[{operand:$r,operator:"=="}]},
      {metric:"vCPU",condition:[{operand:$c,operator:">="}]},
      {metric:"memoryGiB",condition:[{operand:$m,operator:">="}]},
      {metric:"architecture",condition:[{operand:"x86_64",operator:"=="}]}]},
    priority:{policy:[{metric:"cost"}]}, limit:8}')")
  spec=$(jq -r '.[0].id // empty' <<<"$specs"); [ -n "$spec" ] || die "$conn 에 ${HBC_VCPU}vCPU/${HBC_MEM_GIB}GiB 이상 스펙이 없습니다"
  log "스펙 $spec ($(jq -r '.[0] | "\(.vCPU)vCPU \(.memoryGiB)GiB $\(.costPerHour)/h"' <<<"$specs"))"
  [ "$(jq -r '.[0].costPerHour' <<<"$specs")" = -1 ] && log "주의: costPerHour=-1 이라 최저가 정렬이 안 된 후보다 (tencent 2026-11-06). 위 후보가 싼지 따로 본다"
  # searchImage 는 ns/system 에서 한다. 사용자 ns 에서 하면 tencent·kt 가 0건 (pitfalls.md)
  img=$(tb POST /ns/system/resources/searchImage "$(jq -n --arg p "$csp" --arg r "$region" --arg s "$spec" \
    '{providerName:$p, regionName:$r, osType:"ubuntu 22.04", matchedSpecId:$s, includeBasicImageOnly:true, maxResults:5}')" \
    | jq -r '.imageList[0].id // empty')
  [ -n "$img" ] || die "$spec 에 맞는 Ubuntu 22.04 이미지가 없습니다"
  disk=$HBC_DISK_GB; [ "$csp" = ncp ] && [ "$disk" -lt 100 ] && disk=100   # NCP data disk 최소 100GB
  body=$(jq -n --arg n "$infra" --arg c "$conn" --arg s "$spec" --arg i "$img" \
    '{name:$n, description:"cm-migration-test csp collect", installMonAgent:"no", policyOnPartialFailure:"continue",
      nodeGroups:[{name:"g1", nodeGroupSize:1, connectionName:$c, specId:$s, imageId:$i}]}')
  log "요청 본문: $(jq -c . <<<"$body"), data disk ${disk}GB"
  tb GET "/ns/$NS" >/dev/null 2>&1 || { tb POST /ns "$(jq -n --arg n "$NS" '{name:$n, description:"cm-migration-test csp collect"}')" >/dev/null; log "네임스페이스 $NS 생성"; }
  review=$(tb POST "/ns/$NS/infraDynamicReview" "$body")
  jq '{overallStatus, creationViable, estimatedCost: (.estimatedCost // null)}' <<<"$review"
  [ "$(jq -r '.creationViable' <<<"$review")" = true ] || die "생성 불가 판정입니다"
  require_yes "$NS/$infra 에 $spec 1대 + data disk ${disk}GB 생성"
  TB_TIMEOUT=1800 tb POST "/ns/$NS/infraDynamic" "$body" > "$RUN_DIR/hbc-$csp-create.json"
  state_set "HBC_${csp}_INFRA" "$infra"
  jq -r '.node[] | "\(.id)\t\(.status)\t\(.cspResourceId)\t\(.region.region)/\(.region.zone)"' "$RUN_DIR/hbc-$csp-create.json"
  TB_TIMEOUT=900 tb POST "/ns/$NS/infra/$infra/node/g1-1/dataDisk" \
    "$(jq -n --arg n "$infra-disk" --arg c "$conn" --argjson d "$disk" '{name:$n, connectionName:$c, diskSize:$d, diskType:"default", description:"cm-migration-test csp collect"}')" \
    | jq -c '{id, dataDiskIds}'
  ;;
register)
  csp=${args[0]:-}; [ -n "$csp" ] || die "csp 를 줍니다"
  map=$(cred_map "$csp")
  need_keys=$(hb GET "/csp/$csp" | jq -c '.credential_keys | sort')
  have_keys=$(jq -c 'keys | sort' <<<"$map")
  [ "$need_keys" = "$have_keys" ] || die "키 불일치: honeybee $need_keys, 매핑 $have_keys"
  # region_name 은 <region>/<zone>. VM 의 실제 zone 을 쓴다 (alibaba 는 connConfig assignedZone 과 다를 수 있고 azure 는 비어 있다)
  infra=$(state_get "HBC_${csp}_INFRA"); infra=${infra:-$NS-$csp}
  # infra 이름이 <ns>-<csp> 가 아니어도(예: 리전을 바꿔 다시 만든 hbcheck-aws2) 그 CSP 의 VM 을 찾는다
  node=$(tb GET "/ns/$NS/infra" | jq -c --arg i "$infra" --arg p "$csp" '
    [.infra[]? | .id as $id | .node[]? | select((.cspResourceId // "") != "" and .connectionConfig.providerName == $p)
     | {k: (if $id == $i then 0 else 1 end), n: .}] | sort_by(.k) | .[0].n // empty' || true)
  if [ -n "$node" ]; then
    rn=$(jq -r '.region.region + (if (.region.zone // "") != "" then "/" + .region.zone else "" end)' <<<"$node")
    rid=$(jq -r '.cspResourceId' <<<"$node")
  else
    region=$(region_of "$csp"); conn=$(conn_of "$csp" "$region")
    rn=$(tb GET "/connConfig/$conn" | jq -r '.regionZoneInfo | .assignedRegion + (if (.assignedZone // "") != "" then "/" + .assignedZone else "" end)')
    rid=""
    log "$NS/$infra VM 이 없어 region_name 을 connConfig $conn 값으로 채웠습니다 (dry-run 확인용)"
  fi
  if [ "$YES" != 1 ]; then
    build_body "$csp" "$rn" | jq -c '{name, type, provider_name, region_name,
      credential: [.credential[] | {key, value_nonempty: (.value | length > 0)}]}'
    log "연결: resource_type vm, resource_id ${rid:-<VM 없음>}"
    require_yes "honeybee 에 소스 그룹 $NS-$csp 등록"
  fi
  [ -n "$rid" ] || die "$NS/$infra 의 VM 이 없습니다 (create 먼저)"
  old=$(sg_of "$csp"); [ -z "$old" ] || die "소스 그룹 $NS-$csp 가 이미 있습니다 ($old). 그대로 collect 하거나 cleanup 뒤 다시 등록한다"
  build_body "$csp" "$rn" | hb POST /source_group stdin > "$RUN_DIR/hbc-$csp-sg.json"
  sg=$(jq -r '.id' "$RUN_DIR/hbc-$csp-sg.json"); state_set "HBC_${csp}_SG" "$sg"
  hb POST "/source_group/$sg/connection_info" stdin \
    < <(jq -n --arg n "$NS-$csp-vm" --arg r "$rid" '{name:$n, resource_type:"vm", resource_id:$r}') > "$RUN_DIR/hbc-$csp-conn.json"
  state_set "HBC_${csp}_CONN" "$(jq -r '.id' "$RUN_DIR/hbc-$csp-conn.json")"
  jq -c '{id, resource_id, connection_status, agent_status}' "$RUN_DIR/hbc-$csp-conn.json"
  ;;
collect)
  [ "${#args[@]}" -gt 0 ] || die "csp 를 줍니다"
  for csp in "${args[@]}"; do
    sg=$(sg_of "$csp"); [ -n "$sg" ] || { log "$csp: 소스 그룹 $NS-$csp 없음"; continue; }
    hb GET "/source_group/$sg/discover?resource_type=vm" > "$RUN_DIR/hbc-$csp-discover.json" \
      || { log "$csp: discover 실패 (위 응답)"; continue; }
    log "$csp: discover VM $(jq '.items | length' "$RUN_DIR/hbc-$csp-discover.json")대"
    # azure·ncp 는 스펙 조회 때문에 20~30초 걸린다
    s=$(date +%s)
    hb POST "/source_group/$sg/import/infra?count_objects=false" > "$RUN_DIR/hbc-$csp-import.json" || { log "$csp: import 실패"; continue; }
    log "$csp: import $(( $(date +%s) - s ))초, $(jq -c '[.[]? | {connection_id, status}]' "$RUN_DIR/hbc-$csp-import.json")"
  done
  ;;
judge)
  csps=("${args[@]}"); [ "${#csps[@]}" -gt 0 ] || read -r -a csps <<<"$HBC_CSPS"
  files=(); rm -f "$RUN_DIR/hbc-tb-infra-list.json"
  for csp in "${csps[@]}"; do
    hbf="$RUN_DIR/hbc-$csp-hb.json"; tbf="$RUN_DIR/hbc-$csp-tb.json"; rm -f "$hbf" "$tbf"
    sg=$(sg_of "$csp"); [ -n "$sg" ] || { files+=("$csp" - -); continue; }
    cj=$(conn_json_of "$sg"); [ -n "$cj" ] || { files+=("$csp" - -); continue; }
    cid=$(jq -r '.id' <<<"$cj"); rid=$(jq -r '.resource_id' <<<"$cj")
    hb GET "/source_group/$sg/connection_info/$cid/infra" | jq '.csp' > "$hbf" || echo null > "$hbf"
    found=$(tb_node_by_csp_id "$rid" || true)
    if [ -n "$found" ]; then
      n=$(jq -c '.node' <<<"$found")
      vnet=$(tb GET "/ns/$NS/resources/vNet/$(jq -r '.vNetId' <<<"$n")" 2>/dev/null || echo null)
      key=$(tb GET "/ns/$NS/resources/sshKey/$(jq -r '.sshKeyId' <<<"$n")" 2>/dev/null || echo null)
      sgs=$(for s in $(jq -r '.securityGroupIds[]?' <<<"$n"); do tb GET "/ns/$NS/resources/securityGroup/$s" 2>/dev/null || true; done | jq -s -c .)
      disks=$(for d in $(jq -r '.dataDiskIds[]?' <<<"$n"); do tb GET "/ns/$NS/resources/dataDisk/$d" 2>/dev/null || true; done | jq -s -c .)
      jq -n --argjson f "$found" --argjson v "$vnet" --argjson k "$key" --argjson s "$sgs" --argjson d "$disks" \
        '{infra:$f.infra, node:$f.node, vnet:$v, sshkey:$k, sgs:$s, disks:$d}' > "$tbf"
    fi
    files+=("$csp" "$hbf" "$tbf")
  done
  rc=0; python3 -I "$SKILL_DIR/scripts/csp-judge.py" "${files[@]}" || rc=$?
  log "근거: $RUN_DIR/hbc-<csp>-hb.json (honeybee csp 섹션), hbc-<csp>-tb.json (tumblebug 값)"
  exit "$rc"
  ;;
cleanup)
  sgs=$(hb GET /source_group | jq -r --arg p "$NS-" '.source_group[]? | select(.name | startswith($p)) | "\(.id) \(.name)"')
  disks=$(tb GET "/ns/$NS/resources/dataDisk?option=id" | jq -r '.output[]? // empty' || true)
  log "지울 것: honeybee 소스 그룹 [$(awk '{print $2}' <<<"$sgs" | tr '\n' ' ')], tumblebug $NS 의 infra 전부(terminate)·공용 자원, data disk [$(echo $disks)]"
  require_yes "honeybee 소스 그룹과 tumblebug $NS 정리"
  while read -r id name; do
    [ -n "$id" ] || continue
    hb DELETE "/source_group/$id" >/dev/null && log "소스 그룹 $name 삭제"
  done <<<"$sgs"
  "$SKILL_DIR/scripts/08-cleanup.sh" sources "$NS" --yes
  # terminate 뒤 남은 data disk (붙어 있던 것은 terminate 로 떨어진 뒤 지울 수 있다)
  for d in $(tb GET "/ns/$NS/resources/dataDisk?option=id" | jq -r '.output[]? // empty' || true); do
    log "삭제 $NS/dataDisk/$d"
    TB_TIMEOUT=600 tb DELETE "/ns/$NS/resources/dataDisk/$d" | jq -c '.message // .' || log "$d 삭제 실패. force 로 넘어가지 말고 원인을 본다"
  done
  for csp in $HBC_CSPS; do for k in INFRA SG CONN; do state_set "HBC_${csp}_$k" ""; done; done
  ;;
*) sed -n '2,15p' "$0"; exit 2 ;;
esac
