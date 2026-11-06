---
name: cm-migration-test
description: cm-mayfly 로 Cloud-Migrator 통합 플랫폼을 AWS VM 에 띄우고 cb-tumblebug 을 초기화한 뒤, AWS 에 만든 Source VM 을 cm-honeybee 로 수집해 여러 CSP 로 마이그레이션하는 통합 시험을 끝까지 돌리고 정리한다. TRIGGER - "마이그레이션 테스트", "통합 테스트 돌려", "mayfly 로 구축하고 테스트", "tumblebug 초기화하고 이관 시험", "honeybee 수집 확인", "honeybee CSP 수집 시험", "CSP 소스 그룹 수집 판정", 4차년도 통합 테스트 재현. SKIP - 모듈 하나의 코드 수정·리뷰(그 repo 작업), 이미 떠 있는 노드에 이미지 반영만 할 때(deploy-verify), 기능이 동작하는지만 볼 때(verify-impl).
---

# cm-migration-test

credentials 확인 → CM VM → 플랫폼 기동 → tumblebug init → Source VM → 설치 → 수집 → 이관 → 판정 → 정리.

시험 방법은 Confluence `CM_4차 년도/260710_CM_4차 통합 테스트.md` 의 0~16단계와 ETRI 판의 17단계다.
개념은 `references/concepts.md`, 단계별 API 와 검증 상태는 `references/api.md`, 함정은 `references/pitfalls.md`.

## 절대 규칙

1. **과금이 시작되거나 되돌리기 어려운 단계는 직전에 묻는다.** 스크립트는 `--yes` 없이 부르면 계획만 보이고 종료 코드 3 으로 멈춘다.
   승인은 대화에서 받고 그 단계에만 `--yes` 를 붙인다. 해당 단계: VM 생성(02), 플랫폼 기동(04 run), 대상 인프라 생성(07 의 8단계), 정리(08).
   물을 때 Review 가 낸 스펙·대수·시간당 비용을 같이 보인다.
2. **정리는 terminate 만 쓴다.** force 는 CSP 에 과금되는 VM 을 남길 수 있다. terminate 가 실패하면 force 로 넘어가지 말고 원인을 보고 묻는다.
3. **남은 자원은 기준선 대비로 판정한다.** 같은 CSP 계정을 다른 사람도 쓴다 (2026-11-05 AWS 서울에 남의 VM 6대).
   VM 을 만들기 전에 `08-cleanup.sh baseline` 을 뜬다. tumblebug 이 관리하지 않는 자원(`onCspOnly`)은 지우지 않는다.
4. **비밀값을 화면·파일·argv 에 남기지 않는다.**
   - credential 복호화 비밀번호는 `.claude/run/cred.key`(600) 에만 둔다. API 계정은 `.claude/run/state.env`(600) 에만 둔다.
   - 개인키는 `.claude/run/*.pem`(600) 에만 둔다.
   - `.claude/run/` 은 `.git/info/exclude` 에 들어 있다. 시험이 끝나면 `cred.key` 와 `*.pem` 을 지운다.
5. **입력을 받는 스크립트는 사용자에게 별도 터미널로 넘긴다.** encCredential.sh, 키 파일 만들기가 해당한다. `!` 로 돌리면 EOF 로 끝난다.
6. **"검증 안 됨" 단계의 실패는 요청 형식부터 의심한다.** `references/api.md` 의 상태를 실측 결과로 고치고, 새 함정은 `pitfalls.md` 에 더한다.

## 설정

| 파일 | 무엇 |
|------|------|
| `config/versions.env` | 모듈별 이미지 태그. cb-tumblebug 0.13.8·cb-spider 0.13.20 은 고정, cm-* 와 mc-terrarium 은 edge |
| `config/test.env` | Source VM 스펙 (기본 8 vCPU / 16 GiB), CM VM 스펙 (기본 16 vCPU / 32 GiB), 리전, 네임스페이스 이름, 대상 CSP·리전, init 옵션, CSP 수집 시험(`HBC_*`) |
| `config/source-vms.conf` | Source VM 구성. 한 줄이 nodeGroup 의 노드 하나 (`g1-<idx>`) |

환경변수로 덮어쓸 수 있다: `SRC_VCPU=4 SRC_MEM_GIB=8 scripts/02-create-vms.sh source onpremise`.

Source VM 구성 (`source-vms.conf`):

| 노드 | 이름 | 용도 | 설치 |
|------|------|------|------|
| g1-1 | vm1-legacy | 이관 | Apache·Tomcat 바이너리 설치 (legacy) |
| g1-2 | vm2-wp-nginx | 이관 | WordPress + nginx + MariaDB (package), NFS |
| g1-3 | vm3-wp-apache | 이관 | WordPress + Apache + MariaDB (package), NFS |
| g1-4 | vm4-container | 이관 | MariaDB·Tomcat 컨테이너 |
| g1-5 | haproxy | 수집만 | docker + HAProxy 컨테이너 |
| g1-6 | minio | 수집만 | docker + MinIO 컨테이너 |
| g1-7 | rdbms-mariadb | 수집만 | MariaDB (OS 패키지) |
| g1-8 | rdbms-mysql | 수집만 | MySQL (OS 패키지) |

같은 구성을 두 네임스페이스에 만든다.
- `onpremise` 는 honeybee 에 SSH 방식(type onprem)으로 등록한다.
- `csp` 는 cb-spider lib 방식(type csp)으로 등록한다.

네임스페이스마다 소스 그룹을 둘로 나눈다. `<ns>` 에는 이관 대상 VM 을, `<ns>-collect` 에는 수집만 할 VM 을 넣는다.
수집만 할 VM 이 이관 그룹에 섞이면 beetle 이 그 VM 까지 대상으로 추천하기 때문이다.

## 실행 그래프

스크립트는 `scripts/` 아래에 있고, 실행 기록과 응답은 `.claude/run/` 에 남는다.

| # | 단계 | 명령 | 통과 조건 | 승인 |
|---|------|------|-----------|------|
| 0 | 준비 확인 | `docker ps` 로 부트스트랩 tumblebug(로컬 v0.13.8) healthy, 설정 3개 확인 | readyz `initialized:true` | |
| 1 | credentials 찾기 | `01-credentials.sh` | 종료 0. 목록에 TARGET_CSPS 가 다 있고 keys 가 다 참 | |
| 1′ | (사람) 암호화·키 파일 | 01 이 종료 4 로 안내한 명령을 **별도 터미널에서** | 01 재실행이 0 | |
| 2 | 기준선 | `08-cleanup.sh baseline boot aws` | 파일 생성 | |
| 3 | CM VM | `02-create-vms.sh cm` → 승인 → `--yes` | Running, 공인 IP 가 state 에 | **물음** |
| 4 | 플랫폼 준비 | `04-cm-platform.sh prepare` | 버전 반영 표, `csp 수집 경로 있음`, 빈 값 남은 키가 SMTP·VAULT_TOKEN 뿐 | |
| 5 | 플랫폼 기동 | `04-cm-platform.sh run --yes` → `info` | 모든 컨테이너 healthy, readyz 가 200 | **물음** |
| 6 | tumblebug init | `05-tb-init.sh run` (백그라운드, 10~40분) | `initialized:true`, CSP별 connConfig 가 검증됨으로 차 있음 | |
| 7 | 대상 기준선 | `08-cleanup.sh baseline cm <TARGET_CSPS>` | 파일 생성 | |
| 8 | Source VM | `02-create-vms.sh source onpremise`, `... source csp` → 승인 → `--yes` | 노드 8대씩 Running | **물음** |
| 9 | 설치 | `03-install-sources.sh <ns>` → `03-install-sources.sh <ns> check` | 모든 포트 열림, 컨테이너 VM 에 컨테이너 보임 | |
| 10 | honeybee 등록 | `06-honeybee.sh register onpremise onprem`, `06-honeybee.sh register csp csp` | `count_connection_success` 와 `count_agent_success` 가 연결 수와 같음 | |
| 11 | 수집 | 소스 그룹 4개 각각 `06-honeybee.sh collect <sg>` | 200 | |
| 12 | 수집 판정 | `06-honeybee.sh check <sg>` | 연결마다 OK. collect 그룹은 haproxy·minio 컨테이너와 rdbms 의 mariadb·mysql 이 나옴 | |
| 12′ | 버킷 수집 | `09-objectstorage.sh run aws --yes` → `09-objectstorage.sh cleanup aws --yes` | 판정 줄이 전부 OK, cleanup 뒤 tumblebug 목록에 버킷 없음 | **물음** |
| 13 | 이관 | `07-migrate.sh <ns> <csp>` → 8단계 앞에서 멈춤 → 승인 → `--yes` | 17단계 상태가 소프트웨어마다 성공 | **물음** (CSP마다) |
| 14 | 이관 확인 | 대상 VM 에서 서비스 응답 (80·8080·3306, NFS export) | 소스와 같은 응답 | |
| 15 | 정리 | `08-cleanup.sh targets --yes`, `sources onpremise --yes`, `sources csp --yes` | 종료 0. 1 이면 끝에 낸 "실패"·"남음" 목록을 보고 원인부터 본다 | **물음** |
| 16 | 잔여 확인 | `08-cleanup.sh residual cm <TARGET_CSPS>`, `residual boot aws` | 증가 0 | |
| 17 | CM 정리 | `08-cleanup.sh cm --yes`, 다시 `residual boot aws`. `cred.key`·`*.pem` 삭제 | 증가 0 | **물음** |

**한 번에 다 돌리지 않아도 된다.** 각 스크립트는 state 에 남긴 값을 이어 받는다.
07 은 단계별 응답 파일이 있으면 그 단계를 건너뛰므로, 실패한 단계부터 다시 돈다.

**이관 순서는 CSP 하나로 끝까지 가 본 뒤 넓힌다.** 먼저 `onpremise` → `aws` 하나로 4~17단계를 끝내고 api.md 를 고친다.
그다음 나머지 CSP 와 `csp` 네임스페이스로 넓힌다. 처음부터 16개 조합(네임스페이스 2 × CSP 8)을 돌리면 같은 실패가 16번 난다.

**KT 는 cm-beetle 이 인프라 추천에서 빼 두었다.** 07 이 경고를 내고, 실패하면 결과 표에 "미지원" 으로 적는다.

## CSP 소스 그룹 수집 시험 (`10-csp-collect.sh`)

통합 시험과 따로 돈다. cm-honeybee 의 type csp 소스 그룹이 CSP 마다 VM 메타데이터를 다 채우는지 보고,
"Cloud-Migrator 세부 목표" 의 CM-Honeybee 1~8행(Image, Spec, VPC, Subnet, SG, KeyPair, VM, Disk)을 O/△/X 로 판정한다.
CM VM 없이 로컬에서 돈다: VM 은 부트스트랩 tumblebug(`BOOT_TB_URL`)이 만들고, honeybee 는 `HBC_HB_URL`(기본 로컬 8081)이다.
honeybee 는 `bfe9cbe` 이상이어야 한다. 그 전 빌드는 aws·alibaba·ncp 에서 VPC 등이 비어 X 가 나온다 (`references/pitfalls.md`).

언제 쓰나: honeybee 의 CSP 수집 코드나 cb-spider 버전을 바꾼 뒤, 또는 세부 목표 표를 채울 근거가 필요할 때.

| # | 명령 | 통과 조건 | 승인 |
|---|------|-----------|------|
| 1 | `10-csp-collect.sh create <csp>` → 승인 → `--yes` (CSP 마다) | Review `creationViable:true`, 노드 Running, data disk 붙음 | **물음** |
| 2 | `10-csp-collect.sh register <csp>` (dry-run) → 승인 → `--yes` | dry-run 의 credential key 가 전부 `value_nonempty:true`, 연결 `connection_status:success` | **물음** |
| 3 | `10-csp-collect.sh collect <csp...>` | discover 에 그 VM 이 나오고 import 가 success | |
| 4 | `10-csp-collect.sh judge [csp...]` | 표의 칸이 전부 O, `tb 대조` 가 O | |
| 5 | `10-csp-collect.sh cleanup` (계획) → 승인 → `--yes` | 계획에 지울 infra·vNet·SG·sshKey·dataDisk·소스 그룹이 다 나옴. 실행은 종료 0 (소스 그룹 삭제 → data disk 분리 → `08-cleanup.sh sources <ns>` → data disk 삭제). 1 이면 state 를 안 비우므로 원인을 고친 뒤 다시 cleanup | **물음** |

- **judge 는 상태를 바꾸지 않는다.** honeybee 의 `connection_info/{conn}/infra` 의 `csp` 섹션과, tumblebug 이 아는 같은 VM 의 값(vNet·sshKey·SG·dataDisk 리소스)을 대조한다.
  소스 그룹은 state(`HBC_<csp>_SG`)가 없으면 이름 `<HBC_NS>-<csp>` 로 찾으므로, 손으로 등록한 그룹도 판정한다. 판정 기준은 `references/api.md`.
- **credential 은 tumblebug OpenBao(`secret/data/csp/<csp>`)에서 읽어 honeybee 키로 바꿔 파이프로 넘긴다.** 값은 argv·파일·화면에 안 남는다.
  dry-run 은 key 이름과 값이 비었는지만 보인다. 매핑 표는 스크립트의 `cred_map` 이고, honeybee 의 `GET /honeybee/csp/<csp>` 와 키가 다르면 멈춘다.
- region_name 은 `<region>/<zone>` 이고 zone 은 **VM 의 실제 zone** 을 쓴다 (connConfig 의 assignedZone 이 아님).
- `cleanup` 은 `<HBC_NS>` 네임스페이스의 infra 를 **전부** terminate 한다. 그 ns 에 다른 사람이 만든 infra 가 없는지 계획 출력에서 본다.
- 실측(2026-11-06, honeybee `bfe9cbe`): aws(ap-northeast-1) azure gcp alibaba ibm ncp nhn openstack 8개가 1~8행 전부 O.
  **tencent·kt 는 아직 실측 안 했다.** 매핑과 dry-run(key 전부 non-empty)까지만 확인했다. tencent 는 계정 잔액 부족으로 VM 생성부터 실패했다.

## 결과 보고

판정마다 근거 파일(`.claude/run/...`)을 적는다.

| 항목 | onpremise (SSH) | csp (cb-spider lib) |
|------|-----------------|---------------------|
| 연결·agent 성공 수 | | |
| 인프라 수집 | | |
| SW 수집 (vm1~4) | | |
| 컨테이너 수집 (haproxy, minio) | | |
| RDBMS 수집 (mariadb, mysql) | | |
| 버킷 상세 수집 (aws) | - | 12′ 판정 |
| 이관 aws / azure / gcp / alibaba / tencent / nhn / ncp / kt | 칸마다 성공·실패·미지원과 실패 단계 | |
| 잔여 자원 증가 | | |

마지막에 `references/api.md` 에서 "검증 안 됨" 이 남은 줄을 적는다.

## 하지 말 것

- `--yes` 를 승인 없이 붙이기, 앞 단계 승인을 다음 단계에 쓰기
- terminate 실패 뒤 force 로 지우기, `onCspOnly` 자원 지우기
- 비밀번호·키를 명령줄 인자나 출력에 넣기
- 대화형 스크립트를 `!` 로 돌리라고 안내하기
- 응답 형식을 확인하지 않고 "이관 성공" 이라 하기. 17단계 상태와 대상 VM 의 실제 응답까지 본다
