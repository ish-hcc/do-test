# cb-spider · cb-tumblebug 개념

사용자 메모(2026-11-05)를 cb-tumblebug v0.13.8 소스와 대조해 정리했다. 줄 번호는 그 태그 기준이다.

## cb-spider
- CSP 마다 SDK 와 API 가 다른 것을 하나의 API 로 추상화한다. VM·VPC·SG 같은 **자원 하나** 단위로 다룬다.
- **Connection** = CSP 하나 + 리전 하나 (+ 존). 이름은 `aws-ap-northeast-2` 처럼 `<csp>-<region>` 이다.
  tumblebug `GET /tumblebug/connConfig` 의 `configName` 으로 보인다.
- Admin Web: compose 의 cb-spider `ADMINWEB=ON` 으로 켠다.
  - cb-tumblebug v0.13.8 단독 compose 는 기본이 `OFF` 이고 1024 포트가 주석 처리돼 있다. 호스트에서 열려면 `ports` 주석도 풀어야 한다.
  - cm-mayfly compose 도 기본 `OFF` 이고(`conf/docker/docker-compose.yaml:68`) 1024 는 공개돼 있다.
  - 접속 계정은 `.env` 의 spider 계정이다.

## cb-tumblebug
cb-spider 위에서 여러 VM·클러스터를 **묶음**으로 다룬다. 문서: `docs/feature_guide/infra-resource-model-and-lifecycle-management.md`

| VM 묶음 | K8s 묶음 |
|---------|----------|
| Namespace (가장 큰 단위, Infra 여러 개) | Namespace |
| Infra (NodeGroup 여러 개) | Infra (Cluster 여러 개) |
| NodeGroup (특정 CSP 의 특정 리전, 같은 spec·image) | Cluster (K8s 하나) |
| Node (VM 하나, 이름 `<nodeGroup>-<번호>` 예: `g1-1`) | NodeGroup → Node |

VM 묶음과 K8s 클러스터는 같은 Namespace 안에 함께 있을 수 있다.

### 동적 생성 API
| API | 소스 위치 | 하는 일 |
|-----|-----------|---------|
| `POST /ns/{nsId}/infraDynamicReview` | `server.go:415` | 만들기 전에 검토만 한다. `creationViable`, `overallStatus` |
| `POST /ns/{nsId}/infraDynamic` | `server.go:414` | VM 묶음 생성 |
| `POST /ns/{nsId}/k8sClusterDynamic` | `server.go:595` | K8s 묶음 생성 |

dynamic API 는 vNet(VPC)·SecurityGroup·SSHKey 를 같이 만든다. dynamic 을 안 쓰면 셋을 직접 만들어야 한다.
dynamic 이 만든 SG 는 22 만 연다. 다른 포트는 `POST /ns/{nsId}/resources/securityGroup/{sgId}/rules` 로 더한다.

### 삭제 옵션
`DELETE /ns/{nsId}/infra/{infraId}?option=...` (`infra/manage_info.go:271`)

| 옵션 | 뜻 |
|------|----|
| `terminate` (기본, 권장) | CSP 노드를 종료한 뒤 기록을 지운다. CSP 에서 실제로 지워진다 |
| `force` | CSP 종료를 확인하지 않고 tumblebug 기록만 지운다. 과금되는 VM 이 CSP 에 남을 수 있고, 남은 VM 때문에 vNet·SG 삭제도 막힌다 |

그래서 정리는 항상 terminate 로 하고, 끝나면 cb-spider 기준으로 남은 자원이 있는지 확인한다.
- `POST /tumblebug/inspectResources` (`server.go:336`) 가 연결 하나, 자원 종류 하나에 대해 tumblebug·spider·CSP 수를 대조한다.
- 같은 계정을 다른 사람도 쓴다. 2026-11-05 에 AWS 서울에는 tumblebug 이 관리하지 않는 VM 이 6대 있었다(`onCspOnly: 6`).
  그래서 0 이 아니라 **시험 전 기준선 대비 증가분**으로 판정한다 (`scripts/08-cleanup.sh baseline|residual`).

## 초기화 (credential 등록)
1. `~/.cloud-barista/credentials.yaml` 에 CSP 계정을 적는다. 템플릿은 `init/template.credentials.yaml` 이고, holder 는 `admin` 이다.
2. `./init/encCredential.sh` 로 암호화한다. `credentials.yaml.enc` 가 생기고 평문은 지워진다. 고칠 때는 `./init/decCredential.sh` 로 푼다.
3. `./init/init.sh` 를 실행한다.
   - CSP 별 연결 정보를 등록하고, Spec·이미지·가격을 가져온다.
   - 메뉴 `c` 는 Azure 까지 전부 가져오는 것이고, Azure 때문에 오래 걸린다.
4. 끝나면 cb-spider 에서 연결 정보를 볼 수 있다.

## Cloud-Migrator 모듈 (Confluence "신규 참여자 테스트 제안" 기준)
| 모듈 | 역할 | 포트 |
|------|------|------|
| cm-honeybee | 소스의 인프라·소프트웨어·컨테이너·k8s 수집, refined 모델 생산 | 8081 |
| cm-damselfly | 마이그레이션 모델(소스·타겟 인프라, 소프트웨어) 저장 | 8088 |
| cm-beetle | 타겟 인프라 추천과 tumblebug 으로 프로비저닝 | 8056 |
| cm-grasshopper | 타겟 VM 에 소프트웨어 이식 (SSH) | 8084 |
| cm-cicada | Airflow 워크플로로 전 과정 오케스트레이션 | 8083 (airflow 8080) |
| cm-butterfly | 통합 웹 UI | 80 |
| cm-mayfly | 위 전부를 compose 로 띄우는 배포 도구 | - |
