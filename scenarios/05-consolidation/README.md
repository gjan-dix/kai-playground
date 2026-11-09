# 05. Consolidation — 배치 전후 관측

모든 명령은 `aiflow`에서 실행합니다. 다른 POC GPU 작업을 먼저 정리하고, 워커 세 개에 각각 모의 GPU 4개가 있는지 확인하세요. 노드 이름이 다르면 manifest의 hostname을 수정합니다. 디렉토리 전체를 재귀 적용하지 않습니다. 이 시나리오는 파일과 실행 절차를 준비한 상태이며 실제 실행 성공은 아직 검증하지 않았습니다.

```bash
k() { kubectl --context docker-desktop "$@"; }
k apply -f poc/kai/manifests/namespace.yaml
bash poc/kai/scripts/check.sh
```

## 설정 백업과 실험 설정 적용

실험 overlay는 default 스케줄러 전체에 영향을 주므로 다른 시나리오와 동시에 실행하지 않습니다. 현재 사용자 Helm 설정을 먼저 보관합니다. 아래 변수는 종료 후 복원할 때까지 같은 터미널에 유지합니다.

```bash
SCENARIO_DIR=poc/kai/scenarios/05-consolidation
mkdir -p poc/kai/results
BACKUP_DIR=$(mktemp -d "$PWD/poc/kai/results/05-consolidation-config-XXXXXX")
helm get values kai-scheduler -n kai-scheduler --kube-context docker-desktop -o yaml > "$BACKUP_DIR/kai-values.yaml"
helm upgrade kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --kube-context docker-desktop -n kai-scheduler --version v0.18.6 \
  --reset-values -f "$BACKUP_DIR/kai-values.yaml" -f "$SCENARIO_DIR/kai-consolidation-off-values.yaml" --wait
k rollout status deployment/kai-scheduler-default -n kai-scheduler --timeout=180s
k get schedulingshard default -o yaml
k apply -f "$SCENARIO_DIR/priority-classes.yaml" -f "$SCENARIO_DIR/queues.yaml"
```

생성된 SchedulingShard의 actions/plugins가 overlay와 일치하고 스케줄러가 준비된 후 진행합니다. 최소 실행시간 플러그인은 이 실험에서만 끕니다. Queue는 GPU 12개, CPU 1000m, 메모리 1024 MB의 quota/limit을 가지므로 다른 실험 큐와 함께 실행하지 않습니다.

## 1. 분산 배치 만들기

각 워커에 고정 seed Pod로 GPU 3개씩 예약한 뒤, 노드 고정이 없는 1 GPU Job 세 개를 제출합니다. 각 노드에 1 GPU만 남아 있으므로 작은 Job이 하나씩 배치됩니다. 작은 작업을 hostname으로 고정하면 재배치가 불가능하므로 고정하지 않습니다.

```bash
k apply -f "$SCENARIO_DIR/seed-holders.yaml"
k wait pod -n kai-poc -l 'poc.aiflow/scenario=consolidation,poc.aiflow/role=seed' --for=condition=Ready --timeout=180s
k apply -f "$SCENARIO_DIR/movable-jobs.yaml"
k wait pod -n kai-poc -l 'poc.aiflow/scenario=consolidation,poc.aiflow/role=movable' --for=condition=Ready --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=consolidation -o wide
```

작은 Job 세 개의 Pod가 하나씩 다른 노드에서 Ready인지 확인합니다. 생성 전 wait가 실패하면 Pod 생성 후 다시 실행합니다.

## 2. 노드별 가용 3·3·3 → 4 GPU 작업 대기

```bash
k delete -f "$SCENARIO_DIR/seed-holders.yaml" --wait=true
k apply -f "$SCENARIO_DIR/large-job.yaml"
k get pods -n kai-poc -l poc.aiflow/scenario=consolidation -o wide
k get podgroups.scheduling.run.ai -n kai-poc -o yaml
bash poc/kai/scripts/collect.sh consolidation-before
```

총 GPU 9개가 비었어도 한 노드에는 3개뿐이므로 `con-large`는 Pending입니다. Consolidation/Preempt/Reclaim이 모두 꺼진 상태임을 확인합니다. small과 large는 동일 우선순위 50이므로 우선순위 선점으로 해소하는 실험이 아닙니다.

## 3. Consolidation 활성화

```bash
helm upgrade kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --kube-context docker-desktop -n kai-scheduler --version v0.18.6 \
  --reset-values -f "$BACKUP_DIR/kai-values.yaml" -f "$SCENARIO_DIR/kai-consolidation-on-values.yaml" --wait
k rollout status deployment/kai-scheduler-default -n kai-scheduler --timeout=180s
k get schedulingshard default -o yaml
k get pods -n kai-poc -l poc.aiflow/scenario=consolidation -o wide --watch
```

관측 후 Ctrl+C로 watch를 종료하고 결과를 수집합니다.

```bash
k get jobs -n kai-poc -l poc.aiflow/scenario=consolidation
k get pods -n kai-poc -l poc.aiflow/scenario=consolidation -o wide
k logs -n kai-scheduler deployment/kai-scheduler-default --tail=300
bash poc/kai/scripts/collect.sh consolidation-after
```

성공 기준: large Pod가 Ready이고, 작은 Job 세 개 모두 대체 Pod를 포함해 Ready 상태로 회복합니다. 적어도 한 작은 Job의 Pod UID와 배치 노드가 변경되고, Consolidation 로그/이벤트와 대응해야 합니다. before 스냅샷과 비교하세요. 어느 노드를 비울지는 스케줄러가 결정합니다.

Consolidation은 이동한 작업도 다시 배치 가능한 경우를 찾습니다. 무중단 메모리 이동이 아니라 Pod 종료와 Job controller의 재생성입니다. seed를 직접 지워서 large가 곧바로 배치됐거나, small을 수동 삭제해서 자리를 만든 결과는 Consolidation 성공으로 기록하지 않습니다. 회복되지 않으면 Job 재시도, PodGroup, 큐 quota, SchedulingShard actions와 로그를 확인합니다.

애니메이션: 세 노드의 여유 3·3·3 → 4 GPU 요청 대기 → 작은 작업 종료/재생성 표시 → 한 노드에 4개 확보 → 큰 작업 배치 → 작은 작업 회복. UID·노드·시각과 해당 action 근거를 연결합니다.

## 정리 및 설정 복원

```bash
bash poc/kai/scenarios/05-consolidation/cleanup.sh
helm upgrade kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --kube-context docker-desktop -n kai-scheduler --version v0.18.6 \
  --reset-values -f "$BACKUP_DIR/kai-values.yaml" --wait
k rollout status deployment/kai-scheduler-default -n kai-scheduler --timeout=180s
```

cleanup.sh는 이 시나리오의 Job/Pod와 전용 Queue/PriorityClass를 소유 라벨 확인 후 정리합니다. Helm 설정은 별도 복원 명령으로 되돌립니다. 실험 뒤 baseline values를 무조건 덮어쓰는 대신 실행 전 백업을 사용합니다.

## English quick guide

Seed each worker with three GPUs, then start three movable one-GPU Jobs. Verify one small Job per worker. Delete seeds while consolidation is disabled; the four-GPU Job should wait despite nine GPUs free overall. Enable consolidation, observe at least one small Job restart on another node, and verify the large and all small Jobs become Ready. Require consolidation evidence, not just a changed final layout. All commands run from aiflow on docker-desktop. Run scenarios in isolation. Back up the current Helm values, apply the scenario overlay, verify the generated SchedulingShard and scheduler readiness, and create the dedicated policies. After observing and collecting evidence, run cleanup.sh and restore the saved Helm values. Manifests and procedures are prepared; runtime success has not yet been verified.

## 검증 범위

manifest의 클라이언트 dry-run, 셸 문법, KAI v0.18.6 공식 Helm 차트 렌더링을 확인했습니다. cleanup 로직은 각 시나리오 스크립트에 포함하며, 셸 문법을 확인했습니다. 실제 Job/Pod 실행과 선점·재배치·GPU 공유 성공은 아직 검증하지 않았습니다.

## References

- [Consolidation implementation](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/pkg/scheduler/actions/consolidation/consolidation.go)
- [Action configuration](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/docs/developer/designs/scheduler-config-customization.md)
