#!/bin/bash
# 수집 확인용 MinIO 컨테이너. 9000 은 S3 API, 9001 은 콘솔. root 로 실행한다.
# 루트 비밀번호는 VM 안에서 무작위로 만들고 /opt/minio/root.env (600) 에만 둔다.
#
# MinIO 는 커뮤니티 배포물을 내렸다 (2026-11-06 확인: quay.io 401, Docker Hub minio/minio 없음,
# dl.min.io 410). 그래서 GitHub 의 같은 릴리즈 태그를 VM 안에서 빌드해 이미지로 만든다 (8 vCPU 에서 몇 분).
set -euo pipefail
TAG=RELEASE.2025-04-22T22-12-26Z
IMAGE=minio-local:$TAG
mkdir -p /opt/minio/data /opt/minio/build
if [ ! -f /opt/minio/root.env ]; then
  ( umask 077; printf 'MINIO_ROOT_USER=minioadmin\nMINIO_ROOT_PASSWORD=%s\n' "$(openssl rand -hex 16)" > /opt/minio/root.env )
fi
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  cat > /opt/minio/build/Dockerfile <<EOF
FROM golang:1.24-bookworm AS build
RUN git clone -q --depth 1 --branch $TAG https://github.com/minio/minio.git /src
WORKDIR /src
RUN CGO_ENABLED=0 go build -trimpath -o /minio .
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq ca-certificates curl >/dev/null && rm -rf /var/lib/apt/lists/*
COPY --from=build /minio /usr/bin/minio
EXPOSE 9000 9001
ENTRYPOINT ["/usr/bin/minio"]
EOF
  docker build -q -t "$IMAGE" /opt/minio/build
fi
docker rm -f minio >/dev/null 2>&1 || true
docker run -d --name minio --restart unless-stopped -p 9000:9000 -p 9001:9001 \
  --env-file /opt/minio/root.env -v /opt/minio/data:/data \
  "$IMAGE" server /data --console-address ":9001"
for _ in $(seq 1 30); do curl -fsS http://localhost:9000/minio/health/live >/dev/null && break; sleep 2; done
curl -fsS -o /dev/null -w 'minio live %{http_code}\n' http://localhost:9000/minio/health/live
