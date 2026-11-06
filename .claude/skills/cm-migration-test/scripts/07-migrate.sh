#!/usr/bin/env bash
# Confluence "CM_4차 통합 테스트" 4~17단계를 소스 그룹 하나, 대상 CSP 하나에 대해 돈다.
#
#   07-migrate.sh <ns> <csp> [--yes]      전 단계. --yes 없으면 대상 VM 을 만드는 8단계 앞에서 멈춘다
#   07-migrate.sh <ns> <csp> status        17단계(grasshopper 상태)만 다시 본다
#   07-migrate.sh <ns> <csp> verify        대상 VM 에 SSH 로 들어가 서비스 응답을 본다 (14단계).
#       대상 보안 그룹에 서비스 포트가 옮겨지지 않아 밖에서는 안 보인다 (2026-11-06 실측: 22 만 열림)
#
# 단계별 응답은 RUN_DIR/mig-<ns>-<csp>/NN-*.json 에 남고, 다시 돌리면 이미 있는 단계는 건너뛴다.
# 앞 단계를 다시 하려면 그 파일과 뒤 파일을 지운다.
# 2026-11-05 작성 시점에 4~17단계는 실행한 기록이 없다 (references/api.md 의 "검증 안 됨").
set -euo pipefail
. "$(dirname "$0")/lib.sh"
ns=${1:?ns}; csp=${2:?csp}; sub=${3:-all}
ip=$(state_get CM_PUBLIC_IP); [ -n "$ip" ] || die "CM VM 이 없습니다"
sg=$(state_get "SG_${ns//-/_}"); [ -n "$sg" ] || die "SG_$ns 가 state 에 없습니다 (06-honeybee.sh register 먼저)"
rvar="TARGET_REGION_$csp"; region=${!rvar:-}; [ -n "$region" ] || die "$rvar 가 test.env 에 없습니다"
case "$csp" in kt|openstack) log "주의: cm-beetle 은 $csp 를 인프라 추천 대상에서 빼 두었다 (cm-beetle pkg/core/recommendation/infra.go supportedInfraCSPs). 실패가 예상된다";; esac
D="$RUN_DIR/mig-$ns-$csp"; mkdir -p "$D"
seed="${ns}-${csp}"
U_BEETLE="$(state_get CM_BEETLE_API_USERNAME):$(state_get CM_BEETLE_API_PASSWORD)"
U_DAMSEL="$(state_get CM_DAMSELFLY_API_USERNAME):$(state_get CM_DAMSELFLY_API_PASSWORD)"

# api PORT METHOD PATH OUTFILE [BODYFILE] [user:pass]
api() {
  local port=$1 m=$2 p=$3 out=$4 body=${5:-} auth=${6:-} code args=()
  [ -n "$body" ] && args+=(-H 'Content-Type: application/json' --data-binary "@$body")
  code=$(curl -sS -m "${API_TIMEOUT:-1800}" -o "$out.tmp" -w '%{http_code}' -X "$m" --config <(curl_user_cfg "$auth") "${args[@]}" "http://$ip:$port$p") || code=000
  if [ "${code:0:1}" != 2 ]; then log "$m :$port$p -> HTTP $code"; head -c 3000 "$out.tmp" >&2; echo >&2; mv "$out.tmp" "$out.err"; return 1; fi
  mv "$out.tmp" "$out"; log "$m :$port$p -> $code ($(basename "$out"))"
}
# 워크플로를 만들자마자 실행하면 Airflow 가 DAG 파일을 아직 못 읽어 "dag_id is not exist" 로 500 이 난다
# (2026-11-06 실측: 15 직후 16 이 실패, 30초 뒤 다시 하면 성공). 그 응답일 때만 15초 간격으로 10번까지 다시 한다.
run_wf() { # wf outfile
  local i
  for i in $(seq 1 10); do
    api 8083 POST "/cicada/workflow/$1/run" "$2" && return 0
    grep -q 'dag_id is not exist' "$2.err" 2>/dev/null || return 1
    log "DAG 가 아직 Airflow 에 없음, 15초 뒤 다시 ($i/10)"; sleep 15
  done
  return 1
}
step() { [ -s "$D/$1" ] && { log "$1 있음, 건너뜀"; return 1; }; return 0; }
jid() { jq -r '.id // .data.id // .ID // empty' "$1"; }

if [ "$sub" = verify ]; then
  use_cm_tb
  infra=$(cat "$D/08-infra-id" 2>/dev/null) || die "08-infra-id 가 없습니다 (8단계 먼저)"
  vkey=$(node_ssh_key "$MIG_NS" "$infra")
  tb GET "/ns/$MIG_NS/infra/$infra" | jq -r '.node[] | select(.status=="Running") | "\(.id) \(.publicIP) \(.nodeUserName)"' \
    | while read -r id nip nuser; do
      printf '%-50s ' "$id"
      # shellcheck disable=SC2016
      ssh_node "$vkey" "$nuser" "$nip" 'for p in 80 8080; do printf "%s:%s " $p $(curl -s -o /dev/null -m 5 -w %{http_code} http://localhost:$p/); done;
        for s in apache2 nginx mariadb nfs-server tomcat; do [ "$(systemctl is-active $s 2>/dev/null)" = active ] && printf "%s " $s; done;
        sudo docker ps --format "{{.Names}}" 2>/dev/null | tr "\n" " "; echo' 2>&1 | tail -1 || echo "접속 실패"
    done
  exit 0
fi
if [ "$sub" = status ]; then
  api 8084 GET "/grasshopper/software/migrate/status" "$D/17-status-list.json"
  infra=$(cat "$D/08-infra-id" 2>/dev/null || echo "")
  eid=$(jq -r --arg i "$infra" '[.. | objects | select(has("execution_id")) | select(($i=="") or (tostring|contains($i)))] | last | .execution_id // empty' "$D/17-status-list.json")
  [ -n "$eid" ] || die "실행 id 를 못 찾았습니다. $D/17-status-list.json 을 봅니다"
  api 8084 GET "/grasshopper/software/migrate/status/$eid" "$D/17-status.json"
  jq -r '.target_mappings[]? | "\(.target.node_id)\t\(.status)\t" + ([.software_migration_status_list[]? | "\(.software_name)=\(.status)"] | join(" "))' "$D/17-status.json"
  exit 0
fi

# 3. Refined infra
step 03-infra-refined.json && api 8081 GET "/honeybee/source_group/$sg/infra/refined" "$D/03-infra-refined.json"
# 4. Source infra 저장 (damselfly)
if step 04-onpremmodel.json; then
  jq --arg n "$seed-src-infra" '{userId:"admin", userModelName:$n, description:$n, isInitUserModel:true, onpremiseInfraModel:.onpremiseInfraModel}' "$D/03-infra-refined.json" > "$D/04.req"
  api 8088 POST /damselfly/onpremmodel "$D/04-onpremmodel.json" "$D/04.req" "$U_DAMSEL"
fi
# 5. 추천 (beetle)
if step 05-recommend.json; then
  jq --arg c "$csp" --arg r "$region" '{desiredCspAndRegionPair:{csp:$c, region:$r}, onpremiseInfraModel:.onpremiseInfraModel}' "$D/03-infra-refined.json" > "$D/05.req"
  api 8056 POST "/beetle/recommendation/infra?desiredCsp=$csp&desiredRegion=$region&limit=1" "$D/05-recommend.json" "$D/05.req" "$U_BEETLE"
fi
jq -e '.data[0]' "$D/05-recommend.json" >/dev/null || die "추천 후보가 없습니다 ($D/05-recommend.json)"
jq -r '.data[0] | "추천: \(.status) | \(.description)"' "$D/05-recommend.json"
# 6. Target infra 저장 (damselfly)
if step 06-cloudmodel.json; then
  jq --arg n "$seed-tgt-infra" '{userId:"admin", userModelName:$n, description:$n, isInitUserModel:true, isTargetModel:true, cloudInfraModel:.data[0]}' "$D/05-recommend.json" > "$D/06.req"
  api 8088 POST /damselfly/cloudmodel "$D/06-cloudmodel.json" "$D/06.req" "$U_DAMSEL"
fi
cm_id=$(jid "$D/06-cloudmodel.json"); [ -n "$cm_id" ] || die "cloudmodel id 를 못 읽었습니다 ($D/06-cloudmodel.json)"
# 7. Infra migration workflow 생성 (cicada). 문서 예시의 install_docker·메일 task 는 뺐다
if step 07-wf-infra.json; then
  jq -n --arg n "migrate_infra_${seed//-/_}_$(date +%m%d%H%M)" --arg id "$cm_id" --arg ns "$MIG_NS" --arg seed "$seed" '{
    name:$n, data:{description:"cm-migration-test infra", task_groups:[{name:"migrate_infra", description:"migrate infra", tasks:[
      {name:"infra_recommend_get", task_component:"damselfly_task_get_cloud_infra_model", spec:{path_params:{id:$id}}, dependencies:[]},
      {name:"infra_migration", task_component:"beetle_task_infra_migration",
       spec:{path_params:{nsId:$ns}, query_params:{nameSeed:$seed}, request_body:"infra_recommend_get.cloudInfraModel"}, dependencies:["infra_recommend_get"]}
    ]}]}}' > "$D/07.req"
  api 8083 POST /cicada/workflow "$D/07-wf-infra.json" "$D/07.req"
fi
wf_infra=$(jid "$D/07-wf-infra.json")

wait_run() { # wfId label -> 마지막 run 상태가 success/failed 가 될 때까지 (최대 60분)
  local wf=$1 label=$2 st
  for _ in $(seq 1 120); do
    api 8083 GET "/cicada/workflow/$wf/runs" "$D/$label-runs.json" >/dev/null 2>&1 || true
    st=$(jq -r '[.[]? // .data[]?] | last | (.state // .status // "unknown")' "$D/$label-runs.json" 2>/dev/null || echo unknown)
    case "$st" in success|failed) log "$label 워크플로 $st"; [ "$st" = success ]; return;; esac
    sleep 30
  done
  log "$label 워크플로가 60분 안에 안 끝났습니다 (마지막 상태 $st)"; return 1
}

# 8. 실행 -> 대상 VM 생성 (과금 시작)
if step 08-run-infra.json; then
  require_yes "$csp/$region 에 대상 인프라 생성 (cicada 워크플로 $wf_infra 실행)"
  run_wf "$wf_infra" "$D/08-run-infra.json"
  wait_run "$wf_infra" 08 || die "인프라 이관 워크플로 실패. airflow(:8080) 의 task 로그를 봅니다"
fi
api 8056 GET "/beetle/migration/ns/$MIG_NS/infra" "$D/08-infra-list.json" "" "$U_BEETLE"
infra_id=$(jq -r --arg s "$seed" '[.. | objects | select(has("id")) | .id | select(startswith($s))] | first // empty' "$D/08-infra-list.json")
[ -n "$infra_id" ] || die "nameSeed '$seed' 로 시작하는 infra 를 못 찾았습니다 ($D/08-infra-list.json)"
echo "$infra_id" > "$D/08-infra-id"
log "대상 infra: $MIG_NS/$infra_id"

# 9~10. software 수집과 refined (06-honeybee.sh collect 를 했으면 이미 들어 있다)
step 10-software-refined.json && api 8081 GET "/honeybee/source_group/$sg/software/refined" "$D/10-software-refined.json"
# 11. Source software 저장 (damselfly)
if step 11-sw-source.json; then
  jq --arg n "$seed-src-sw" '{userId:"admin", userModelName:$n, description:$n, isInitUserModel:true, sourceSoftwareModel:.sourceSoftwareModel}' "$D/10-software-refined.json" > "$D/11.req"
  api 8088 POST /damselfly/softwaremodel/source "$D/11-sw-source.json" "$D/11.req" "$U_DAMSEL"
fi
# 13. Target software model (grasshopper)
if step 13-migration-list.json; then
  jq '{sourceSoftwareModel:.sourceSoftwareModel}' "$D/10-software-refined.json" > "$D/13.req"
  api 8084 POST /grasshopper/software/migration_list "$D/13-migration-list.json" "$D/13.req"
fi
# 14. Target software 저장 (damselfly)
if step 14-sw-target.json; then
  jq --arg n "$seed-tgt-sw" '{userId:"admin", userModelName:$n, description:$n, isInitUserModel:true} + .' "$D/13-migration-list.json" > "$D/14.req"
  api 8088 POST /damselfly/softwaremodel/target "$D/14-sw-target.json" "$D/14.req" "$U_DAMSEL"
fi
tsw_id=$(jid "$D/14-sw-target.json"); [ -n "$tsw_id" ] || die "target software model id 를 못 읽었습니다"
# 15. Software migration workflow 생성
if step 15-wf-sw.json; then
  jq -n --arg n "migrate_sw_${seed//-/_}_$(date +%m%d%H%M)" --arg id "$tsw_id" --arg ns "$MIG_NS" --arg inf "$infra_id" '{
    name:$n, data:{description:"cm-migration-test software", task_groups:[{name:"migrate_software", description:"migrate software", tasks:[
      {name:"get_target_software_model", task_component:"damselfly_task_get_target_software_model", spec:{path_params:{id:$id}}, dependencies:[]},
      {name:"run_software_migration", task_component:"grasshopper_task_software_migration",
       spec:{request_body:"get_target_software_model", query_params:{nsId:$ns, infraId:$inf}}, dependencies:["get_target_software_model"]}
    ]}]}}' > "$D/15.req"
  api 8083 POST /cicada/workflow "$D/15-wf-sw.json" "$D/15.req"
fi
wf_sw=$(jid "$D/15-wf-sw.json")
# 16. 실행
if step 16-run-sw.json; then
  run_wf "$wf_sw" "$D/16-run-sw.json"
  wait_run "$wf_sw" 16 || log "SW 이관 워크플로가 success 가 아닙니다. 17단계 상태로 어느 소프트웨어가 실패했는지 봅니다"
fi
# 17. 상태
"$0" "$ns" "$csp" status
