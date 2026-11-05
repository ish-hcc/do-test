#!/usr/bin/env bash
# tumblebug 이 쓸 credentials.yaml 을 찾고, 암호화 상태와 들어 있는 CSP 를 확인한다.
# 값은 출력하지 않는다. CSP 이름과 키 이름만 출력한다.
#
#   01-credentials.sh            찾기 + 상태 판정
#
# 종료 코드: 0 준비됨(.enc 있고 키 파일로 복호화됨)  4 사람이 할 일이 남음(안내 출력)  1 실패
set -euo pipefail
. "$(dirname "$0")/lib.sh"
need openssl python3

KEY_FILE="$RUN_DIR/cred.key"
PLAIN="$CRED_DIR/credentials.yaml"
ENC="$CRED_DIR/credentials.yaml.enc"

log "credentials 후보를 찾습니다 (내용은 읽지 않음)"
find "$HOME" -maxdepth 6 \( -name 'credentials.yaml' -o -name 'credentials.yaml.enc' \) \
  -not -path '*/node_modules/*' -not -path '*/template*' 2>/dev/null | while read -r f; do
  printf '  %s  (%s, %s)\n' "$f" "$(stat -c %y "$f" | cut -d. -f1)" "$(stat -c %s "$f")B"
done || true   # 권한 없는 디렉터리 때문에 find 가 1 로 끝나도 계속한다

if [ -f "$PLAIN" ]; then
  cat >&2 <<EOF
평문 $PLAIN 이 있습니다. 암호화가 먼저입니다.
encCredential.sh 는 비밀번호를 두 번 입력받는 대화형 스크립트라 '!' 로는 못 돌립니다. 별도 터미널에서:

  cd $TB_SRC && ./init/encCredential.sh

끝나면 $ENC 가 생기고 평문은 지워집니다. 그다음 이 스크립트를 다시 돌립니다.
EOF
  exit 4
fi
[ -f "$ENC" ] || die "$ENC 이 없습니다. $TB_SRC/init/genCredential.sh 로 만들고 CSP 정보를 채운 뒤 encCredential.sh 를 돌립니다"

if [ ! -s "$KEY_FILE" ]; then
  cat >&2 <<EOF
암호화된 $ENC 이 있습니다. init 을 입력 없이 돌리려면 복호화 비밀번호를 키 파일로 둡니다.
별도 터미널에서 (화면에 안 보이게 입력받아 600 권한 파일로 저장):

  ( umask 077; read -rs -p 'credential password: ' p; echo; printf '%s' "\$p" > $KEY_FILE )

그다음 이 스크립트를 다시 돌립니다. 키 파일은 git 밖($RUN_DIR)에 있고, 시험이 끝나면 지웁니다.
EOF
  exit 4
fi

if ! openssl enc -d -aes-256-cbc -salt -pbkdf2 -in "$ENC" -pass "file:$KEY_FILE" 2>/dev/null \
  | python3 -I -c '
import sys, yaml
d = yaml.safe_load(sys.stdin) or {}
holders = d.get("credentialholder", {})
for h, csps in holders.items():
    for csp, kv in (csps or {}).items():
        kv = kv or {}
        filled = [k for k, v in kv.items() if str(v or "").strip()]
        print(f"  holder={h} csp={csp} keys={len(filled)}/{len(kv)}")
'; then
  die "복호화 실패. 키 파일의 비밀번호가 맞는지 봅니다"
fi
log "복호화 확인. 위 목록에 TARGET_CSPS($TARGET_CSPS)가 모두 있고 keys 가 다 차 있어야 합니다"
state_set CRED_READY 1
