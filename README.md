# KAI + Fake GPU POC

실제 KAI 스케줄링과 모의 GPU 예약을 확인합니다. CUDA 연산이나 실제 GPU 사용률은 검증하지 않습니다. Pod는 최대 24시간 자원을 예약하므로 실행 후 정리합니다.

## 디렉토리

- `versions.env`: 버전 기록
- `install/`: Helm values. Kubernetes manifest가 아니므로 kubectl로 적용하지 않습니다.
- `manifests/`: 공통 네임스페이스와 향후 큐 정책
- `scenarios/`: 순서별 manifest와 실행·성공 기준
- `scripts/`: 환경 확인, 스냅샷 수집, 정리 스크립트 호환 진입점
- `results/`: 실행별 관측 결과. 생성 결과는 Git 추적에서 제외합니다.

## 환경과 준비

기준: Docker Desktop이 관리하는 kind, ARM64, GPU 워커 3개 × 4 GPU, Fake GPU Operator 0.2.1, KAI v0.18.6. Docker Desktop의 Kubernetes 설정에서 노드 구성을 관리합니다. 설치 values는 `install/fake-gpu-values.yaml`, `install/kai-values.yaml`에 있습니다. 파일 생성은 클러스터 설치나 적용을 수행하지 않습니다.

모든 예시는 `aiflow`에서 실행합니다. 스크립트는 어느 디렉토리에서도 실행할 수 있습니다. 기본 컨텍스트는 `docker-desktop`이며 `KUBE_CONTEXT` 환경변수로 명시적으로 변경할 수 있습니다. 수동 kubectl 명령은 현재 컨텍스트를 사용하므로 먼저 확인합니다.

```bash
kubectl config current-context
bash poc/kai/scripts/check.sh
kubectl apply -f poc/kai/manifests/namespace.yaml
```

워커 3개의 GPU가 각각 4개이고, 기본 큐 `default-queue`와 구성 요소가 정상이어야 합니다. `Allocatable`은 남은 GPU 수량이 아니라 할당 가능한 총량입니다. check.sh는 상태를 출력하고 명령 실패를 반환하지만, 예상 노드 수량·Ready 여부의 자동 합격 판정은 하지 않습니다.

## 실행 순서

1. [01-smoke](scenarios/01-smoke/README.md): GPU 1개 Pod 배치·Ready 확인 후 정리.
2. [02-gpu-wait](scenarios/02-gpu-wait/README.md): GPU 4개 Pod 세 개 실행 → waiter 대기 → holder A 삭제 → waiter 자동 배치.
3. [03-priority-and-fit](scenarios/03-priority-and-fit/README.md): 높은 우선순위의 4 GPU 작업이 대기하는 동안 낮은 우선순위의 1 GPU 작업이 먼저 배치되는지 확인. 전용 리소스도 시나리오의 `cleanup.sh`로 정리합니다.
4. [04-gang-scheduling](scenarios/04-gang-scheduling/README.md): 구성원 하나를 실행할 자원만 있으면 Gang 전체 대기 → GPU 1개 반환 → 두 구성원 배치.
5. [05-consolidation](scenarios/05-consolidation/README.md): 노드별 3·3·3 GPU 여유 → 4 GPU 요청 대기 → 기존 Job 재배치 → 큰 작업 실행.
6. [06-fractional-gpu](scenarios/06-fractional-gpu/README.md): 하나의 모의 GPU에 0.25+0.25+0.5 예약 → 추가 요청 대기 → 0.25 반환 후 배치.
7. 단계별 스냅샷 수집 후 정리.

05~06은 전용 Queue/PriorityClass와 실험용 Helm overlay를 포함합니다. 04는 기본 큐에서 실행하며 Helm 설정 변경이 없습니다. 현재 Helm values를 백업하고 overlay를 적용한 뒤, 시나리오 종료 후 백업으로 복원합니다. 기존 baseline 설치 파일은 바꾸지 않습니다. 실제 실행은 아직 검증하지 않았습니다.

순서가 중요하므로 `poc/kai`나 `scenarios/` 전체를 재귀 적용하지 않습니다. 다른 GPU 작업이 없어야 12 GPU 점유 시나리오를 그대로 재현할 수 있습니다.

## 결과 수집과 정리

```bash
bash poc/kai/scripts/collect.sh gpu-wait-pending
# holder A 삭제 및 waiter 실행 확인 후
bash poc/kai/scripts/collect.sh gpu-wait-running
bash poc/kai/scenarios/02-gpu-wait/cleanup.sh
```

수집할 때마다 UTC 시각과 이름으로 새 결과 디렉토리를 만듭니다. Pod·Node·PodGroup·Queue·Event 스냅샷, 최근 스케줄러·binder 로그, 컨텍스트, 수집 오류, 결과 메모 양식을 저장합니다. 이것은 호출 시점의 스냅샷이며 연속 Watch 기록이 아닙니다. `summary.md`의 성공 여부와 관측 결과는 직접 기록합니다. 일부 조회가 실패해도 나머지 수집은 진행하고 마지막에 실패 코드를 반환합니다.

각 시나리오 디렉토리의 `cleanup.sh`를 인자 없이 실행합니다. manifest의 Pod 이름과 POC 소유 라벨에 모두 일치하는 Pod만 삭제하며 PodGroup 정리는 KAI 컨트롤러에 맡깁니다. 시나리오 03은 `kai-poc`의 모든 PodGroup 삭제를 최대 60초 기다린 뒤 소유·시나리오 라벨이 일치하는 전용 Queue와 PriorityClass도 삭제합니다. Namespace, 기본 Queue, Operator, KAI는 유지합니다. 기존 `scripts/cleanup.sh smoke|gpu-wait|priority-and-fit|gang-scheduling|consolidation|fractional|all`도 사용할 수 있으며, `all`은 여섯 시나리오의 리소스 정리를 시도합니다. 시나리오는 하나씩 실행·정리하세요. 기존 03의 정리 절차는 공유 네임스페이스에 다른 PodGroup이 남아 있으면 중단합니다. 05~06의 Helm 설정 복원은 각 README의 별도 명령으로 수행합니다.

## 진단 / Troubleshooting

```bash
kubectl describe pod <pod-name> -n kai-poc
kubectl get events -n kai-poc --sort-by=.metadata.creationTimestamp
kubectl logs -n kai-scheduler deployment/kai-scheduler-default --tail=100
kubectl logs -n kai-scheduler deployment/binder --tail=100
kubectl get pods -n gpu-operator -o wide
kubectl describe node <worker-node-name>
```

- `ImagePullBackOff`: 이미지 다운로드 문제입니다. 네트워크·레지스트리 접근을 확인합니다.
- 노드가 이미 지정된 `ContainerCreating`: 스케줄링 이후 컨테이너 준비 단계입니다. Pod Events와 device-plugin 로그를 확인합니다.
- 점유 작업이 Pending: 다른 GPU 예약, 노드별 가용량, CPU·메모리, 큐 정책을 확인합니다. 점유 작업 세 개가 Ready가 되기 전 waiter를 제출하지 않습니다.
- waiter가 바로 실행됨: smoke/이전 실행 상태와 점유 작업 수, 노드 GPU 수량을 확인합니다.
- 대기 원인이 Pod Events에 없으면 PodGroup 상태와 스케줄러 로그를 함께 확인합니다.

24시간이 지난 Pod는 종료될 수 있습니다. 같은 이름의 완료 Pod를 재실행하려면 해당 시나리오를 정리한 뒤 다시 적용합니다. Pod의 자원 요청 등 immutable 필드를 수정하는 경우에도 삭제 후 재생성합니다.


## 애니메이션 연동

Pod UID, workload/PodGroup 식별자, 큐, GPU 요청 수, 노드 이름, phase/conditions, 변경 전후 스냅샷, 관련 Events를 수집합니다. 이벤트 시각과 수집 시각을 구분하고 삭제된 Pod의 UID도 이력에 남깁니다. GPU 개별 장치 식별은 이 manifest의 수량 예약과 별도입니다.

재생 흐름: 작업 접수 → 미배치 대기 → holder 삭제 → 예약 해제 → waiter 노드 배치 → 컨테이너 실행. UI에는 실제 스케줄링을 관측한 **모의 GPU 환경**임을 표시합니다.


## 참고

- [KAI v0.18.6 GPU Pod example](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/docs/quickstart/pods/gpu-pod.yaml)
- [Fake GPU Operator](https://github.com/run-ai/fake-gpu-operator)

## English quick guide

Use `install/` for Helm values, `manifests/` for shared resources, and each scenario README for ordered execution. Run `check.sh`, create the namespace, complete and clean the smoke scenario, then run the GPU wait scenario. Scripts default to the `docker-desktop` context; override with `KUBE_CONTEXT` when needed. `collect.sh <label>` saves point-in-time evidence under `results/` and reports partial failures. Fill in `summary.md` manually. Run `cleanup.sh` inside each scenario directory without arguments. Scenario 03 also waits for all PodGroups in `kai-poc` to disappear before removing its owned dedicated queues and PriorityClasses. The compatibility entry point `scripts/cleanup.sh smoke|gpu-wait|priority-and-fit|gang-scheduling|consolidation|fractional|all` delegates to these scripts; `all` covers all six scenarios. Run scenarios one at a time; restore Helm values separately after scenarios 05–06. No scenario or cluster changes run automatically.
# kai-playground
