#!/usr/bin/env bash
# Tests the alert rules in observability/: promtool check rules, the unit
# tests in alerts.test.yaml, and then mutation checks. Each mutation removes
# one guard from a rule; the unit tests must catch it (fail). A mutation the
# tests do not catch means a guard nobody tests, and fails this script.
# Uses promtool from ./bin (bash tools/install-cli.sh promtool) or the PATH.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OBS="${REPO_ROOT}/observability"
PATH="${REPO_ROOT}/bin:${PATH}"
command -v promtool >/dev/null || { echo "promtool not found: run bash tools/install-cli.sh promtool" >&2; exit 2; }

failures=0
promtool --version 2>&1 | sed -n 1p
if promtool check rules "${OBS}/alerts.yaml"; then echo "  [ok] promtool check rules"; else echo "  [FAIL] promtool check rules"; failures=$((failures + 1)); fi
if promtool test rules "${OBS}/alerts.test.yaml"; then echo "  [ok] promtool test rules"; else echo "  [FAIL] promtool test rules"; failures=$((failures + 1)); fi

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
cp "${OBS}/alerts.test.yaml" "${tmp}/"
rules="$(cat "${OBS}/alerts.yaml")"

# mutate <description> <exact text in alerts.yaml> <replacement>: replaces
# every occurrence.
mutate() {
  local mutated="${rules//"$2"/"$3"}"
  if [ "${mutated}" = "${rules}" ]; then
    echo "  [FAIL] mutation '$1': text not found in alerts.yaml (update this script)"; failures=$((failures + 1)); return
  fi
  printf '%s\n' "${mutated}" > "${tmp}/alerts.yaml"
  if promtool test rules "${tmp}/alerts.test.yaml" >/dev/null 2>&1; then
    echo "  [FAIL] mutation '$1' survived: no test covers it"; failures=$((failures + 1))
  else
    echo "  [ok] mutation '$1' caught by the tests"
  fi
}

mutate "FailClose: count 500s that reached a model server" \
  'destination_workload="unknown", response_code="500"' 'response_code="500"'
mutate "FailClose: count every Service, not only InferencePool services" \
  'destination_service_name=~".+-ip-[0-9a-f]{8}"' 'destination_service_name=~".+"'
mutate "FailClose: no for clause (page on a one-minute blip)" \
  $'    for: 2m\n    labels:\n      severity: page' $'    labels:\n      severity: page'
mutate "FailOpen: alert on streams_failed (any ext_proc error) instead of failure_mode_allowed" \
  'rate(envoy_http_ext_proc_failure_mode_allowed[5m])' 'rate(envoy_http_ext_proc_streams_failed[5m])'
mutate "EPP: absent(up) instead of absent(up == 1), blind to a down target" \
  'absent(up{job="model-server-epp"} == 1)' 'absent(up{job="model-server-epp"})'
mutate "hit rate: compare with the current value instead of the 6-hour median" \
  'quantile_over_time(0.5, model_name:vllm_prefix_cache_hit_ratio:rate5m[6h] offset 15m)' 'quantile_over_time(0.5, model_name:vllm_prefix_cache_hit_ratio:rate5m[5m])'
mutate "hit rate: no for clause (fire on a ten-minute dip)" \
  $'    for: 15m\n' ''
mutate "TTFT: no minimum traffic (p99 of three requests a minute)" \
  'sum by (model_name) (rate(vllm:time_to_first_token_seconds_count[5m])) > 0.1' 'sum by (model_name) (rate(vllm:time_to_first_token_seconds_count[5m])) > 0'
mutate "TTFT: p90 instead of p99" \
  'histogram_quantile(0.99,' 'histogram_quantile(0.90,'

echo "alert tests: ${failures} failure(s)"
[ "${failures}" -eq 0 ]
