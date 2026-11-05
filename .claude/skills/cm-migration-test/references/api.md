# 단계별 API 와 검증 상태

출처 표기:
- **문서**: Confluence `CM_4차 년도/260710_CM_4차 통합 테스트.md` (17단계는 `260714_... ETRI 환경.md`)
- **소스**: 2026-11-05 로컬 소스
- **실행**: 지난 세션에서 실제로 돌린 기록

검증 상태는 이 skill 로 처음 돌린 뒤 실측 결과로 고친다. "검증 안 됨" 인 단계가 실패하면, 먼저 이 표의 요청 형식이 틀렸는지 의심한다.

## 플랫폼·초기화

| 단계 | 호출 | 근거 | 상태 |
|------|------|------|------|
| 플랫폼 기동 | `./mayfly infra run -d` (health 대기로 실패하면 한 번 더) | 문서 0단계, mayfly README | 검증 안 됨 |
| 상태 | `./mayfly infra info` | mayfly README | 검증 안 됨 |
| tumblebug init | `printf 'c\n' \| ./init/init.sh --key-file <키>` + `TUMBLEBUG_SERVER`, `TB_API_*` env | init.py:111-113, 153-200 | 단독 compose 에서 실행됨 (11-03, `MULTI_INIT_PWD` 로) |
| init 확인 | `GET /tumblebug/readyz` → `initialized:true`, `GET /tumblebug/connConfig` | 실행 | 실행됨 |

## Source VM (부트스트랩 tumblebug)

| 단계 | 호출 | 상태 |
|------|------|------|
| 스펙 고르기 | `POST /tumblebug/recommendSpec` (providerName·regionName·architecture·vCPU·memoryGiB 필터, cost 우선) | 실행됨 (2026-11-05, 8c/16G → c5a.2xlarge, 16c/32G → c5a.4xlarge) |
| 이미지 | `POST /tumblebug/ns/system/resources/searchImage` (`matchedSpecId`, `osType:"ubuntu 22.04"`) | 실행됨 |
| 검토·생성 | `infraDynamicReview` → `infraDynamic` (nodeGroup 하나, nodeGroupSize = VM 수) | 실행됨 (11-04, Azure 1대) |
| 포트 | `POST /ns/{ns}/resources/securityGroup/{sg}/rules` | 실행됨 (11-04) |
| 개인키 | `GET /ns/{ns}/resources/sshKey/{id}` 의 `privateKey`, 사용자 `nodeUserName` | 소스 (`model/ssh_key.go:51`) |

## cm-honeybee (8081, 인증 없음)

| 단계 | 호출 | 상태 |
|------|------|------|
| 1. 소스 그룹 (onprem) | `POST /honeybee/source_group` `{name, type:"onprem", connection_info:[{name, ip_address, ssh_port, user, private_key}]}` | 문서(password 방식), 소스 |
| 1. 소스 그룹 (csp) | 위 + `type:"csp", provider_name, region_name, credential:[{key,value}]`, 연결마다 `resource_type:"vm", resource_id:<인스턴스 id>` | 소스 (`model/sourceGroup.go:79`, `connectionInfo.go:104`). credential 키 이름은 `GET /honeybee/csp/aws` |
| 2. 인프라 수집 | `POST /honeybee/source_group/{sg}/import/infra` | 문서 |
| 3. refined 인프라 | `GET /honeybee/source_group/{sg}/infra/refined` → `.onpremiseInfraModel` | 문서 |
| 9. SW 수집 | `POST /honeybee/source_group/{sg}/import/software` | 문서 |
| 10. refined SW | `GET /honeybee/source_group/{sg}/software/refined` → `.sourceSoftwareModel` | 문서 |
| RDBMS | `GET /honeybee/source_group/{sg}/rdbms/refined` | 소스. 설치형은 SW 수집 결과에서 mysql·mariadb·postgresql 패키지와 컨테이너 이미지로 찾는다 (`controller/getRDBMSInstalled.go:79-93`) |

CSP 연결에 SSH 정보가 없으면 VM 안 agent 를 못 써서 CSP 메타데이터만 수집된다 (`controller/import.go:112`). 그래서 csp 방식에도 SSH 정보를 함께 넣는다.
CSP 수집과 RDBMS 수집은 v0.6.3 까지의 릴리즈에 없다. main 을 빌드한 이미지가 필요하다.

## 이관 (문서 4~17단계, `scripts/07-migrate.sh`)

| # | 호출 | 상태 |
|---|------|------|
| 4 | damselfly `POST /damselfly/onpremmodel` `{userId, userModelName, description, isInitUserModel:true, onpremiseInfraModel}` | 검증 안 됨 |
| 5 | beetle `POST /beetle/recommendation/infra?desiredCsp=&desiredRegion=&limit=1` `{desiredCspAndRegionPair:{csp,region}, onpremiseInfraModel}`. 응답은 `{success, data:[후보...]}` | 검증 안 됨. 응답 형식은 소스 (`cm-beetle model/response.go:35`) |
| 6 | damselfly `POST /damselfly/cloudmodel` `{..., cloudInfraModel:<후보>}` | 검증 안 됨 |
| 7 | cicada `POST /cicada/workflow`. task 는 `damselfly_task_get_cloud_infra_model` → `beetle_task_infra_migration` (`nsId=mig01`, `nameSeed`) | 검증 안 됨. `nameSeed` 를 query_params 로 넘기는 것은 이 skill 이 더한 것이다 (같은 ns 에 CSP 여러 개를 만들 때 이름이 겹치지 않게) |
| 8 | cicada `POST /cicada/workflow/{wfId}/run`, 진행은 `GET /cicada/workflow/{wfId}/runs` | 검증 안 됨 |
| 8' | beetle `GET /beetle/migration/ns/mig01/infra` | 검증 안 됨 |
| 11 | damselfly `POST /damselfly/softwaremodel/source` `{..., sourceSoftwareModel}` | 검증 안 됨 |
| 13 | grasshopper `POST /grasshopper/software/migration_list` `{sourceSoftwareModel}` → targetSoftwareModel | 검증 안 됨 |
| 14 | damselfly `POST /damselfly/softwaremodel/target` | 검증 안 됨. 본문 형식이 문서에 생략돼 있다 |
| 15-16 | cicada 워크플로: `damselfly_task_get_target_software_model` → `grasshopper_task_software_migration` (`nsId`, `infraId`) | 검증 안 됨 |
| 17 | grasshopper `GET /grasshopper/software/migrate/status` → `/status/{executionId}` 의 `target_mappings[].status` | 문서(ETRI 판). 예시 결과에 `finished with error` 가 있다 |

문서의 7단계 예시에 있던 `install_docker`(run_script) task 와 `trigger_email` task 는 넣지 않았다. 메일은 SMTP 설정이 필요하고, docker 설치는 SW 이관이 맡는다.

## 대상 CSP

| CSP | 리전 (test.env) | 비고 |
|-----|-----------------|------|
| aws | ap-northeast-2 | |
| azure | koreacentral | `standard_b2s` 는 과거 실패 이력 때문에 Review 단계에서 막힌 적이 있다 (11-04) |
| gcp | asia-northeast3 | 서비스 계정 actAs 권한 때문에 VM 생성이 막힌 적이 있다 (메모리) |
| alibaba | ap-northeast-2 | |
| tencent | ap-seoul | 2026-11-05 로컬 tumblebug 에 tencent 연결이 0개였다. credential 을 먼저 본다 |
| nhn | KR1 | |
| ncp | KR | |
| kt | KR1 | **cm-beetle 이 인프라 추천에서 빼 두었다** (`cm-beetle pkg/core/recommendation/infra.go:66-76`, `csp.KT: false`). 2026-11-05 로컬 tumblebug 에 kt 연결도 0개였다 |
