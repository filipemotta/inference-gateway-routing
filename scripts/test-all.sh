#!/usr/bin/env bash
# Runs the whole lab from nothing, in the order of the article, and always
# tears it down at the end (also on failure or Ctrl-C), unless KEEP=1.
# Exits non-zero if any assertion of any step fails.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${DIR}/../out"
mkdir -p "${OUT}"
: > "${OUT}/assertions.txt"
# Results of an earlier run must not stand in for this one.
rm -f "${OUT}"/0[1-4]*.json "${OUT}"/0[1-4]*.log "${OUT}/side-by-side.txt"
: > "${OUT}/timings.txt"

cleanup() {
  if [ "${KEEP:-0}" = 1 ]; then
    echo "KEEP=1: the cluster is still running; remove it with: bash scripts/teardown.sh"
  else
    printf '\n######## teardown ########\n'
    bash "${DIR}/teardown.sh" || echo "teardown reported leftovers: check the output above"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

start="$(date +%s)"
failed=()
for s in 00-cluster 01-context 02-service 03-inference-pool 04-epp-down; do
  printf '\n######## %s ########\n' "${s}"
  t0="$(date +%s)"
  if ! bash "${DIR}/${s}.sh"; then
    failed+=("${s}")
    # Every later step needs the cluster from step 0, and 03 and 04 compare
    # with the results of the step before them.
    [ "${s}" = "00-cluster" ] && break
  fi
  echo "step ${s}: $(( $(date +%s) - t0 ))s" | tee -a "${OUT}/timings.txt"
done

printf '\n######## summary ########\n'
awk '{ p += $2; f += $3; printf "  %-26s %3d passed, %d failed\n", $1, $2, $3 }
     END { printf "  %-26s %3d passed, %d failed\n", "total", p, f }' "${OUT}/assertions.txt"
echo "duration: $(( $(date +%s) - start ))s (teardown not included)"
if [ "${#failed[@]}" -eq 0 ]; then
  echo "all steps passed"
else
  echo "failed steps: ${failed[*]}"
  exit 1
fi
