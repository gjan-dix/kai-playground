# 06. KAI Fractional GPU

모든 명령은 `aiflow`에서 실행합니다. 다른 POC GPU 작업을 먼저 정리하고, 워커 세 개에 각각 모의 GPU 4개가 있는지 확인하세요. 노드 이름이 다르면 manifest의 hostname을 수정합니다. 디렉토리 전체를 재귀 적용하지 않습니다. 이 시나리오는 파일과 실행 절차를 준비한 상태이며 실제 실행 성공은 아직 검증하지 않았습니다.

```bash
k() { kubectl --context docker-desktop "$@"; }
k apply -f poc/kai/manifests/namespace.yaml
bash poc/kai/scripts/check.sh
```

## 설정 백업과 실험 설정 적용

실험 overlay는 default 스케줄러 전체에 영향을 주므로 다른 시나리오와 동시에 실행하지 않습니다. 현재 사용자 Helm 설정을 먼저 보관합니다. 아래 변수는 종료 후 복원할 때까지 같은 터미널에 유지합니다.

```bash
SCENARIO_DIR=poc/kai/scenarios/06-fractional-gpu
mkdir -p poc/kai/results
BACKUP_DIR=$(mktemp -d "$PWD/poc/kai/results/06-fractional-gpu-config-XXXXXX")
helm get values kai-scheduler -n kai-scheduler --kube-context docker-desktop -o yaml > "$BACKUP_DIR/kai-values.yaml"
helm upgrade kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --kube-context docker-desktop -n kai-scheduler --version v0.18.6 \
  --reset-values -f "$BACKUP_DIR/kai-values.yaml" -f "$SCENARIO_DIR/kai-fractional-values.yaml" --wait
k rollout status deployment/kai-scheduler-default -n kai-scheduler --timeout=180s
k get schedulingshard default -o yaml
k apply -f "$SCENARIO_DIR/priority-classes.yaml" -f "$SCENARIO_DIR/queues.yaml"
```

생성된 SchedulingShard의 actions/plugins가 overlay와 일치하고 스케줄러가 준비된 후 진행합니다. 최소 실행시간 플러그인은 이 실험에서만 끕니다. Queue는 GPU 12개, CPU 1000m, 메모리 1024 MB의 quota/limit을 가지므로 다른 실험 큐와 함께 실행하지 않습니다.

공유 모드는 `NonMemoryEnforced`입니다. 요청 비율은 스케줄링용 GPU 메모리 용량 예약입니다. 실제 CUDA 메모리 상한이나 연산 성능 비율을 강제하지 않습니다. kind에는 NVIDIA runtime이 없으므로 admission의 runtimeClass 자동 삽입을 빈 문자열로 비활성화합니다. 정수 GPU 요청은 fractional Pod에 넣지 않습니다.

## 1. 공유할 GPU 하나만 남기기

모든 fractional Pod를 `desktop-worker`로 제한합니다. 해당 노드의 4 GPU 중 3개는 비선점 holder가 예약합니다. 다른 두 워커의 GPU는 이번 실험의 후보가 아닙니다.

```bash
k apply -f "$SCENARIO_DIR/whole-gpu-holder.yaml"
k wait pod/fractional-holder -n kai-poc --for=condition=Ready --timeout=180s
k apply -f "$SCENARIO_DIR/shared-pods.yaml"
k wait pod -n kai-poc -l 'poc.aiflow/scenario=fractional,poc.aiflow/role=shared' --for=condition=Ready --timeout=180s
k get pods -n kai-poc -l poc.aiflow/scenario=fractional -o wide
k get pods -n kai-resource-reservation -o wide
```

A=0.25, B=0.25, C=0.5로 합계 1 GPU를 예약합니다. 모두 Ready가 된 뒤 진행합니다. 같은 노드라는 사실만으로 같은 GPU 공유를 확정하지 말고 장치 ID를 대조합니다.

## 2. 장치 공유와 추가 요청 대기 확인

```bash
k get pods -n kai-poc -l poc.aiflow/scenario=fractional -o yaml
k get configmaps -n gpu-operator -l node-topology=true -o yaml
k get pods -n kai-resource-reservation -o yaml
k apply -f "$SCENARIO_DIR/waiter.yaml"
k get pod fractional-waiter -n kai-poc -o wide
k describe pod fractional-waiter -n kai-poc
bash poc/kai/scripts/collect.sh fractional-full
```

A/B/C의 admission/binder가 기록한 annotation·환경변수(예: NVIDIA_VISIBLE_DEVICES)와 Fake GPU topology의 allocatedBy/podGpuUsageStatus를 대조해 동일 장치 ID를 공유하는지 확인합니다. 버전에 따라 필드가 다를 수 있으므로 원본 YAML을 저장합니다. 장치 ID 근거가 없으면 같은 GPU 공유는 미확인으로 기록합니다. reservation Pod는 장치 하나 전체를 예약할 수 있으므로 Node의 정수 GPU Requests 합계만으로 분수별 사용량을 계산하지 않습니다.

성공 기준 1: A/B/C는 Ready, 0.25를 추가 요청한 waiter는 미배치 Pending. 모두 같은 우선순위 50이며 Preempt/Reclaim/Consolidation을 꺼서 다른 작업을 밀어내지 않도록 합니다.

## 3. 0.25 반환 후 waiter 배치

```bash
k delete pod fractional-a -n kai-poc --wait=true
k wait pod/fractional-waiter -n kai-poc --for=condition=Ready --timeout=180s
bash poc/kai/scripts/collect.sh fractional-released
```

성공 기준 2: waiter 재제출 없이 Ready, B/C 유지, 동일 공유 장치에 waiter 할당. 예약 비율 변화만 검증하며 실제 메모리 격리와 성능은 실물 GPU에서 검증합니다.

## Fake GPU 연동 문제 확인

```bash
k get runtimeclass
k describe pods -n kai-resource-reservation
k logs -n kai-scheduler deployment/binder --tail=100
k logs -n gpu-operator deployment/status-updater --tail=100
k auth can-i patch pods -n kai-resource-reservation --as=system:serviceaccount:gpu-operator:status-updater
```

reservation Pod 준비 실패 시 이미지/장치 플러그인, RuntimeClass, fake status-updater의 reservation namespace 패치 권한을 먼저 확인합니다. 기존 `install/fake-gpu-values.yaml`의 reservation namespace와 `statusUpdater.podPatchRbac.enabled=true`가 실제 릴리스에도 적용돼 있어야 합니다. 권한·런타임 오류를 GPU 용량 부족과 구분합니다. 본 POC는 NonMemoryEnforced만 대상으로 하며 HAMi/NvFractions를 설치하지 않습니다.

애니메이션: GPU 블록 하나에 A 25%·B 25%·C 50% 예약 → waiter 대기 → A 예약 해제 → waiter 25% 배치. 실제 GPU 연산 사용률과 구분해 표시합니다.

## 정리 및 설정 복원

```bash
bash poc/kai/scenarios/06-fractional-gpu/cleanup.sh
helm upgrade kai-scheduler oci://ghcr.io/kai-scheduler/kai-scheduler/kai-scheduler \
  --kube-context docker-desktop -n kai-scheduler --version v0.18.6 \
  --reset-values -f "$BACKUP_DIR/kai-values.yaml" --wait
k rollout status deployment/kai-scheduler-default -n kai-scheduler --timeout=180s
```

cleanup.sh는 이 시나리오의 Job/Pod와 전용 Queue/PriorityClass를 소유 라벨 확인 후 정리합니다. Helm 설정은 별도 복원 명령으로 되돌립니다. 실험 뒤 baseline values를 무조건 덮어쓰는 대신 실행 전 백업을 사용합니다.

## English quick guide

Use NonMemoryEnforced mode with runtimeClass injection disabled for kind. Pin all fractional Pods to desktop-worker and reserve three whole GPUs there. A/B/C reserve 0.25/0.25/0.5 on the remaining device. Confirm shared device IDs using Pod metadata, environment variables, reservation Pods and fake topology. Submit the 0.25 waiter: it should wait. Delete A: the waiter should run. Diagnose reservation runtime/RBAC errors separately from capacity. This validates scheduling accounting only, not runtime memory isolation or compute performance. All commands run from aiflow on docker-desktop. Run scenarios in isolation. Back up the current Helm values, apply the scenario overlay, verify the generated SchedulingShard and scheduler readiness, and create the dedicated policies. After observing and collecting evidence, run cleanup.sh and restore the saved Helm values. Manifests and procedures are prepared; runtime success has not yet been verified.

## 검증 범위

manifest의 클라이언트 dry-run, 셸 문법, KAI v0.18.6 공식 Helm 차트 렌더링을 확인했습니다. cleanup 로직은 각 시나리오 스크립트에 포함하며, 셸 문법을 확인했습니다. 실제 Job/Pod 실행과 선점·재배치·GPU 공유 성공은 아직 검증하지 않았습니다.

## References

- [GPU sharing](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/docs/gpu-sharing/README.md)
- [Fake GPU test setup](https://github.com/kai-scheduler/KAI-Scheduler/blob/v0.18.6/hack/setup-e2e-cluster.sh)
