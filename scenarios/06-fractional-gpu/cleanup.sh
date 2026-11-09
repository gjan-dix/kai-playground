#!/usr/bin/env bash
# Scenario-owned cleanup; Helm configuration is restored separately.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
scenario="fractional"
resources=(pod/fractional-waiter pod/fractional-a pod/fractional-b pod/fractional-c pod/fractional-holder)
k=(kubectl --context "${KUBE_CONTEXT:-docker-desktop}" --request-timeout=20s)
expected="aiflow-kai-poc/$scenario"
owned_delete() {
  local resource="$1" scope="$2" actual
  local command=("${k[@]}")
  if [[ "$scope" == namespaced ]]; then command+=(-n kai-poc); fi
  actual="$("${command[@]}" get "$resource" --ignore-not-found \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}{"/"}{.metadata.labels.poc\.aiflow/scenario}')"
  if [[ "$actual" == "$expected" ]]; then
    "${command[@]}" delete "$resource" --ignore-not-found \
      --cascade=foreground --wait=true --timeout=60s --request-timeout=90s
  else
    printf 'Skipping %s: absent or ownership differs\n' "$resource"
  fi
}
for resource in "${resources[@]}"; do
  case "$resource" in job/*|pod/*) ;; *) exit 2 ;; esac
  owned_delete "$resource" namespaced
done

# Only wait for PodGroups referencing this dedicated queue.
remaining=1
for ((attempt=0; attempt<30; attempt++)); do
  groups="$("${k[@]}" get podgroups.scheduling.run.ai -n kai-poc -o json)"
  remaining="$(python3 -c 'import json,sys; q=sys.argv[1]; print(sum(x.get("spec",{}).get("queue")==q for x in json.load(sys.stdin)["items"]))' "aiflow-poc-$scenario" <<< "$groups")"
  if [[ "$remaining" == 0 ]]; then break; fi
  sleep 2
done
if [[ "$remaining" != 0 ]]; then
  printf 'PodGroups still reference this queue; retry after checking KAI controllers.\n' >&2
  exit 1
fi
owned_delete "queues.scheduling.run.ai/aiflow-poc-$scenario" cluster
owned_delete "queues.scheduling.run.ai/aiflow-poc-$scenario-parent" cluster
classes=(train protected)
for suffix in "${classes[@]}"; do
  owned_delete "priorityclasses.scheduling.k8s.io/aiflow-poc-$scenario-$suffix" cluster
done
