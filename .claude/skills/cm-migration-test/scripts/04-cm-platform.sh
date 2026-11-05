#!/usr/bin/env bash
# CM VM 에 cm-mayfly 로 Cloud-Migrator 통합 플랫폼을 띄운다.
#
#   04-cm-platform.sh prepare          docker 설치, cm-mayfly clone, .env 생성, 버전 반영, honeybee 빌드 (기동 안 함)
#   04-cm-platform.sh run [--yes]      ./mayfly infra run -d 후 infra info
#   04-cm-platform.sh info             ./mayfly infra info 와 각 모듈 readyz
#
# .env 의 빈 비밀번호는 CM VM 안에서 무작위로 채운다. API 계정은 로컬 state(600)로만 가져오고 출력하지 않는다.
set -euo pipefail
. "$(dirname "$0")/lib.sh"
use_boot_tb
mode=${1:?prepare | run | info}

ip=$(state_get CM_PUBLIC_IP); [ -n "$ip" ] || die "CM VM 이 없습니다. 02-create-vms.sh cm 먼저"
key=$(node_ssh_key "$CM_NS" "$CM_INFRA")
user=$(tb GET "/ns/$CM_NS/infra/$CM_INFRA" | jq -r '.node[0].nodeUserName')
CM_HOME=${CM_HOME/\/home\/cb-user//home/$user}
r() { ssh_node "$key" "$user" "$ip" "$@"; }
r_script() { # stdin 으로 스크립트를 넘긴다 (ssh -n 을 못 쓰는 자리)
  timeout "${SSH_TIMEOUT:-3600}" ssh -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 -o LogLevel=ERROR "$user@$ip" "$@"
}

pull_creds() { # CM 의 .env 에서 API 계정을 state 로 (화면에 안 냄)
  local envs; envs=$(r "cat $CM_HOME/conf/docker/.env")
  for k in TB_API_USERNAME TB_API_PASSWORD BEETLE_API_USERNAME BEETLE_API_PASSWORD DAMSELFLY_API_USERNAME DAMSELFLY_API_PASSWORD SPIDER_USERNAME SPIDER_PASSWORD; do
    state_set "CM_${k}" "$(sed -n "s/^$k=//p" <<<"$envs" | tail -1)"
  done
  state_set CM_TB_USER "$(state_get CM_TB_API_USERNAME)"; state_set CM_TB_PASS "$(state_get CM_TB_API_PASSWORD)"
  log "CM API 계정을 $STATE 에 저장 (값은 출력 안 함)"
}

case "$mode" in
prepare)
  log "docker 설치"
  r_script 'sudo bash -s' < "$SKILL_DIR/scripts/source/install-docker.sh"
  log "cm-mayfly clone ($MAYFLY_REF)"
  r "test -d $CM_HOME/.git || git clone -q $MAYFLY_REPO $CM_HOME; cd $CM_HOME && git fetch -q --all --tags && git checkout -q $MAYFLY_REF && (git pull -q --ff-only 2>/dev/null || true) && git log --oneline -1"
  log ".env 생성 (빈 *_PASSWORD/*_SECRET 를 VM 안에서 무작위로 채움)"
  r "cd $CM_HOME/conf/docker && if [ ! -f .env ]; then cp .env.example .env; fi && chmod 600 .env && \
     for k in \$(grep -E '^[A-Z_]*(PASSWORD|SECRET)=\$' .env | cut -d= -f1); do case \$k in SMTP_*) continue;; esac; \
       sed -i \"s|^\$k=\$|\$k=\$(openssl rand -hex 16)|\" .env; done; \
     echo \"빈 값 남은 키: \$(grep -E '^[A-Z_]+=\$' .env | cut -d= -f1 | tr '\n' ' ')\""
  log "버전 반영"
  scp -q -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
    "$SKILL_DIR/config/versions.env" "$SKILL_DIR/scripts/apply-versions.sh" "$user@$ip:/tmp/"
  r "bash /tmp/apply-versions.sh $CM_HOME/conf/docker/docker-compose.yaml /tmp/versions.env"
  if [ -n "${HONEYBEE_BUILD_REF:-}" ]; then
    log "cm-honeybee $HONEYBEE_BUILD_REF 빌드 -> cloudbaristaorg/cm-honeybee:$CM_HONEYBEE"
    r "test -d ~/cm-honeybee/.git || git clone -q $HONEYBEE_REPO ~/cm-honeybee; cd ~/cm-honeybee && git fetch -q --all && git checkout -q $HONEYBEE_BUILD_REF && (git pull -q --ff-only 2>/dev/null || true) && \
       echo \"honeybee 소스 \$(git log --oneline -1)\" && test -f server/pkg/api/rest/route/csp.go && echo 'csp 수집 경로 있음' && \
       sudo docker build -q -t cloudbaristaorg/cm-honeybee:$CM_HONEYBEE server"
  fi
  pull_creds
  ;;
run)
  require_yes "CM VM($ip) 에서 mayfly infra run -d"
  log "mayfly infra run -d (첫 기동은 이미지 pull 때문에 오래 걸린다)"
  r "cd $CM_HOME && sudo ./mayfly infra run -d" | tail -40 || log "infra run 이 0 이 아닌 코드로 끝남. 문서 경험상 health 대기 때문에 한 번 더 돌리면 되는 경우가 있다"
  r "cd $CM_HOME && sudo ./mayfly infra info" | tail -40
  ;;
info)
  r "cd $CM_HOME && sudo ./mayfly infra info" | tail -40
  for u in "1323/tumblebug/readyz" "1024/spider/readyz" "8081/honeybee/readyz" "8056/beetle/readyz" "8088/damselfly/readyz" "8083/cicada/readyz" "8084/grasshopper/readyz"; do
    printf '  %-28s %s\n' "$u" "$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "http://$ip:$u" 2>&1)"
  done
  ;;
*) die "모드는 prepare | run | info" ;;
esac
