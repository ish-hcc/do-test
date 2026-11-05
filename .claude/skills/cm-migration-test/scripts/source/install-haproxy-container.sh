#!/bin/bash
# 수집 확인용 HAProxy 컨테이너. 80 은 프런트, 8404 는 통계 페이지. root 로 실행한다.
set -euo pipefail
mkdir -p /opt/haproxy
cat > /opt/haproxy/haproxy.cfg <<'EOF'
global
    log stdout format raw local0
defaults
    mode http
    timeout connect 5s
    timeout client  30s
    timeout server  30s
frontend http_in
    bind *:80
    default_backend local_static
frontend stats
    bind *:8404
    stats enable
    stats uri /stats
    stats refresh 10s
backend local_static
    http-request return status 200 content-type text/plain string "haproxy source vm for cm-honeybee collection test\n"
EOF
docker rm -f haproxy >/dev/null 2>&1 || true
docker run -d --name haproxy --restart unless-stopped -p 80:80 -p 8404:8404 \
  -v /opt/haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro haproxy:2.8
sleep 3
curl -fsS http://localhost/ && curl -fsS -o /dev/null -w 'stats %{http_code}\n' http://localhost:8404/stats
