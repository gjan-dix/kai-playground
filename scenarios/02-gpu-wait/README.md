# GPU 대기와 반환 / GPU wait and release

모든 명령은 `aiflow`에서 실행합니다. [공통 준비](../../README.md)를 먼저 완료하세요.

`holders.yaml`과 `waiter.yaml`을 한꺼번에 적용하지 않습니다. 먼저 점유 Pod 세 개가 모두 Ready가 된 뒤 waiter를 제출해야 대기를 재현할 수 있습니다.

먼저 별도 터미널에서 상태와 이벤트를 관측합니다.

```bash
kubectl get pods -n kai-poc -o wide --watch
```

```bash
kubectl get events -n kai-poc --watch
```

점유 Pod A/B/C는 각각 GPU 4개를 요청합니다. 한 워커의 GPU가 4개이므로 서로 다른 워커에 배치됩니다. 노드를 직접 지정하지 않고 KAI가 결정하게 합니다.

```bash
kubectl apply -f poc/kai/scenarios/02-gpu-wait/holders.yaml
kubectl wait -n kai-poc --for=condition=Ready pod -l poc.aiflow/role=holder --timeout=180s
kubectl get pods -n kai-poc -l poc.aiflow/scenario=gpu-wait -o wide
kubectl apply -f poc/kai/scenarios/02-gpu-wait/waiter.yaml
kubectl get pod gpu-waiter -n kai-poc -o wide
kubectl describe pod gpu-waiter -n kai-poc
kubectl get podgroups.scheduling.run.ai -n kai-poc
```

예상 상태 / Expected: A/B/C 모두 Ready, 총 12 GPU 예약. `gpu-waiter`는 GPU 1개를 요청하지만 `Pending`이며 노드가 할당되지 않습니다. 스케줄링 사이클 후 이벤트·PodGroup·스케줄러 로그에서 대기 근거를 확인합니다. 이벤트에 근거가 없다면 Pending만으로 GPU 부족을 확정하지 않습니다.

관측을 마친 후 A를 삭제하여 GPU를 반환합니다. 독립 Pod이므로 A는 자동 재생성되지 않습니다.

```bash
kubectl delete pod gpu-holder-a -n kai-poc --wait=true
kubectl wait -n kai-poc --for=condition=Ready pod/gpu-waiter --timeout=180s
kubectl get pods -n kai-poc -o wide
kubectl describe pod gpu-waiter -n kai-poc
```

성공 기준: waiter를 다시 제출하지 않아도 KAI가 반환된 자원에 배치하고 Pod가 Ready가 됩니다. `holders.yaml`을 다시 적용하면 A가 재생성되므로 관측 도중 재적용하지 않습니다.


## 정리 / Cleanup

```bash
bash poc/kai/scenarios/02-gpu-wait/cleanup.sh
```

English: Apply holders first and wait for all three to become Ready. Apply the waiter and verify it is Pending and unbound. Delete holder A; the waiter should become Ready without resubmission. Collect evidence before and after release. Do not reapply holders during observation.
