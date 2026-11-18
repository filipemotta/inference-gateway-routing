#!/usr/bin/env bash
# Scenario 3, the fix: same gateway, same workload, the InferencePool as the
# backend. For every request Envoy calls the Endpoint Picker (ext_proc), which
# scores each pod on queue depth, KV cache utilization and the share of the
# prompt prefix it has likely cached, and Envoy sends the request there.
# Compared side by side with scenario 2 (02b is the same gateway with the
# Service as backend).
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

[ -s "${OUT}/02b-gateway-service.json" ] || { echo "run scripts/02-service.sh first: scenario 3 is compared with it" >&2; exit 1; }

step "Endpoint Picker (llm-d-router v1.0.0), InferencePool, HTTPRoute"
apply_file "${MANIFESTS}/epp/epp.yaml"
apply_file "${MANIFESTS}/epp/inferencepool.yaml"
apply_file "${MANIFESTS}/gateway/route-pool.yaml"
k -n "${NS}" rollout status deploy/model-server-epp --timeout=300s >/dev/null
pool_resolved() { [ "$(k -n "${NS}" get inferencepool model-server -o jsonpath='{.status.parents[0].conditions[?(@.type=="ResolvedRefs")].status}')" = True ]; }
wait_until 120 pool_resolved || true
k -n "${NS}" get inferencepool model-server -o yaml | sed -n '/^spec:/,/^status:/p' | sed '$d' | show

step "InferencePool through the gateway"
fresh_model_servers
# The EPP watches the pool's pods and scrapes their /metrics every 50 ms;
# give it a moment to pick up the three new pods.
sleep 5
loadgen inference-pool "${OUT}/03-inference-pool" "${LOAD_ARGS[@]}" --url "$(gateway_url)" --host-header pool.llm.lab --pods "$(model_endpoints)"
per_replica "${OUT}/03-inference-pool.json" | show

step "side by side (same seed, same $(load_requests) requests)"
{
  printf '%-22s %8s %8s %8s %10s %10s %8s %8s\n' backend "TTFT p50" "TTFT p90" "TTFT p99" "total p50" "total p99" "hit rate" "pods/conv"
  for f in 02a-service 02b-gateway-service 03-inference-pool; do
    jq -r '[.label, .ttft_ms.p50, .ttft_ms.p90, .ttft_ms.p99, .total_ms.p50, .total_ms.p99, .prefix_hit_rate, .pods_per_conversation_mean]
      | "\(.[0]) \(.[1]) \(.[2]) \(.[3]) \(.[4]) \(.[5]) \(.[6]) \(.[7])"' "${OUT}/${f}.json" \
      | awk '{ printf "%-22s %8s %8s %8s %10s %10s %8s %8s\n", $1, $2, $3, $4, $5, $6, $7, $8 }'
  done
} | tee "${OUT}/side-by-side.txt" | show

step "Checks"
P="$(cat "${OUT}/03-inference-pool.json")"
both="$(jq -s '{svc: .[0], gw: .[1], pool: .[2]}' "${OUT}/02a-service.json" "${OUT}/02b-gateway-service.json" "${OUT}/03-inference-pool.json")"
expect_eq "InferencePool accepted by the gateway" "True" "$(k -n "${NS}" get inferencepool model-server -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')"
expect_eq "failureMode FailClose as declared in the manifest" "FailClose" "$(k -n "${NS}" get inferencepool model-server -o jsonpath='{.spec.endpointPickerRef.failureMode}')"
expect_eq "every request answered" "$(load_requests)/$(load_requests)" "$(jq -r '"\(.ok)/\(.requests)"' <<< "${P}")"
expect_true_if "each conversation stays on one replica (mean $(jq -r .pods_per_conversation_mean <<< "${P}") replicas per conversation, at most 1.5)" \
  .pods_per_conversation_mean '.pods_per_conversation_mean <= 1.5' "${P}"
expect_perf "prefix cache hit rate $(jq -r .pool.prefix_hit_rate <<< "${both}") at least 0.15 above the gateway->Service baseline ($(jq -r .gw.prefix_hit_rate <<< "${both}"))" \
  '.pool.prefix_hit_rate >= .gw.prefix_hit_rate + 0.15' "${both}"
expect_perf "TTFT p50 $(jq -r .pool.ttft_ms.p50 <<< "${both}") ms at most 60% of the gateway->Service baseline ($(jq -r .gw.ttft_ms.p50 <<< "${both}") ms)" \
  '.pool.ttft_ms.p50 <= 0.6 * .gw.ttft_ms.p50' "${both}"
expect_perf "TTFT p90 $(jq -r .pool.ttft_ms.p90 <<< "${both}") ms below the gateway->Service baseline ($(jq -r .gw.ttft_ms.p90 <<< "${both}") ms)" \
  '.pool.ttft_ms.p90 < .gw.ttft_ms.p90' "${both}"
expect_perf "TTFT p99 $(jq -r .pool.ttft_ms.p99 <<< "${both}") ms below the kube-proxy baseline ($(jq -r .svc.ttft_ms.p99 <<< "${both}") ms)" \
  '.pool.ttft_ms.p99 < .svc.ttft_ms.p99' "${both}"
expect_perf "total latency p50 $(jq -r .pool.total_ms.p50 <<< "${both}") ms below the gateway->Service baseline ($(jq -r .gw.total_ms.p50 <<< "${both}") ms)" \
  '.pool.total_ms.p50 < .gw.total_ms.p50' "${both}"
finish
