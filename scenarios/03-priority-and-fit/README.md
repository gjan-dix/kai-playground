# 03. 우선순위와 배치 가능 조건 / Priority and resource fit

높은 우선순위 작업이 4 GPU를 확보하지 못하면 대기하고, 나중에 제출된 낮은 우선순위 작업이 가용 GPU 1개에 먼저 배치되는지 검증합니다. 실제 CUDA 실행이 아닌 모의 GPU 예약 실험입니다. 이 파일을 생성한 단계에서는 클러스터에 적용하거나 실행하지 않았습니다.

## 구성과 전제

KAI v0.18.6, Fake GPU Operator 0.2.1, `desktop-worker`, `desktop-worker2`, `desktop-worker3` 각각 GPU 4개를 전제로 합니다. 노드 이름이 다르면 `holders.yaml`의 hostname을 바꿉니다. holder만 노드를 제한하며 두 대기 작업의 노드는 KAI가 결정합니다.

| Pod | 요청 GPU | PriorityClass 값 | 고정 노드 |
| --- | ---: | ---: | --- |
| fit-holder-a | 3 | 300 | desktop-worker |
| fit-holder-b | 1 | 300 | desktop-worker |
| fit-holder-c | 4 | 300 | desktop-worker2 |
| fit-holder-d | 4 | 300 | desktop-worker3 |
| fit-large-job | 4 | 200 | KAI가 선택 |
| fit-small-job | 1 | 100 | KAI가 선택 |

PriorityClass는 모두 `globalDefault: false`, `preemptionPolicy: Never`입니다. KAI v0.18.6에서는 값 100 이상이 비선점 대상이므로 작은 작업을 쫓아내서 큰 작업을 배치하는 효과를 배제합니다. 비선점 작업은 quota 안에서 실행해야 하므로 별도 parent/leaf Queue의 GPU quota/limit을 각각 12로 설정합니다. CPU는 1000m, 메모리는 1024 MB를 보장합니다. 이 수량을 보장할 실제 클러스터 여유가 있어야 하며 다른 작업·시나리오와 동시에 실행하지 않습니다. 기존 default Queue와 PriorityClass는 수정하지 않습니다.

이 실험은 우선순위만의 효과를 증명하는 비교 실험이 아닙니다. 자원 조건 때문에 낮은 우선순위 작업이 먼저 실행될 수 있는지를 확인합니다.

## 1. 준비

`aiflow` 디렉토리에서 실행합니다. 아래 `k` 함수는 모든 명령을 `docker-desktop` 컨텍스트로 한정합니다. 다른 터미널에서는 함수를 다시 정의하세요.

```bash
cd /Users/gyujinan/Workspace/agj017/aidc-research/aiflow
k() { kubectl --context docker-desktop "$@"; }
SCENARIO_DIR=poc/kai/scenarios/03-priority-and-fit

k get nodes -L run.ai/simulated-gpu-node-pool
k get nodes -o 'custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
k get pods -A -o wide
k apply -f poc/kai/manifests/namespace.yaml
```

이전 시나리오가 실행 중이면 해당 가이드에 따라 먼저 정리합니다. GPU 12개가 비어 있어야 재현할 수 있습니다. 전용 Queue와 PriorityClass 이름이 다른 용도의 기존 리소스와 겹치지 않는지도 확인합니다.

```bash
k apply -f "$SCENARIO_DIR/priority-classes.yaml"
k apply -f "$SCENARIO_DIR/queues.yaml"
k get queues.scheduling.run.ai aiflow-poc-fit-parent aiflow-poc-fit
```

디렉토리 전체를 한꺼번에 적용하지 마세요 / Do not apply this directory recursively. 제출 순서가 실험 조건입니다.

## 2. holder로 GPU 12개 예약

```bash
k apply -f "$SCENARIO_DIR/holders.yaml"
k wait -n kai-poc --for=condition=Ready pod \
  -l 'poc.aiflow/scenario=priority-and-fit,poc.aiflow/role=fit-holder' --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=priority-and-fit -o wide
```

holder 4개가 모두 Ready이고 노드 배치가 표와 같은지 확인한 후 진행합니다. 실패하면 다음 단계로 넘어가지 말고 `k describe pod <이름> -n kai-poc`로 확인합니다.

## 3. large를 먼저, small을 나중에 제출

```bash
k apply -f "$SCENARIO_DIR/large-job.yaml"
k get pod fit-large-job -n kai-poc -o wide
k apply -f "$SCENARIO_DIR/small-job.yaml"
k get pods -n kai-poc -l poc.aiflow/scenario=priority-and-fit \
  -o 'custom-columns=POD:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase,PRIORITY:.spec.priority,GPU:.spec.containers[*].resources.requests.nvidia\.com/gpu'
k describe pod fit-large-job -n kai-poc
k describe pod fit-small-job -n kai-poc
k get podgroups.scheduling.run.ai -n kai-poc
bash poc/kai/scripts/collect.sh fit-both-pending
```

두 대기 작업 / Both waiters: `Pending`이고 `NODE`가 미설정인지 확인합니다. 판단에 몇 차례의 스케줄링 사이클이 걸릴 수 있습니다. Events, PodGroup, 스케줄러 로그의 근거도 확인합니다.

별도 터미널에서 변화를 관측할 수 있습니다.

```bash
kubectl --context docker-desktop get pods -n kai-poc \
  -l poc.aiflow/scenario=priority-and-fit -o wide --watch
```

## 4. GPU 1개 반환 → small 먼저 실행

```bash
k delete pod fit-holder-b -n kai-poc --wait=true
k wait -n kai-poc --for=condition=Ready pod/fit-small-job --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=priority-and-fit -o wide
k describe pod fit-large-job -n kai-poc
bash poc/kai/scripts/collect.sh fit-small-running
```

예상 결과 / Expected: small은 `desktop-worker`에서 Ready, large는 노드 미설정의 Pending입니다. large의 우선순위가 높아도 가용 GPU가 1개이므로 4 GPU 요청을 만족하지 못합니다.

## 5. GPU 3개 추가 반환 → large는 대기 유지

```bash
k delete pod fit-holder-a -n kai-poc --wait=true
k get pods -n kai-poc -l poc.aiflow/scenario=priority-and-fit -o wide
k describe node desktop-worker
k describe pod fit-large-job -n kai-poc
bash poc/kai/scripts/collect.sh fit-three-free
```

small이 GPU 1개를 예약하므로 worker의 가용량은 3 GPU이고 large는 여전히 Pending입니다. 최소 몇 차례의 스케줄링 사이클 동안 관측합니다. 노드의 `Allocatable`은 여전히 4이며 현재 가용량이 아닙니다. `Allocated resources`의 GPU Requests가 1인지 대조합니다.

## 6. small 종료 → large 자동 실행

```bash
k delete pod fit-small-job -n kai-poc --wait=true
k wait -n kai-poc --for=condition=Ready pod/fit-large-job --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=priority-and-fit -o wide
bash poc/kai/scripts/collect.sh fit-large-running
```

large를 재제출하지 않아도 `desktop-worker`에서 Ready가 되면 성공입니다. 도중에 holders나 small manifest를 다시 적용하면 삭제한 Pod가 재생성되므로 재적용하지 않습니다.

## 7. 정리와 재실행

이 시나리오의 Pod를 정리하고 `kai-poc`의 모든 PodGroup이 삭제될 때까지 최대 60초 기다린 뒤 전용 Queue와 PriorityClass를 정리합니다. 다른 시나리오의 PodGroup이 남아 있어도 정책 정리를 중단하므로 해당 시나리오를 먼저 종료하세요. 시간 초과 시 컨트롤러 상태를 확인하고 다시 실행합니다. 리소스 이름과 POC 소유 라벨을 확인하며 Queue와 PriorityClass는 시나리오 라벨도 확인합니다. Namespace, 기본 Queue, Operator, KAI는 유지합니다.

```bash
bash poc/kai/scenarios/03-priority-and-fit/cleanup.sh
```

기본 컨텍스트는 `docker-desktop`이며 다른 컨텍스트에서는 `KUBE_CONTEXT`를 지정합니다. 결과는 `poc/kai/results/`에 저장되며 각 `summary.md`에 예상값·관측 결과·성공 여부를 기록합니다.

## English quick guide

Run from `aiflow` and define the context-pinned `k` function and `SCENARIO_DIR` above. Ensure all three workers have four free simulated GPUs. Apply the namespace, dedicated PriorityClasses and queues, then holders; wait for all four to be Ready. Submit large first and small second; verify both are Pending and unbound. Delete holder B: small should become Ready while large remains Pending. Delete holder A: three GPUs are free but large still cannot fit. Delete small: large should become Ready without resubmission. Collect snapshots at each stage. Run this scenario’s `cleanup.sh` (override `KUBE_CONTEXT` if needed). It deletes named POC-owned Pods, waits up to 60 seconds for all PodGroups in `kai-poc` to disappear, then deletes the owned dedicated leaf queue, parent queue and PriorityClasses. If PodGroups remain, policy cleanup stops; clean other active scenarios or check the controller before retrying. This scenario uses non-preemptible workloads and dedicated quota; it tests resource-fit bypass, not priority ordering in isolation.

## References

- [KAI v0.18.6 workload priority](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/docs/priority/README.md)
- [KAI v0.18.6 queues](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/docs/queues/README.md)
