#!/usr/bin/env bash
# Delete only this scenario's named, POC-owned Pods.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
pods=(gpu-waiter gpu-holder-a gpu-holder-b gpu-holder-c)
context="${KUBE_CONTEXT:-docker-desktop}"
printf 'Deleting POC Pods in context=%s namespace=kai-poc\n' "$context"
k=(kubectl --context "$context" --request-timeout=90s)
for pod in "${pods[@]}"; do
  owner="$("${k[@]}" get pod "$pod" -n kai-poc --ignore-not-found \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}')"
  if [[ "$owner" == aiflow-kai-poc ]]; then
    "${k[@]}" delete pod "$pod" -n kai-poc \
      --ignore-not-found --wait=true --timeout=60s
  else
    printf 'Skipping %s: absent or POC ownership label does not match\n' "$pod"
  fi
done
