#!/bin/bash
# 수집 확인용 MinIO 컨테이너. 9000 은 S3 API, 9001 은 콘솔. root 로 실행한다.
# 루트 비밀번호는 VM 안에서 무작위로 만들고 /opt/minio/root.env (600) 에만 둔다.
set -euo pipefail
mkdir -p /opt/minio/data
if [ ! -f /opt/minio/root.env ]; then
  ( umask 077; printf 'MINIO_ROOT_USER=minioadmin\nMINIO_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 16)" > /opt/minio/root.env )
fi
docker rm -f minio >/dev/null 2>&1 || true
docker run -d --name minio --restart unless-stopped -p 9000:9000 -p 9001:9001 \
  --env-file /opt/minio/root.env -v /opt/minio/data:/data \
  quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z server /data --console-address ":9001"
for _ in $(seq 1 30); do curl -fsS http://localhost:9000/minio/health/live >/dev/null && break; sleep 2; done
curl -fsS -o /dev/null -w 'minio live %{http_code}\n' http://localhost:9000/minio/health/live
