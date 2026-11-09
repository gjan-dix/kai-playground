# 단일 GPU 배치 / Single-GPU smoke check

모든 명령은 `aiflow`에서 실행합니다. [공통 준비](../../README.md)를 먼저 완료하세요.

```bash
kubectl apply -f poc/kai/scenarios/01-smoke/pod.yaml
kubectl wait -n kai-poc --for=condition=Ready pod/gpu-smoke --timeout=180s
kubectl get pod gpu-smoke -n kai-poc -o wide
kubectl get pod gpu-smoke -n kai-poc -o jsonpath='{.spec.schedulerName}{"\n"}{.spec.nodeName}{"\n"}'
kubectl get podgroups.scheduling.run.ai -n kai-poc
kubectl logs gpu-smoke -n kai-poc
```

성공 기준: KAI가 Pod를 GPU 워커에 배치하고 Pod가 `Running/Ready`가 됩니다. 로그는 `sleep` 컨테이너 시작을 확인하는 용도입니다. GPU 연산을 수행하지 않습니다. 이미지를 처음 받는 시간과 GPU 배치 대기 시간을 구분합니다.

다음 시나리오 전에 smoke Pod를 제거하여 GPU 1개를 반환합니다.

```bash
bash poc/kai/scenarios/01-smoke/cleanup.sh
```


## 정리 / Cleanup

```bash
bash poc/kai/scenarios/01-smoke/cleanup.sh
```

English: Apply the smoke Pod, wait for Ready, verify its scheduler and assigned node, then clean it up before the next scenario.
