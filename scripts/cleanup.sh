#!/usr/bin/env bash
# Compatibility entry point; cleanup implementations live with each scenario.
set -euo pipefail
if [[ $# -ne 1 ]]; then
  printf 'Usage: %s smoke|gpu-wait|priority-and-fit|gang-scheduling|consolidation|fractional|all\n' "$0" >&2
  exit 2
fi
base_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "$1" in
  smoke) scenarios=(01-smoke) ;;
  gpu-wait) scenarios=(02-gpu-wait) ;;
  priority-and-fit) scenarios=(03-priority-and-fit) ;;
  gang-scheduling) scenarios=(04-gang-scheduling) ;;
  consolidation) scenarios=(05-consolidation) ;;
  fractional) scenarios=(06-fractional-gpu) ;;
  all) scenarios=(01-smoke 02-gpu-wait 04-gang-scheduling 05-consolidation 06-fractional-gpu 03-priority-and-fit) ;;
  *) printf 'Unknown scenario: %s\n' "$1" >&2; exit 2 ;;
esac
for scenario in "${scenarios[@]}"; do
  bash "$base_dir/scenarios/$scenario/cleanup.sh"
done
