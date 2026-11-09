#!/usr/bin/env bash
# Clean dedicated resources only after Pods and PodGroups are gone.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
pods=(fit-large-job fit-small-job fit-holder-a fit-holder-b fit-holder-c fit-holder-d)
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

# kai-poc is the shared POC namespace. Fail before deleting policies if any
# PodGroups remain, including those belonging to another active scenario.
"${k[@]}" wait podgroups.scheduling.run.ai -n kai-poc --all \
  --for=delete --timeout=60s

delete_policy() {
  local kind="$1" name="$2" labels
  labels="$("${k[@]}" get "$kind" "$name" --ignore-not-found \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}{"/"}{.metadata.labels.poc\.aiflow/scenario}')"
  if [[ "$labels" == aiflow-kai-poc/priority-and-fit ]]; then
    "${k[@]}" delete "$kind" "$name" --ignore-not-found --wait=true --timeout=60s
  else
    printf 'Skipping %s/%s: absent or scenario ownership labels do not match\n' "$kind" "$name"
  fi
}

# Delete the leaf queue before its parent.
delete_policy queues.scheduling.run.ai aiflow-poc-fit
delete_policy queues.scheduling.run.ai aiflow-poc-fit-parent
for name in aiflow-poc-fit-small aiflow-poc-fit-large aiflow-poc-fit-holder; do
  delete_policy priorityclasses.scheduling.k8s.io "$name"
done
