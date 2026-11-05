#!/usr/bin/env bash
# CSP 오브젝트 스토리지(버킷) 상세 수집 시험. cm-honeybee 의 type csp 소스 그룹에
# resource_type object_storage 커넥션을 두고 import/infra 로 수집한 뒤 data/refined 를 기대값과 대조한다.
#
#   09-objectstorage.sh plan    <csp> [region]          만들 것과 기대값을 보인다
#   09-objectstorage.sh run     <csp> [region] --yes    버킷 생성 → 버전 관리·CORS·객체 3개 → honeybee 등록·수집 → 판정
#   09-objectstorage.sh check   <csp>                   이미 수집한 결과를 다시 판정
#   09-objectstorage.sh cleanup <csp> --yes             객체 버전 → 버킷 → honeybee 소스 그룹 순으로 지움
#
# 버킷은 CM VM 의 tumblebug(초기화된 쪽)으로 만든다. 상태는 state 에 OS_<csp>_* 로 남는다.
# 기대값: versioningEnabled, corsEnabled 와 규칙 1개(origin https://example.com, GET·PUT, header *, expose ETag, 300초),
#         encryptionEnabled(AWS 는 기본 암호화), isPublic 없음, objectCount 3, totalSizeBytes 7148.
#
# 2026-11-06 실측: aws 통과. azure·ibm 은 cb-spider 가 버킷 생성부터 "accessKey is empty" 로 거부한다
# (credentials 에 Azure StorageAccountName/Key, IBM S3AccessKey/S3SecretKey(HMAC) 가 없음). references/pitfalls.md 참고.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need python3 openssl

cmd=${1:-}; csp=${2:-}; region=${3:-}
[ "$region" = --yes ] && region=""
[ -n "$csp" ] || { sed -n '2,15p' "$0"; exit 2; }
eval "region=\${region:-\${TARGET_REGION_$csp:-}}"
[ -n "$region" ] || die "$csp 리전을 정하지 못했습니다 (TARGET_REGION_$csp)"
conn="$csp-$region"
tag=$(date +%m%d%H%M)
osid=$(state_get "OS_${csp}_ID"); osid=${osid:-hbos-$csp-$tag}

ip=$(state_get CM_PUBLIC_IP); [ -n "$ip" ] || die "CM VM 이 없습니다"
HB="http://$ip:8081/honeybee"
hb() { # METHOD PATH [stdin]
  local m=$1 p=$2 out code; out=$(mktemp)
  if [ "${3:-}" = stdin ]; then
    code=$(curl -sS -m 600 -o "$out" -w '%{http_code}' -X "$m" -H 'Content-Type: application/json' "$HB$p" --data-binary @-)
  else
    code=$(curl -sS -m 600 -o "$out" -w '%{http_code}' -X "$m" "$HB$p")
  fi
  if [ "${code:0:1}" != 2 ]; then log "$m $p -> HTTP $code"; head -c 2000 "$out" >&2; echo >&2; rm -f "$out"; return 1; fi
  cat "$out"; rm -f "$out"
}
use_cm_tb
OSP="/ns/default/resources/objectStorage"

check() {
  local sg=$1 c=$2
  hb GET "/source_group/$sg/connection_info/$c/data/refined" > "$RUN_DIR/os-refined-$csp.json"
  hb GET "/source_group/$sg/connection_info/$c/data" > "$RUN_DIR/os-data-$csp.json"
  python3 -I - "$RUN_DIR/os-refined-$csp.json" "$RUN_DIR/os-data-$csp.json" <<'PY'
import sys, json
m = json.load(open(sys.argv[1]))["sourceObjectStorageModel"]
p = m["sourceObjectStorages"][0]
d = json.load(open(sys.argv[2]))
rule = (p.get("corsRule") or [{}])[0]
checks = [
    ("versioningEnabled", p.get("versioningEnabled") is True),
    ("corsEnabled", p.get("corsEnabled") is True),
    ("corsRule", rule.get("allowedOrigin") == ["https://example.com"] and rule.get("allowedMethod") == ["GET", "PUT"]
                 and rule.get("allowedHeader") == ["*"] and rule.get("exposeHeader") == ["ETag"] and rule.get("maxAgeSeconds") == 300),
    ("encryptionEnabled", p.get("encryptionEnabled") is True),
    ("isPublic 없음", not p.get("isPublic")),
    ("objectCount 3", p.get("objectCount") == 3),
    ("totalSizeBytes 7148", p.get("totalSizeBytes") == 7148),
    ("data 버킷 이름 채워짐", bool((d.get("buckets") or [{}])[0].get("name"))),
    ("data errors 없음", not d.get("errors")),
]
print("sourceCloud:", m.get("sourceCloud"))
for name, ok in checks:
    print(f"  {'OK  ' if ok else 'FAIL'} {name}")
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
}

case "$cmd" in
plan)
  log "만들 것: tumblebug objectStorage $osid ($conn), 객체 3개(100·2048·5000 바이트), honeybee 소스 그룹 hbos-$csp"
  log "지우는 것: cleanup 이 객체 버전 → 버킷 → 소스 그룹 순으로 지운다"
  ;;
run)
  require_yes "버킷 $osid 를 $conn 에 만들고 honeybee 로 수집"
  log "버킷 생성 $osid ($conn)"
  out=$(tb PUT "$OSP" "{\"bucketName\":\"$osid\",\"connectionName\":\"$conn\",\"description\":\"cm-migration-test bucket detail\"}")
  bucket=$(jq -r '.cspResourceName' <<<"$out")
  state_set "OS_${csp}_ID" "$osid"; state_set "OS_${csp}_BUCKET" "$bucket"
  log "CSP 버킷 이름 $bucket"
  tb PUT "$OSP/$osid/versioning" '{"status":"Enabled"}' >/dev/null
  tb PUT "$OSP/$osid/cors" '{"corsRule":[{"allowedOrigin":["https://example.com"],"allowedMethod":["GET","PUT"],"allowedHeader":["*"],"exposeHeader":["ETag"],"maxAgeSeconds":300}]}' >/dev/null
  # 객체 키에 '/' 를 넣으면 tumblebug 경로가 안 맞는다 (pitfalls.md)
  for spec in a.txt:100 b.bin:2048 c.bin:5000; do
    k=${spec%%:*}; n=${spec#*:}
    url=$(tb POST "$OSP/$osid/object/$k/presignedUrl?operation=upload&expires=600" | jq -r '.presignedURL')
    code=$(head -c "$n" /dev/urandom | curl -sS -m 120 -o /dev/null -w '%{http_code}' -X PUT --data-binary @- "$url")
    [ "$code" = 200 ] || die "$k 업로드 실패 (HTTP $code)"
  done
  log "honeybee 소스 그룹 hbos-$csp 등록"
  openssl enc -d -aes-256-cbc -salt -pbkdf2 -in "$CRED_DIR/credentials.yaml.enc" -pass "file:$RUN_DIR/cred.key" \
    | python3 -I -c '
import sys, json, yaml
csp, region, bucket = sys.argv[1:4]
kv = yaml.safe_load(sys.stdin)["credentialholder"]["admin"][csp]
json.dump({"name": f"hbos-{csp}", "description": "cm-migration-test bucket detail", "type": "csp",
           "provider_name": csp, "region_name": region,
           "credential": [{"key": k, "value": str(v)} for k, v in kv.items() if str(v or "").strip()],
           "connection_info": [{"name": f"hbos-{csp}-bucket", "resource_type": "object_storage", "resource_id": bucket}]}, sys.stdout)' \
      "$csp" "$region" "$bucket" \
    | hb POST /source_group stdin > "$RUN_DIR/os-sg-$csp.json"
  sg=$(jq -r '.id' "$RUN_DIR/os-sg-$csp.json"); state_set "OS_${csp}_SG" "$sg"
  c=$(hb GET "/source_group/$sg/connection_info" | jq -r '.connection_info[0].id'); state_set "OS_${csp}_CONN" "$c"
  log "import/infra"
  st=$(hb POST "/source_group/$sg/connection_info/$c/import/infra" | jq -r '.status')
  [ "$st" = success ] || die "import/infra 상태가 $st (success 여야 함)"
  check "$sg" "$c"
  ;;
check)
  check "$(state_get "OS_${csp}_SG")" "$(state_get "OS_${csp}_CONN")"
  ;;
cleanup)
  require_yes "버킷 $osid 와 소스 그룹 정리"
  sg=$(state_get "OS_${csp}_SG")
  [ -n "$sg" ] && hb DELETE "/source_group/$sg" >/dev/null && log "소스 그룹 $sg 삭제"
  if tb GET "$OSP/$osid" >/dev/null 2>&1; then
    tb GET "$OSP/$osid/versions" | jq -r '((.version // []) + (.deleteMarker // []))[] | "\(.key) \(.versionId)"' \
      | while read -r k vid; do tb DELETE "$OSP/$osid/versions/$k?versionId=$vid" >/dev/null; done
    tb DELETE "$OSP/$osid" >/dev/null && log "버킷 $osid 삭제"
  fi
  left=$(tb GET "$OSP" | jq -r --arg id "$osid" '[.objectStorage[] | select(.id == $id)] | length')
  [ "$left" = 0 ] || die "tumblebug 에 $osid 가 남았습니다"
  for k in ID BUCKET SG CONN; do state_set "OS_${csp}_$k" ""; done
  ;;
*) sed -n '2,15p' "$0"; exit 2 ;;
esac
