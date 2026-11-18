#!/usr/bin/env bash
# The whole EKS part, from nothing to nothing: infra, platform, then the same
# scenario scripts as the kind lab (02 Service, 03 InferencePool, 04 EPP down)
# against EKS, then teardown: always, also on failure or Ctrl-C, unless
# KEEP=1. A watchdog tears everything down after 3 hours whatever happens.
# Billable: about US$ 3.30 per hour while it runs (3x g5.xlarge, EKS, NAT).
# Not exercised end to end: the published EKS numbers come from running the
# same steps one at a time (see the README). Its trap and watchdog are untested.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${DIR}/../.." && pwd)"
# shellcheck source=/dev/null
source "${DIR}/lib.sh"
: > "${OUT}/timings.txt"
CAP_SECONDS="${CAP_SECONDS:-10800}"
( sleep "${CAP_SECONDS}" && echo "######## ${CAP_SECONDS}s cap reached: tearing down ########" && kill -TERM $$ ) &
WATCHDOG=$!
cleanup() {
  kill "${WATCHDOG}" 2>/dev/null || true
  if [ "${KEEP:-0}" = 1 ]; then echo "KEEP=1: the cluster is still running (and billing); remove it with: bash eks/scripts/teardown.sh"
  else printf '\n######## teardown ########\n'; t0=$SECONDS; bash "${DIR}/teardown.sh"; echo "teardown: $((SECONDS - t0))s" | tee -a "${OUT}/timings.txt"; fi
  echo "wall time: $((SECONDS / 60)) min" | tee -a "${OUT}/timings.txt"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

rm -f "${OUT}"/0[2-4]*.json "${OUT}"/0[2-4]*.log
failed=()
for s in eks/scripts/00-infra eks/scripts/01-platform scripts/02-service scripts/03-inference-pool scripts/04-epp-down; do
  printf '\n######## %s ########\n' "${s}"
  t0=$SECONDS
  LAB_TARGET=eks bash "${REPO}/${s}.sh" || { failed+=("${s}"); case "${s}" in *00-infra|*01-platform) break ;; esac; }
  echo "step ${s}: $((SECONDS - t0))s" | tee -a "${OUT}/timings.txt"
done
printf '\n######## summary ########\n'
awk '{ p += $2; f += $3; printf "  %-22s %3d passed, %d failed\n", $1, $2, $3 } END { printf "  %-22s %3d passed, %d failed\n", "total", p, f }' "${OUT}/assertions.txt"
if [ "${#failed[@]}" -eq 0 ]; then echo "all steps passed"; else echo "failed steps: ${failed[*]}"; exit 1; fi
