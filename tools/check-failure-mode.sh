#!/usr/bin/env bash
# Fails if any InferencePool manifest in the repository leaves out
# spec.endpointPickerRef.failureMode, or sets it to anything but FailOpen or
# FailClose. The API defaults a missing value to FailClose, but the
# llm-d-router chart writes FailOpen, so the mode a pool gets depends on where
# it came from unless the manifest says it. (The chart's README lists the
# options as FailOpen and FailClosed; FailClosed does not exist in the v1 API,
# and is reported here too.)
#
# Usage: bash tools/check-failure-mode.sh [file...]   (default: every *.yaml
#        and *.yml in the repository, except bin/, out/ and .terraform/)
#        bash tools/check-failure-mode.sh --self-test
# Plain block-style YAML, as in this repository's manifests; flow style on the
# endpointPickerRef line itself ({name: x, failureMode: FailOpen}) is read too.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# check_file <file>: prints one line per offending InferencePool, returns 1 if any.
check_file() {
  awk -v file="$1" '
    function indent(s) { match(s, /^ */); return RLENGTH }
    function finish_doc() {
      if (is_pool) {
        if (mode == "") { printf "%s: InferencePool %s has no spec.endpointPickerRef.failureMode\n", file, name; bad = 1 }
        else if (mode != "FailOpen" && mode != "FailClose") { printf "%s: InferencePool %s has failureMode %s (allowed: FailOpen, FailClose)\n", file, name, mode; bad = 1 }
      }
      is_pool = 0; name = "?"; mode = ""; in_spec = 0; in_ref = 0; meta = 0
    }
    BEGIN { bad = 0; finish_doc() }
    /^---/ { finish_doc(); next }
    { sub(/[ \t]+#.*$/, ""); if ($0 ~ /^[ \t]*#/ || $0 ~ /^[ \t]*$/) next }
    /^kind:[ \t]*InferencePool[ \t]*$/ { is_pool = 1 }
    /^metadata:/ { meta = 1; next }
    meta && /^  name:/ { name = $0; sub(/^  name:[ \t]*/, "", name); gsub(/["\047]/, "", name) }
    /^[^ ]/ { meta = 0; in_spec = ($0 ~ /^spec:/); in_ref = 0; next }
    in_spec && /^[ ]+endpointPickerRef:/ {
      ref_indent = indent($0); in_ref = 1; child = -1
      if (match($0, /failureMode:[ \t]*[A-Za-z"\047]+/)) { m = substr($0, RSTART, RLENGTH); sub(/failureMode:[ \t]*/, "", m); gsub(/["\047]/, "", m); mode = m }
      next
    }
    in_ref {
      if (indent($0) <= ref_indent) { in_ref = 0; next }
      # only direct children of endpointPickerRef (not port.failureMode)
      if (child < 0) child = indent($0)
      if (indent($0) == child && $0 ~ /^[ ]+failureMode:/) { m = $0; sub(/^[ ]+failureMode:[ \t]*/, "", m); gsub(/["\047 \t]/, "", m); mode = m }
    }
    END { finish_doc(); exit bad }
  ' "$1"
}

run_checks() {
  local f status=0 count=0 files=("$@")
  if [ "${#files[@]}" -eq 0 ]; then
    while IFS= read -r f; do files+=("$f"); done < <(cd "${REPO_ROOT}" && find . \( -path ./bin -o -path ./out -o -path '*/.terraform' -o -path '*/out' \) -prune -o \( -name '*.yaml' -o -name '*.yml' \) -print | sort)
    cd "${REPO_ROOT}" || return 1
  fi
  for f in "${files[@]}"; do
    grep -q '^kind:[[:space:]]*InferencePool[[:space:]]*$' "$f" || continue
    count=$((count + 1))
    check_file "$f" || status=1
  done
  echo "InferencePool manifests checked: ${count}"
  [ "${count}" -gt 0 ] || { echo "no InferencePool manifest found: is the search path right?"; status=1; }
  return "${status}"
}

self_test() {
  local dir failures=0
  dir="$(mktemp -d)"
  trap 'rm -rf "${dir}"' RETURN
  head='apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: pool
spec:
  selector:
    matchLabels:
      app: model-server
  targetPorts:
  - number: 8000'
  printf '%s\n  endpointPickerRef:\n    name: epp\n    port:\n      number: 9002\n    failureMode: FailClose\n' "${head}" > "${dir}/good-close.yaml"
  printf '%s\n  endpointPickerRef:\n    failureMode: "FailOpen"\n    name: epp\n' "${head}" > "${dir}/good-open-quoted-first.yaml"
  printf '%s\n  endpointPickerRef: {name: epp, port: {number: 9002}, failureMode: FailOpen}\n' "${head}" > "${dir}/good-flow.yaml"
  printf '%s\n  endpointPickerRef:\n    name: epp\n    port:\n      number: 9002\n' "${head}" > "${dir}/bad-missing.yaml"
  printf '%s\n  endpointPickerRef:\n    name: epp\n    failureMode: FailClosed\n' "${head}" > "${dir}/bad-chart-typo.yaml"
  printf '%s\n  failureMode: FailOpen\n  endpointPickerRef:\n    name: epp\n' "${head}" > "${dir}/bad-at-spec-root.yaml"
  printf '%s\n  endpointPickerRef:\n    name: epp\n    port:\n      failureMode: FailOpen\n      number: 9002\n' "${head}" > "${dir}/bad-nested-in-port.yaml"
  printf '%s\n  endpointPickerRef:\n    name: epp\n    # failureMode: FailClose\n' "${head}" > "${dir}/bad-commented-out.yaml"
  printf '%s\n  endpointPickerRef:\n    name: epp\n    failureMode: FailOpen\n---\n%s\n  endpointPickerRef:\n    name: epp2\n' "${head}" "${head/name: pool/name: pool2}" > "${dir}/bad-second-doc.yaml"
  printf 'apiVersion: apiextensions.k8s.io/v1\nkind: CustomResourceDefinition\nspec:\n  names:\n    kind: InferencePool\n' > "${dir}/not-a-pool-crd.yaml"

  expect() { # expect <pass|fail> <file>
    local got=pass
    check_file "${dir}/$2" >/dev/null || got=fail
    if [ "${got}" = "$1" ]; then echo "  [ok] $2 -> $1"; else echo "  [FAIL] $2: expected $1, got ${got}"; failures=$((failures + 1)); fi
  }
  expect pass good-close.yaml
  expect pass good-open-quoted-first.yaml
  expect pass good-flow.yaml
  expect fail bad-missing.yaml
  expect fail bad-chart-typo.yaml
  expect fail bad-at-spec-root.yaml
  expect fail bad-nested-in-port.yaml
  expect fail bad-commented-out.yaml
  expect fail bad-second-doc.yaml
  # the CRD names the kind indented: it is not a pool and is not scanned
  if grep -q '^kind:[[:space:]]*InferencePool[[:space:]]*$' "${dir}/not-a-pool-crd.yaml"; then
    echo "  [FAIL] not-a-pool-crd.yaml selected as a pool"; failures=$((failures + 1))
  else echo "  [ok] not-a-pool-crd.yaml -> not scanned"; fi
  # the whole-run entry point must fail when one file is bad
  if run_checks "${dir}/good-close.yaml" "${dir}/bad-missing.yaml" >/dev/null; then
    echo "  [FAIL] run with one bad file passed"; failures=$((failures + 1))
  else echo "  [ok] run with one bad file -> fail"; fi
  echo "self-test: ${failures} failure(s)"
  [ "${failures}" -eq 0 ]
}

if [ "${1:-}" = --self-test ]; then self_test; else run_checks "$@"; fi
