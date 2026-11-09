#!/usr/bin/env bash
# Read-only environment report; Ready states and capacity require review.
set -euo pipefail
context="${KUBE_CONTEXT:-docker-desktop}"
k=(kubectl --context "$context" --request-timeout=20s)
printf 'Context: %s\n' "$context"
"${k[@]}" cluster-info
"${k[@]}" get nodes -L run.ai/simulated-gpu-node-pool
"${k[@]}" get nodes -o 'custom-columns=NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
"${k[@]}" get pods -n gpu-operator -o wide
"${k[@]}" get ds -n gpu-operator
"${k[@]}" get deploy -n kai-scheduler
"${k[@]}" get queues.scheduling.run.ai
