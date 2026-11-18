#!/usr/bin/env bash
# Scenario 2, the failure: the model servers behind a plain Service.
# The same seeded workload (180 streamed requests, Poisson arrivals at 3/s,
# 16 conversations with a 600-word shared prefix each, 15% long pasted
# documents, 8 to 64 output tokens) is sent two ways:
#   a) to the Service's ClusterIP over 16 keep-alive connections: kube-proxy
#      picks a pod once per connection, and every request on it follows;
#   b) through the Istio gateway with the Service as the HTTPRoute backend:
#      Envoy picks a pod per request (Istio's default LEAST_REQUEST), the
#      fairest baseline for scenario 3, which only swaps the backend.
# Neither knows which replica holds a conversation's prefix in its KV cache.
# Each run starts from freshly restarted model servers (cold caches).
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

apply_file "${MANIFESTS}/gateway/route-service.yaml"
route_accepted() { [ "$(k -n "${NS}" get httproute llm-service -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}')" = True ]; }
wait_until 120 route_accepted

step "a) Service ClusterIP, 16 keep-alive connections (kube-proxy picks per connection)"
fresh_model_servers
loadgen service-kube-proxy "${OUT}/02a-service" "${LOAD_ARGS[@]}" --url "$(service_url)" --keepalive 16 --pods "$(model_endpoints)"
per_replica "${OUT}/02a-service.json" | show

step "b) Istio gateway -> HTTPRoute -> Service (Envoy LEAST_REQUEST per request)"
fresh_model_servers
loadgen gateway-service "${OUT}/02b-gateway-service" "${LOAD_ARGS[@]}" --url "$(gateway_url)" --host-header service.llm.lab --pods "$(model_endpoints)"
per_replica "${OUT}/02b-gateway-service.json" | show

step "Checks"
for f in 02a-service 02b-gateway-service; do
  r="${OUT}/${f}.json"
  l="$(j "${r}" .label)"
  expect_eq "${l}: every request answered" "$(load_requests)/$(load_requests)" "$(j "${r}" '"\(.ok)/\(.requests)"')"
  # Each conversation lands on (almost) every replica, so its prefix is
  # prefilled again on each of them.
  expect_true_if "${l}: conversations spread over replicas (mean $(j "${r}" .pods_per_conversation_mean) replicas per conversation, at least 2.5)" \
    .pods_per_conversation_mean '.pods_per_conversation_mean >= 2.5' "$(cat "${r}")"
  expect_perf "${l}: prefix cache hit rate $(j "${r}" .prefix_hit_rate) stays at or below 0.65" '.prefix_hit_rate <= 0.65' "$(cat "${r}")"
  expect_perf "${l}: some replica queued requests (peak waiting per replica $(jq -c .waiting_max_by_pod "${r}"))" '(.waiting_max_by_pod | max) >= 1' "$(cat "${r}")"
done
finish
