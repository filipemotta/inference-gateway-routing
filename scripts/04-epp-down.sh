#!/usr/bin/env bash
# Scenario 4, the new contract: the Endpoint Picker is on the critical path.
#   - EPP scaled to zero with failureMode FailClose (as the manifest declares): every
#     request on the InferencePool route fails at the gateway, while the
#     route to the plain Service keeps working;
#   - failureMode FailOpen: the gateway skips the picker and forwards to a
#     pod of its own choosing (Envoy's fallback, round-robin). Same workload
#     as scenarios 2 and 3: everything answers, at baseline quality;
#   - what the operator sees in each case: status codes, the gateway's
#     access log and its proxy log, an InferencePool status that stays green
#     throughout, and the gateway metrics the alerts in observability/ read
#     (istio_requests_total and the ext_proc counters), saved in out/ as
#     04-gateway-*.prom.
# A change of failureMode is checked where it matters, in the gateway's
# Envoy configuration, not only in the InferencePool object.
# Restores FailClose and one EPP replica at the end.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

[ -s "${OUT}/03-inference-pool.json" ] || { echo "run scripts/03-inference-pool.sh first" >&2; exit 1; }
GW_POD="$(k -n "${NS}" get pods -l gateway.networking.k8s.io/gateway-name=inference-gateway -o jsonpath='{.items[0].metadata.name}')"

# failure_mode_allow of the ext_proc override on the pool route, as the
# gateway's Envoy has it right now (true = FailOpen, false = FailClose).
envoy_failure_mode_allow() {
  k -n "${NS}" exec "${GW_POD}" -c istio-proxy -- pilot-agent request GET config_dump 2>/dev/null \
    | jq -r '[.. | objects | select(has("failure_mode_allow") and .processing_mode.request_body_mode == "FULL_DUPLEX_STREAMED") | .failure_mode_allow] | first'
}
# set_failure_mode <FailOpen|FailClose>: patch the pool, then wait for the
# gateway to carry it. Observed with Istio 1.32.0: patching only the pool
# updates the label of the Service Istio generates for it, but the route's
# ext_proc keeps the old mode until istiod recomputes the route. The script
# records whether that happened and then restarts istiod.
set_failure_mode() {
  local mode="$1" want=false
  [ "${mode}" = FailOpen ] && want=true
  k -n "${NS}" patch inferencepool model-server --type merge -p "{\"spec\":{\"endpointPickerRef\":{\"failureMode\":\"${mode}\"}}}" >/dev/null
  note "patched InferencePool model-server: failureMode ${mode}"
  envoy_has() { [ "$(envoy_failure_mode_allow)" = "${want}" ]; }
  if wait_until 30 envoy_has; then
    note "gateway Envoy picked it up within 30 s (failure_mode_allow ${want})"
    echo "${mode} propagated-without-restart" >> "${OUT}/04-propagation.txt"
  else
    note "after 30 s the gateway Envoy still has failure_mode_allow $(envoy_failure_mode_allow): restarting istiod"
    echo "${mode} stale-until-istiod-restart" >> "${OUT}/04-propagation.txt"
    k -n istio-system rollout restart deploy/istiod >/dev/null
    k -n istio-system rollout status deploy/istiod --timeout=180s >/dev/null
    wait_until 60 envoy_has || true
  fi
}
gateway_log() { k -n "${NS}" logs "${GW_POD}" -c istio-proxy --since-time="$1" 2>/dev/null; }
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
pool_conditions() { k -n "${NS}" get inferencepool model-server -o jsonpath='{range .status.parents[0].conditions[*]}{.type}={.status} {end}'; }
: > "${OUT}/04-propagation.txt"

# The gateway's Prometheus metrics, straight from its Envoy, saved in out/.
gateway_stats() { k -n "${NS}" exec "${GW_POD}" -c istio-proxy -- pilot-agent request GET stats/prometheus 2>/dev/null > "${OUT}/04-gateway-$1.prom"; }
# metric_sum <snapshot> <metric> [label regex...]: sum of the samples of the
# metric whose labels match every regex (the alerts' selectors, as regexes).
metric_sum() {
  local f="${OUT}/04-gateway-$1.prom" m="$2" lines; shift 2
  lines="$(grep -E "^${m}\{" "${f}" || true)"
  for re in "$@"; do lines="$(grep -E -- "${re}" <<< "${lines}" || true)"; done
  awk 'NF { s += $NF } END { printf "%d", s }' <<< "${lines}"
}
# metric_delta <before> <after> <metric> [label regex...]
metric_delta() { echo $(( $(metric_sum "$2" "${@:3}") - $(metric_sum "$1" "${@:3}") )); }
# The selectors of InferencePoolRequestsRefusedAtGateway in observability/alerts.yaml.
POOL_SVC='destination_service_name="[^"]+-ip-[0-9a-f]{8}"'
NO_WORKLOAD='destination_workload="unknown"'

step "EPP down, failureMode FailClose (as declared)"
expect_eq "pool starts in FailClose" "FailClose" "$(k -n "${NS}" get inferencepool model-server -o jsonpath='{.spec.endpointPickerRef.failureMode}')"
k -n "${NS}" scale deploy/model-server-epp --replicas=0 >/dev/null
k -n "${NS}" wait --for=delete pod -l app=model-server-epp --timeout=180s >/dev/null 2>&1 || true
sleep 3
gateway_stats failclose-before
t="$(now)"
loadgen failclose-epp-down "${OUT}/04a-failclose" --seed 7 --requests 20 --rate 2 --model "${MODEL_NAME}" --url "$(gateway_url)" --host-header pool.llm.lab
loadgen service-route-meanwhile "${OUT}/04a-service-route" --seed 7 --requests 20 --rate 2 --model "${MODEL_NAME}" --url "$(gateway_url)" --host-header service.llm.lab
sleep 2
gateway_stats failclose-after
log_close="$(gateway_log "${t}")"
note "gateway access log, one failed request:"
grep -m1 'pool.llm.lab' <<< "${log_close}" | show
note "gateway proxy log:"
grep -m1 'ext_proc' <<< "${log_close}" | sed -E 's/\[Tags[^]]*\] //' | show
note "InferencePool status meanwhile: $(pool_conditions)"
close_conditions="$(pool_conditions)"

step "EPP still down, failureMode FailOpen"
set_failure_mode FailOpen
open_allow="$(envoy_failure_mode_allow)"
fresh_model_servers
gateway_stats failopen-before
t="$(now)"
loadgen failopen-epp-down "${OUT}/04b-failopen" "${LOAD_ARGS[@]}" --url "$(gateway_url)" --host-header pool.llm.lab --pods "$(model_endpoints)"
per_replica "${OUT}/04b-failopen.json" | show
sleep 2
gateway_stats failopen-after
log_open="$(gateway_log "${t}")"
note "gateway access log, one request served without the picker:"
grep -m1 'pool.llm.lab' <<< "${log_open}" | show
open_conditions="$(pool_conditions)"

step "restore: one EPP replica, failureMode FailClose"
k -n "${NS}" scale deploy/model-server-epp --replicas=1 >/dev/null
k -n "${NS}" rollout status deploy/model-server-epp --timeout=180s >/dev/null
set_failure_mode FailClose
sleep 3
gateway_stats restored-before
loadgen restored "${OUT}/04c-restored" --seed 7 --requests 20 --rate 2 --model "${MODEL_NAME}" --url "$(gateway_url)" --host-header pool.llm.lab
gateway_stats restored-after
note "failureMode propagation: $(paste -sd' ' "${OUT}/04-propagation.txt")"

step "the gateway metrics behind the alerts (observability/alerts.yaml)"
for w in failclose failopen restored; do
  note "${w}: pool requests refused at the gateway +$(metric_delta "${w}-before" "${w}-after" istio_requests_total 'reporter="source"' "${POOL_SVC}" "${NO_WORKLOAD}" 'response_code="500"'), pool requests served +$(metric_delta "${w}-before" "${w}-after" istio_requests_total 'reporter="source"' "${POOL_SVC}" 'destination_workload="model-server"' 'response_code="200"'), ext_proc streams_failed +$(metric_delta "${w}-before" "${w}-after" envoy_http_ext_proc_streams_failed), failure_mode_allowed +$(metric_delta "${w}-before" "${w}-after" envoy_http_ext_proc_failure_mode_allowed)"
done
note "a refused request, as the gateway exports it:"
grep -E '^istio_requests_total\{' "${OUT}/04-gateway-failclose-after.prom" | grep -E -- "${POOL_SVC}" | grep -F 'response_code="500"' | head -1 | show

step "Checks"
C="$(cat "${OUT}/04a-failclose.json")"
S="$(cat "${OUT}/04a-service-route.json")"
O="$(jq -s '{open: .[0], pool: .[1], gw: .[2]}' "${OUT}/04b-failopen.json" "${OUT}/03-inference-pool.json" "${OUT}/02b-gateway-service.json")"
expect_eq "FailClose, EPP down: every pool request refused with HTTP 500" '{"500":20}' "$(jq -c .statuses <<< "${C}")"
expect_match "FailClose: the gateway logs the ext_proc failure as the response detail" '" 500 - ext_proc_error_gRPC_error_14.*"pool\.llm\.lab"' "$(grep ' 500 ' <<< "${log_close}")"
expect_match "FailClose: the proxy log says why (gRPC 14, no healthy upstream)" 'ext_proc.*Received gRPC error on stream: 14, message no healthy upstream' "${log_close}"
expect_eq "meanwhile the route to the plain Service answers everything" '{"200":20}' "$(jq -c .statuses <<< "${S}")"
expect_match "InferencePool status stays Accepted and ResolvedRefs with no EPP running" 'Accepted=True ResolvedRefs=True' "${close_conditions}"
expect_eq "gateway Envoy has failure_mode_allow true after the switch to FailOpen" "true" "${open_allow}"
expect_eq "FailOpen, EPP down: every request answered" "$(load_requests)/$(load_requests)" "$(jq -r '"\(.open.ok)/\(.open.requests)"' <<< "${O}")"
expect_match "FailOpen: the access log line looks like any healthy request (200 via_upstream)" '" 200 - via_upstream .*"pool\.llm\.lab"' "${log_open}"
expect_true_if "FailOpen: conversations spread again ($(jq -r .open.pods_per_conversation_mean <<< "${O}") replicas per conversation vs $(jq -r .pool.pods_per_conversation_mean <<< "${O}") with the picker)" \
  .open.pods_per_conversation_mean '.open.pods_per_conversation_mean >= 2.5' "${O}"
expect_perf "FailOpen: prefix cache hit rate back to baseline ($(jq -r .open.prefix_hit_rate <<< "${O}") vs $(jq -r .pool.prefix_hit_rate <<< "${O}") with the picker)" \
  '.open.prefix_hit_rate <= .pool.prefix_hit_rate - 0.15' "${O}"
# Mean, not p50: with the hit rate near 0.5 the TTFT distribution has two
# modes (warm cache near 80 ms, cold prefill near 500 ms) and the median lands
# on either one from run to run.
expect_perf "FailOpen: mean TTFT back above the picker's ($(jq -r .open.ttft_ms.mean <<< "${O}") ms vs $(jq -r .pool.ttft_ms.mean <<< "${O}") ms)" \
  '.open.ttft_ms.mean >= 1.3 * .pool.ttft_ms.mean' "${O}"
expect_match "InferencePool status still Accepted and ResolvedRefs" 'Accepted=True ResolvedRefs=True' "${open_conditions}"
expect_eq "restored: gateway Envoy back to failure_mode_allow false" "false" "$(envoy_failure_mode_allow)"
expect_eq "restored: every request answered through the picker" '{"200":20}' "$(jq -c .statuses "${OUT}/04c-restored.json")"
# The alerts' inputs, read from the gateway itself.
expect_ge "the gateway exports the ext_proc counters (stats matcher on the Gateway)" 1 "$(grep -c '^envoy_http_ext_proc_failure_mode_allowed{' "${OUT}/04-gateway-failclose-before.prom")"
expect_eq "FailClose metrics: the 20 refused requests in istio_requests_total as 500, InferencePool service, no workload" 20 \
  "$(metric_delta failclose-before failclose-after istio_requests_total 'reporter="source"' "${POOL_SVC}" "${NO_WORKLOAD}" 'response_code="500"')"
expect_eq "FailClose metrics: no 500 counted on the plain Service route" 0 \
  "$(metric_delta failclose-before failclose-after istio_requests_total 'reporter="source"' 'destination_service_name="model-server"' 'response_code="500"')"
expect_ge "FailClose metrics: ext_proc streams_failed counts the failed calls" 20 \
  "$(metric_delta failclose-before failclose-after envoy_http_ext_proc_streams_failed)"
expect_eq "FailClose metrics: failure_mode_allowed does not move" 0 \
  "$(metric_delta failclose-before failclose-after envoy_http_ext_proc_failure_mode_allowed)"
expect_eq "FailOpen metrics: failure_mode_allowed counts every request let through" "$(load_requests)" \
  "$(metric_delta failopen-before failopen-after envoy_http_ext_proc_failure_mode_allowed)"
expect_eq "FailOpen metrics: no request refused at the gateway" 0 \
  "$(metric_delta failopen-before failopen-after istio_requests_total 'reporter="source"' "${POOL_SVC}" 'response_code="500"')"
expect_eq "restored metrics: no ext_proc failure, nothing let through" "0 0" \
  "$(metric_delta restored-before restored-after envoy_http_ext_proc_streams_failed) $(metric_delta restored-before restored-after envoy_http_ext_proc_failure_mode_allowed)"
finish
