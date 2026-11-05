# 함정 (증상 → 원인 → 해결)

근거는 세션 id(앞 8자리)와 날짜다. 새로 겪은 것은 같은 형식으로 아래에 더한다.

## 플랫폼·초기화

| 증상 | 원인 | 해결 | 근거 |
|------|------|------|------|
| `! ./init/init.sh` 가 `Select option` 에서 `EOFError` | `!` 로 돌린 명령은 stdin 이 TTY 가 아니다 | 메뉴는 `printf 'c\n' \|` 로, 비밀번호는 `--key-file` 로 넘긴다 (`05-tb-init.sh`). encCredential.sh 처럼 입력을 받는 것은 별도 터미널에서 돌린다 | c841f99f 10-13 |
| init 이 `/credential/openbaoStatus` 에서 401 | init.py 는 `.env` 를 안 읽고, 계정이 없으면 `default/default` 를 쓴다 | `TB_API_USERNAME`/`TB_API_PASSWORD` 를 env 로 넘긴다 | c841f99f |
| `required variable SP_API_USERNAME is missing` | 옛 `.env` 와 새 `.env.example` 의 키 이름이 다르다 | `.env.example` 을 기준으로 다시 만든다 | c841f99f |
| tumblebug unhealthy, `role "tumblebug" does not exist` | 옛 postgres 데이터 디렉터리가 남아 있어 초기화를 건너뛴다 | 승인받고 그 데이터 디렉터리를 지운다. mayfly 면 `infra remove -s cb-tumblebug --clean-db` | c841f99f |
| init 은 exit 0 인데 GCP 스펙이 0건 | 서비스 계정에 `compute.machineTypes.list` 권한이 없다 (403). init 의 종료 코드로는 안 드러난다 | `05-tb-init.sh check` 의 CSP별 표를 본다. 권한을 준 뒤 `init.sh -y --load-assets-only --providers gcp`, 이어서 `--fetch-price-only` | 04257493 11-03 |
| `mayfly infra run -d` 가 health 대기 중 실패 | 컨테이너 기동이 느려 health 체크 시간을 넘긴다 | 한 번 더 `infra run -d` | Confluence 통합 테스트 0단계 |
| mayfly compose 의 tumblebug 을 0.12.x → 0.13.8 로 올린 뒤 env 오류 | 0.13 에서 env·볼륨이 바뀌었을 수 있다 (실측 없음) | cb-tumblebug v0.13.8 의 `docker-compose.yaml` 과 mayfly compose 의 tumblebug 블록을 diff 한다 | 추정 |
| `tumblebug-init` 이 OpenBao 불일치로 중단 | `VAULT_TOKEN` 이 컨테이너와 다르다 | `./mayfly setup openbao status` 로 진단 | mayfly docs/tumblebug-init-cmd.md |

## VM 생성·설치

| 증상 | 원인 | 해결 | 근거 |
|------|------|------|------|
| `/ns/default/mci` 404 | 0.13 에서 `mci` 가 `infra` 로 바뀌었다 | `/infra`, `infraDynamic` 을 쓴다 | e65f5bcd 11-04 |
| Review 에서 `creationViable:false` | 그 스펙의 과거 실패 이력 | 다른 스펙. `test.env` 의 vCPU·메모리나 `SRC_IMAGE_ID` 를 바꾼다 | e65f5bcd |
| 80 포트 응답 없음 | dynamic SG 는 22 만 연다 | `02-create-vms.sh` 가 source-vms.conf 의 포트를 연다 | e65f5bcd |
| `control/infra?action=reboot` 가 success 인데 재부팅 안 됨 | 확인 필요 | cmd 로 `sudo systemd-run --on-active=5 /bin/systemctl reboot`, `uptime -s` 로 확인 | e65f5bcd |
| AWS RHEL·Amazon Linux 에 `cb-user` 로 SSH 실패 | cloud-init 의 `useradd -G sudo` 가 wheel 만 있는 OS 에서 실패 | Ubuntu 를 쓴다 (`SRC_OS`) | 58f78ce7 11-04 |
| Azure Rocky 이미지 `requires Plan information` | cb-spider 가 plan 정보를 안 보낸다 | plan 없는 이미지 | 58f78ce7 |

## 수집·이관

| 증상 | 원인 | 해결 | 근거 |
|------|------|------|------|
| CSP 소스 그룹 API 가 404 이거나 type csp 를 모른다 | honeybee 릴리즈 이미지(v0.6.3 까지)에 CSP 수집이 없다 | `versions.env` 의 `HONEYBEE_BUILD_REF` 로 main 을 빌드한다 | 2026-11-05 소스 대조 |
| 이미 있던 소스 그룹이 401 | 저장된 AWS 키가 무효 | 새 소스 그룹을 만든다 | 81c32323 09-30 |
| SW 이관 `can't find matched target node` | beetle 새 버전은 라벨 `cm-source-machine-ids` 를 쓰고 옛 grasshopper 는 옛 키만 읽는다 | grasshopper `6ea9d7c` 이후 | a872372c (코드만 봄) |
| cicada xcom 경로 오류 | beetle 응답이 `{success, data}` 로 감싸져 있다 | `$.data.id`, `$.data.node[0].id` | 메모리 (실행 기록 없음) |
| KT 대상 추천 실패 | beetle 이 KT 를 지원 목록에서 뺐다 | 시험 표에 "미지원" 으로 적는다 | cm-beetle `infra.go:66-76` |

## 정리

| 증상 | 원인 | 해결 | 근거 |
|------|------|------|------|
| SG 삭제 409, vNet 삭제 500 "deletion unconfirmed" | Azure 에서 spider 의 `allsecuritygroup`/`allvpc` 가 500 | 해결 안 됨. force 로 넘어가지 말고 사용자에게 묻는다 | e65f5bcd 11-05 |
| vNet 삭제 500 "has 2 subnet(s)" | 서브넷이 남아 있다 | `?action=withSubnets` 또는 `DELETE /ns/{ns}/sharedResources` | e65f5bcd |
| terminate 뒤에도 CSP 목록에 VM 이 보인다 | AWS 는 종료된 VM 을 한동안 `terminated` 로 보여준다 | 잠시 뒤 다시 본다 | 04257493 10-07 |
| 공용 vNet 안에 남의 VM 이 있다 | 같은 계정을 여러 사람이 쓴다 | 지우기 직전에 vNet 안의 VM 을 확인하고, 남의 것이 있으면 vNet 은 남긴다 | 04257493 |
