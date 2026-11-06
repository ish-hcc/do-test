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
| 버킷 (csp) | 소스 그룹 csp 에 연결 `resource_type:"object_storage", resource_id:<CSP 버킷 이름>`. `import/infra` 로 수집하고 `?count_objects=false` 면 객체 개수·크기를 안 센다 | **검증됨** aws (2026-11-06, honeybee `407a71d`). azure·ibm 은 credentials 에 스토리지 키가 없어 못 함 |
| refined 버킷 | `GET /honeybee/source_group/{sg}/connection_info/{conn}/data/refined`, 그룹은 `/source_group/{sg}/data/refined` → `.sourceObjectStorageModel` (cm-beetle `storagemodel.SourceObjectStorageModel`) | **검증됨** aws (2026-11-06) |
| RDBMS | `GET /honeybee/source_group/{sg}/rdbms/refined` | 소스. 설치형은 SW 수집 결과에서 mysql·mariadb·postgresql 패키지와 컨테이너 이미지로 찾는다 (`controller/getRDBMSInstalled.go:79-93`) |

CSP 연결에 SSH 정보가 없으면 VM 안 agent 를 못 써서 CSP 메타데이터만 수집된다 (`controller/import.go:112`). 그래서 csp 방식에도 SSH 정보를 함께 넣는다.
CSP 수집과 RDBMS 수집은 v0.6.3 까지의 릴리즈에 없다. main 을 빌드한 이미지가 필요하다.

## cm-honeybee CSP 소스 그룹 수집 (`scripts/10-csp-collect.sh`)

| 단계 | 호출 | 상태 |
|------|------|------|
| VM | tumblebug `recommendSpec`(providerName·regionName·vCPU≥2·memoryGiB≥2·x86_64, cost) → `POST /ns/system/resources/searchImage` `{providerName, regionName, osType:"ubuntu 22.04", matchedSpecId, includeBasicImageOnly:true}` → `infraDynamicReview` → `infraDynamic` (nodeGroup `g1` 1대, `connectionName` 지정) | 실측 2026-11-06 (8 CSP) |
| data disk | tumblebug `POST /ns/{ns}/infra/{infra}/node/g1-1/dataDisk` `{name, connectionName, diskSize, diskType:"default"}` (만들고 붙임) | 실측 2026-11-06 |
| credential 원본 | tumblebug OpenBao `GET /v1/secret/data/csp/<csp>` (헤더 `X-Vault-Token`, 토큰은 tumblebug 컨테이너 env `VAULT_TOKEN`) → `.data.data` | 실측 2026-11-06 |
| honeybee 가 받는 키 | `GET /honeybee/csp/<csp>` → `credential_keys`. 이름은 대소문자 무관(`/csp/KT` = `/csp/kt`) | 실측 2026-11-06 |
| 소스 그룹 | `POST /honeybee/source_group` `{name, type:"csp", provider_name, region_name:"<region>/<zone>", credential:[{key,value}]}` | 실측 2026-11-06 |
| 연결 | `POST /honeybee/source_group/{sg}/connection_info` `{name, resource_type:"vm", resource_id:<CSP VM id>}` | 실측 2026-11-06 |
| discover | `GET /honeybee/source_group/{sg}/discover?resource_type=vm` → `.items[]{resource_id, name, region, extra}` | 실측 2026-11-06 |
| 수집 | `POST /honeybee/source_group/{sg}/import/infra?count_objects=false` | 실측 2026-11-06 |
| 결과 | `GET /honeybee/source_group/{sg}/connection_info/{conn}/infra` → `.csp` | 실측 2026-11-06 |

credential 매핑 (honeybee 키 ← tumblebug OpenBao 키). 스크립트의 `cred_map` 과 같다.

| csp | 매핑 | 확인 |
|-----|------|------|
| aws | `aws_access_key_id`←`AWS_ACCESS_KEY_ID`, `aws_secret_access_key`←`AWS_SECRET_ACCESS_KEY` | 수집 실측 |
| azure | `clientId`←`ARM_CLIENT_ID`, `clientSecret`←`ARM_CLIENT_SECRET`, `tenantId`←`ARM_TENANT_ID`, `subscriptionId`←`ARM_SUBSCRIPTION_ID` | 수집 실측 |
| gcp | `private_key`, `project_id`, `client_email` (이름 같음) | 수집 실측 |
| alibaba | `AccessKeyId`←`ALIBABA_CLOUD_ACCESS_KEY_ID`, `AccessKeySecret`←`ALIBABA_CLOUD_ACCESS_KEY_SECRET` | 수집 실측 |
| ibm | `ApiKey`←`IC_API_KEY` | 수집 실측 |
| ncp | `ncloud_access_key`←`NCLOUD_ACCESS_KEY`, `ncloud_secret_key`←`NCLOUD_SECRET_KEY` | 수집 실측 |
| nhn | `IdentityEndpoint`·`Username`·`Password`·`DomainName`·`TenantId` ← `NHN_*` | 수집 실측 |
| openstack | `IdentityEndpoint`←`OS_AUTH_URL`, `Username`·`Password`·`DomainName`·`ProjectID` ← `OS_*` | 수집 실측 |
| tencent | `SecretId`←`TENCENTCLOUD_SECRET_ID`, `SecretKey`←`TENCENTCLOUD_SECRET_KEY` | **dry-run 만** (2026-11-06) |
| kt | `IdentityEndpoint`·`Username`·`Password`·`DomainName`·`ProjectID` ← `KT_*`. tumblebug `kt` 는 `kt-driver`("KT Cloud (VPC)", cloudinfo.yaml) 라 honeybee `kt` 에 맞춘다. honeybee `ktclassic`(`API_Key`/`Secret_Key`)은 OpenBao 에 대응 키가 없다 | **dry-run 만** (2026-11-06) |

리전 기본값(`HBC_REGION_<csp>`): aws ap-northeast-1, azure koreacentral, gcp asia-northeast3, alibaba ap-northeast-2, ibm jp-tok, ncp kr, nhn kr1, openstack regionone, tencent ap-seoul(connConfig `tencent-ap-seoul`, ap-seoul-1), kt kr1(connConfig `kt-kr1`, KR1/DX-M1). tencent·kt 는 실측 안 함.

판정 기준 (`scripts/csp-judge.py`, honeybee `.csp` 와 tumblebug 값 대조). O = 값이 있고 tumblebug 과 맞음, △ = 일부만 있거나 다름, X = 비었음, - = 소스 그룹 없음.

| 행 | honeybee 필드 | O 조건 (tumblebug 쪽) |
|----|---------------|------------------------|
| 1 Image | `image`, `image_detail` | 둘 다 있고 `image`·`image_detail.id/name` 중 하나가 노드 `cspImageName`/`imageId` |
| 2 Spec | `vm_spec`, `vm_spec_detail.vcpus/memory_mib` | `vm_spec`=`cspSpecName`, vcpus=`spec.vCPU`, memory_mib 가 `spec.memoryGiB`×1024 의 ±10% |
| 3 VPC | `network.vpc.name/cidr` | name 이 vNet `cspResourceName`/`cspResourceId`, cidr=`cidrBlock`. gcp·ibm·openstack 은 cidr 자리에 "... does not support IPv4_CIDR" 가 와서 O 로 본다 |
| 4 Subnet | `network.subnet`, `vpc.subnets[].cidr` | subnet 이 vNet 의 subnet 중 하나, tumblebug subnet cidr 가 전부 honeybee 쪽에 있음 |
| 5 SG | `network.security_groups[].rules` | 모든 SG 에 rules 가 있고 SG 이름이 tumblebug SG 중 하나 |
| 6 KeyPair | `keypair.name` | sshKey `cspResourceName`/`cspResourceId` 또는 노드 `cspSshKeyId` |
| 7 VM | `name`, `id`, `public_ip`/`private_ip`, `status` | 다 있고 id·IP 가 노드 값과 같음 |
| 8 Disk | `root_disk.size`, `data_disk_details[].size` | root > 0, data disk 크기 목록이 tumblebug dataDisk `diskSize` 목록과 같음 |

## 이관 (문서 4~17단계, `scripts/07-migrate.sh`)

| # | 호출 | 상태 |
|---|------|------|
| 4 | damselfly `POST /damselfly/onpremmodel` `{userId, userModelName, description, isInitUserModel:true, onpremiseInfraModel}` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공) |
| 5 | beetle `POST /beetle/recommendation/infra?desiredCsp=&desiredRegion=&limit=1` `{desiredCspAndRegionPair:{csp,region}, onpremiseInfraModel}`. 응답은 `{success, data:[후보...]}` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공). 4대 모두 matched |
| 6 | damselfly `POST /damselfly/cloudmodel` `{..., cloudInfraModel:<후보>}` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공) |
| 7 | cicada `POST /cicada/workflow`. task 는 `damselfly_task_get_cloud_infra_model` → `beetle_task_infra_migration` (`nsId=mig01`, `nameSeed`) | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공). `nameSeed` 를 query_params 로 넘기는 것은 이 skill 이 더한 것이다 (같은 ns 에 CSP 여러 개를 만들 때 이름이 겹치지 않게) |
| 8 | cicada `POST /cicada/workflow/{wfId}/run`, 진행은 `GET /cicada/workflow/{wfId}/runs` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공). 워크플로를 만든 직후 run 하면 500 `dag_id is not exist` 가 날 수 있어 `run_wf` 가 다시 한다 |
| 8' | beetle `GET /beetle/migration/ns/mig01/infra` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공) |
| 11 | damselfly `POST /damselfly/softwaremodel/source` `{..., sourceSoftwareModel}` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공) |
| 13 | grasshopper `POST /grasshopper/software/migration_list` `{sourceSoftwareModel}` → targetSoftwareModel | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공) |
| 14 | damselfly `POST /damselfly/softwaremodel/target` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공). 본문 형식은 `07-migrate.sh` 가 만드는 것 |
| 15-16 | cicada 워크플로: `damselfly_task_get_target_software_model` → `grasshopper_task_software_migration` (`nsId`, `infraId`) | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공) |
| 17 | grasshopper `GET /grasshopper/software/migrate/status` → `/status/{executionId}` 의 `target_mappings[].status` | 2026-11-06 실측 (aws gcp nhn ncp 대상 8조합 성공). `finished` 라도 실제로 설치 안 된 경우가 있어 `07-migrate.sh verify` 로 VM 안을 본다 |

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
