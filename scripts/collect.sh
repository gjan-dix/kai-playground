#!/usr/bin/env bash
# Point-in-time snapshots, not a continuous event recorder.
set -euo pipefail
label="${1:-snapshot}"
if [[ $# -gt 1 || ! "$label" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
  printf 'Usage: %s [label: letters, digits, underscores, hyphens]\n' "$0" >&2
  exit 2
fi
base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
context="${KUBE_CONTEXT:-docker-desktop}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$base_dir/results"
output_dir="$(mktemp -d "$base_dir/results/${stamp}-${label}-XXXXXX")"
k=(kubectl --context "$context" --request-timeout=20s)
failed=0
printf 'Context: %s\nCollected at (UTC): %s\n' "$context" "$stamp" > "$output_dir/context.txt"
capture() {
  local filename="$1"
  shift
  if "$@" > "$output_dir/$filename" 2> "$output_dir/$filename.stderr"; then
    printf 'OK %s\n' "$filename" >> "$output_dir/collection-status.txt"
  else
    failed=1
    printf 'FAILED %s (see .stderr)\n' "$filename" >> "$output_dir/collection-status.txt"
  fi
}
capture pods.json "${k[@]}" get pods -n kai-poc -o json
capture jobs.json "${k[@]}" get jobs -n kai-poc -o json
capture reservation-pods.json "${k[@]}" get pods -n kai-resource-reservation -o json
capture reservation-events.json "${k[@]}" get events -n kai-resource-reservation -o json
capture fake-topology.json "${k[@]}" get configmaps -n gpu-operator -l node-topology=true -o json
capture scheduling-shards.json "${k[@]}" get schedulingshards -o json
capture nodes.json "${k[@]}" get nodes -o json
capture podgroups.json "${k[@]}" get podgroups.scheduling.run.ai -n kai-poc -o json
capture queues.json "${k[@]}" get queues.scheduling.run.ai -o json
capture events.json "${k[@]}" get events -n kai-poc -o json
capture scheduler.log "${k[@]}" logs -n kai-scheduler deployment/kai-scheduler-default --tail=1000 --timestamps=true
capture binder.log "${k[@]}" logs -n kai-scheduler deployment/binder --tail=500 --timestamps=true
cat > "$output_dir/summary.md" <<EOF
# POC observation / 관측 결과

- Label: $label
- Context: $context
- Collected at (UTC): $stamp
- Result / 성공 여부: 미작성 / Not recorded
- Expected state / 예상 상태:
- Observed state and evidence / 관측 상태와 근거:
- Issues and next steps / 문제와 다음 단계:

See collection-status.txt and *.stderr for collection failures.
Snapshots describe collection time; use Event timestamps for event time.
EOF
printf 'Saved: %s\n' "$output_dir"
cat "$output_dir/collection-status.txt"
exit "$failed"
