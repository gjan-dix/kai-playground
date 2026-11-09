# 04. Gang Scheduling — 최소 구성원 전체가 배치될 때 실행

한 구성원을 실행할 GPU만 남아 있을 때 작업 전체가 대기하고, 최소 구성원 두 개를 모두 배치할 수 있게 되면 실행되는지 확인합니다.

## 구성

Docker Desktop kind의 `desktop-worker`에 모의 GPU 4개가 있는 구성을 사용합니다. 다른 노드의 GPU는 후보에서 제외합니다. 노드 이름이 다르면 두 manifest의 hostname을 함께 수정합니다.

| 리소스 | 요청 GPU | 역할 |
| --- | ---: | --- |
| Pod `gang-holder` | 2 | 실험 내내 예약 유지 |
| Pod `gang-release` | 1 | 대기 확인 후 삭제해 1 GPU 반환 |
| Job `gang-training` | 1 × Pod 2개 | minMember=2인 Gang 작업 |

Job은 `parallelism=2`, `completions=2`, `kai.scheduler/batch-min-member: "2"`입니다. 모든 Pod가 기본 큐 `default-queue`를 사용하고 `desktop-worker`에 배치되도록 설정합니다. 실제 CUDA 연산 대신 sleep으로 GPU 예약을 유지합니다.

## 1. 준비

모든 명령은 `aiflow`에서 실행합니다. 다른 시나리오 작업을 먼저 정리하고 05~06의 실험 설정이 남아 있으면 해당 가이드에 따라 복원하세요. 대상 노드에 GPU 4개가 비어 있고 기본 큐의 정책을 별도로 변경하지 않은 상태를 전제로 합니다.

```bash
k() { kubectl --context docker-desktop "$@"; }
SCENARIO_DIR=poc/kai/scenarios/04-gang-scheduling
bash poc/kai/scripts/check.sh
k apply -f poc/kai/manifests/namespace.yaml
```

디렉토리 전체를 한 번에 적용하지 마세요. 제출 순서와 중간 상태 확인이 실험 조건입니다.

## 2. GPU 3개 예약 → GPU 1개만 남기기

```bash
k apply -f "$SCENARIO_DIR/holders.yaml"
k wait pod/gang-holder pod/gang-release -n kai-poc --for=condition=Ready --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=gang-scheduling -o wide
```

두 Pod 모두 `desktop-worker`에서 Ready인지 확인합니다. `Allocatable=4`는 총량이며, 현재 예약량 3개를 뺀 추가 가용량은 1개입니다.

## 3. Gang 제출 → 두 구성원 모두 대기

```bash
k apply -f "$SCENARIO_DIR/gang-job.yaml"
k wait job/gang-training -n kai-poc --for=jsonpath='{.status.active}'=2 --timeout=60s
k get pods -n kai-poc -l 'poc.aiflow/scenario=gang-scheduling,poc.aiflow/role=gang' -o wide
k get podgroups.scheduling.run.ai -n kai-poc -o yaml
k get events -n kai-poc --sort-by=.metadata.creationTimestamp
bash poc/kai/scripts/collect.sh gang-one-gpu-free
```

성공 기준: Job의 Pod 두 개가 생성되고, 스케줄링 사이클이 진행돼도 **둘 다 Pending이며 NODE가 미설정**입니다. 관련 PodGroup의 minMember=2와 대기 근거도 확인합니다. Job의 active=2는 종료하지 않은 Pod 두 개를 뜻하며 Running 두 개를 뜻하지 않습니다.

GPU 1개가 있어 개별 Pod 하나는 실행할 수 있지만 Gang 전체에 필요한 GPU 2개가 없으므로, 한 Pod만 먼저 실행되면 기대 결과와 다릅니다. 이미지 다운로드 등 배치 이후 지연을 Gang 대기로 오인하지 않도록 `spec.nodeName`을 함께 확인합니다.

별도 터미널에서 관측할 수 있습니다.

```bash
kubectl --context docker-desktop get pods -n kai-poc \
  -l poc.aiflow/scenario=gang-scheduling -o wide --watch
```

## 4. GPU 1개 반환 → 두 구성원 배치

```bash
k delete pod gang-release -n kai-poc --wait=true
k wait pod -n kai-poc -l 'poc.aiflow/scenario=gang-scheduling,poc.aiflow/role=gang' --for=condition=Ready --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=gang-scheduling -o wide
bash poc/kai/scripts/collect.sh gang-two-gpus-free
```

성공 기준: Job을 재제출하지 않아도 두 구성원이 모두 `desktop-worker`에 배치되고 Ready가 됩니다. `gang-holder`는 같은 UID와 노드로 실행을 유지해야 합니다. before/after 스냅샷과 이벤트를 대조합니다. 두 컨테이너의 시작 시각이 정확히 같아야 한다는 뜻은 아닙니다.

애니메이션 사건은 **GPU 여유 1개 → Gang 구성원 두 개 대기 → release 종료로 여유 2개 → Gang 배치 → 각 구성원 실행**입니다. holder의 예약과 실행 상태를 함께 표시합니다.

## 5. 정리

```bash
bash poc/kai/scenarios/04-gang-scheduling/cleanup.sh
# 또는
bash poc/kai/scripts/cleanup.sh gang-scheduling
```

Job을 먼저 삭제하여 구성원 Pod의 재생성을 막은 뒤 독립 Pod를 정리합니다. 소유·시나리오 라벨을 확인하고 삭제하며 PodGroup 정리는 KAI에 맡깁니다.

## 검증 범위

manifest 클라이언트 dry-run과 cleanup.sh 셸 문법을 확인했습니다. 실제 클러스터에 적용해 Gang 대기·실행을 검증하지는 않았습니다.

## English quick guide

This scenario verifies gang admission. Pin all Pods to a four-GPU worker. Start a two-GPU holder and a one-GPU release Pod, leaving one GPU free. Submit a Job with two one-GPU members and minMember=2: both members must remain Pending and unbound. Delete only the release Pod; both members should become Ready without resubmission while the holder keeps its UID and node. Observe PodGroup minMember and events, collect before/after snapshots, then run the scenario cleanup script. Container start times need not be identical.

## References

- [KAI v0.18.6 Batch Scheduling](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/docs/batch/README.md)
