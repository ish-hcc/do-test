#!/usr/bin/env bash
# cm-honeybee 에 Source VM 을 소스 그룹으로 등록하고 수집한 뒤 결과를 판정한다.
#
#   06-honeybee.sh register <ns> onprem   SSH 접속 정보로 등록 (type onprem)
#   06-honeybee.sh register <ns> csp      cb-spider lib 방식 (type csp, provider/region/credential + resource_id)
#       소스 그룹을 둘 만든다: <ns> (source-vms.conf 의 migrate VM) 와 <ns>-collect (collect VM).
#       수집만 할 VM 이 이관 그룹에 섞이면 beetle 이 그 VM 까지 대상으로 추천하기 때문이다.
#   06-honeybee.sh collect  <sgId>        import/infra, import/software
#   06-honeybee.sh check    <sgId>        refined infra·software·rdbms 를 노드별로 요약하고 기대값과 대조
#
# 소스 그룹 id 는 state 에 SG_<ns>, SG_<ns>_collect 로 남는다. 요청 본문(개인키·credential 포함)은 파일로 남기지 않는다.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need python3 openssl
ip=$(state_get CM_PUBLIC_IP); [ -n "$ip" ] || die "CM VM 이 없습니다"
HB="http://$ip:8081/honeybee"
hb() { # METHOD PATH [stdin 본문 여부]
  local m=$1 p=$2 out code; out=$(mktemp)
  if [ "${3:-}" = stdin ]; then
    code=$(curl -sS -m "${HB_TIMEOUT:-1800}" -o "$out" -w '%{http_code}' -X "$m" -H 'Content-Type: application/json' "$HB$p" --data-binary @-)
  else
    code=$(curl -sS -m "${HB_TIMEOUT:-1800}" -o "$out" -w '%{http_code}' -X "$m" "$HB$p")
  fi
  if [ "${code:0:1}" != 2 ]; then log "$m $p -> HTTP $code"; head -c 3000 "$out" >&2; echo >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}

case "${1:-}" in
register)
  ns=${2:?ns}; kind=${3:?onprem|csp}
  use_boot_tb
  infra_json="$RUN_DIR/$ns-$SRC_INFRA.live.json"
  tb GET "/ns/$ns/infra/$SRC_INFRA" > "$infra_json"
  key=$(node_ssh_key "$ns" "$SRC_INFRA")
  cred_cmd=":"
  if [ "$kind" = csp ]; then
    log "honeybee 가 요구하는 $SRC_CSP credential 키: $(hb GET "/csp/$SRC_CSP" | jq -c '[.. | .key? // empty]' 2>/dev/null || echo '?')"
    cred_cmd="openssl enc -d -aes-256-cbc -salt -pbkdf2 -in $CRED_DIR/credentials.yaml.enc -pass file:$RUN_DIR/cred.key"
  fi
  for purpose in migrate collect; do
  sgname=$ns; [ "$purpose" = collect ] && sgname="$ns-collect"
  # 본문은 python 이 만들어 바로 curl stdin 으로 넘긴다 (argv·파일에 비밀이 안 남음)
  $cred_cmd | python3 -I "$SKILL_DIR/scripts/hb-body.py" "$kind" "$ns" "$infra_json" "$key" "$SKILL_DIR/config/source-vms.conf" "$SRC_CSP" "$SRC_REGION" "$SRC_NODEGROUP" "$purpose" "$sgname" \
    | hb POST /source_group stdin > "$RUN_DIR/sg-$sgname.json"
  sg=$(jq -r '.id' "$RUN_DIR/sg-$sgname.json")
  state_set "SG_${sgname//-/_}" "$sg"
  jq '{id, name, type, provider_name, region_name, connection_info_status_count}' "$RUN_DIR/sg-$sgname.json"
  done
  ;;
collect)
  sg=${2:?sgId}
  log "import/infra"; hb POST "/source_group/$sg/import/infra" > "$RUN_DIR/import-infra-$sg.json"
  log "import/software"; hb POST "/source_group/$sg/import/software" > "$RUN_DIR/import-software-$sg.json"
  log "수집 응답: $RUN_DIR/import-*-$sg.json"
  ;;
check)
  sg=${2:?sgId}
  hb GET "/source_group/$sg/connection_info" > "$RUN_DIR/conn-$sg.json"
  hb GET "/source_group/$sg/infra/refined" > "$RUN_DIR/infra-refined-$sg.json"
  hb GET "/source_group/$sg/software/refined" > "$RUN_DIR/software-refined-$sg.json"
  hb GET "/source_group/$sg/rdbms/refined" > "$RUN_DIR/rdbms-refined-$sg.json" || log "rdbms/refined 실패 (위 응답 참고)"
  python3 -I - "$RUN_DIR" "$sg" "$SKILL_DIR/config/source-vms.conf" <<'PY'
import sys, json, os
run, sg, conf = sys.argv[1:4]
def load(n):
    p = os.path.join(run, f"{n}-{sg}.json")
    return json.load(open(p)) if os.path.exists(p) else None
conns = load("conn") or {}
conns = conns.get("connection_info", conns) if isinstance(conns, dict) else conns
sw = json.dumps(load("software-refined") or {}).lower()
rd = json.dumps(load("rdbms-refined") or {}).lower()
expect = {  # 이름 -> 수집 결과 어딘가에 나와야 하는 낱말
    "vm1-legacy": ["httpd", "tomcat"], "vm2-wp-nginx": ["nginx", "mariadb", "nfs"],
    "vm3-wp-apache": ["apache2", "mariadb", "nfs"], "vm4-container": ["mariadb", "tomcat"],
    "haproxy": ["haproxy"], "minio": ["minio"], "rdbms-mariadb": ["mariadb"], "rdbms-mysql": ["mysql"],
}
print(f"{'연결':28} {'접속':8} {'agent':8} 판정")
for c in conns or []:
    name = c.get("name", "")
    short = name.split("-", 1)[1] if "-" in name else name
    words = expect.get(short, [])
    miss = [w for w in words if w not in sw]
    print(f"{name:28} {c.get('connection_status','?'):8} {c.get('agent_status','?'):8} "
          + ("OK" if not miss else f"소프트웨어에 없음: {','.join(miss)}"))
for eng in ["mariadb", "mysql"]:
    print(f"rdbms refined 에 {eng}: {'있음' if eng in rd else '없음'}")
PY
  ;;
*) sed -n '2,10p' "$0"; exit 2 ;;
esac
