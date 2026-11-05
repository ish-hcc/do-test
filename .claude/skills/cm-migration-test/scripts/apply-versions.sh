#!/usr/bin/env bash
# versions.env 의 태그를 cm-mayfly docker-compose.yaml 의 이미지 줄에 반영한다.
# 주석 처리된 image 줄(# image: ...:edge)은 건드리지 않는다.
#
#   apply-versions.sh <docker-compose.yaml> <versions.env> [--dry-run]
#
# 바뀌는 줄을 "이전 -> 이후" 로 출력한다. --dry-run 이면 파일을 바꾸지 않는다.
# lib.sh 에 기대지 않는다 (CM VM 에 이 파일만 복사해서 돌린다).
set -euo pipefail
compose=${1:?docker-compose.yaml 경로}; versions=${2:?versions.env 경로}; dry=${3:-}
[ -f "$compose" ] && [ -f "$versions" ] || { echo "파일 없음" >&2; exit 1; }

tmp=$(mktemp); cp "$compose" "$tmp"
changed=0
while IFS= read -r line; do
  name=$(sed -E 's#^\s*image: cloudbaristaorg/([a-z0-9-]+):.*#\1#' <<<"$line")
  cur=$(sed -E 's#^\s*image: cloudbaristaorg/[a-z0-9-]+:([^ ]+).*#\1#' <<<"$line")
  key=$(tr 'a-z-' 'A-Z_' <<<"$name")
  want=$(sed -n "s/^$key=//p" "$versions" | tail -1 | sed -E 's/\s*#.*$//; s/^"//; s/"$//')
  if [ -z "$want" ]; then printf '  %-22s %s (versions.env 에 없음, 그대로)\n' "$name" "$cur"; continue; fi
  if [ "$want" = "$cur" ]; then printf '  %-22s %s (같음)\n' "$name" "$cur"; continue; fi
  sed -i -E "s#^(\s*image: cloudbaristaorg/$name):[^ ]+#\1:$want#" "$tmp"
  printf '  %-22s %s -> %s\n' "$name" "$cur" "$want"; changed=$((changed+1))
done < <(grep -E '^\s*image: cloudbaristaorg/' "$compose")

if [ "$dry" = "--dry-run" ]; then rm -f "$tmp"; echo "dry-run: ${changed}줄 바뀔 예정"; exit 0; fi
mv "$tmp" "$compose"
echo "${changed}줄 바꿈: $compose"
