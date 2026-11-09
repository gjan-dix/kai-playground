#!/usr/bin/env bash
# Delete this scenario's named Job and Pods after checking ownership.
set -euo pipefail
if [[ $# -ne 0 ]]; then
  printf 'Usage: %s\n' "$0" >&2
  exit 2
fi
k=(kubectl --context "${KUBE_CONTEXT:-docker-desktop}" --request-timeout=90s)
resources=(job/gang-training pod/gang-release pod/gang-holder)
for resource in "${resources[@]}"; do
  actual="$("${k[@]}" get "$resource" -n kai-poc --ignore-not-found \
    -o 'jsonpath={.metadata.labels.app\.kubernetes\.io/part-of}{"/"}{.metadata.labels.poc\.aiflow/scenario}')"
  if [[ "$actual" == aiflow-kai-poc/gang-scheduling ]]; then
    "${k[@]}" delete "$resource" -n kai-poc --ignore-not-found \
      --cascade=foreground --wait=true --timeout=60s
  else
    printf 'Skipping %s: absent or ownership differs\n' "$resource"
  fi
done
