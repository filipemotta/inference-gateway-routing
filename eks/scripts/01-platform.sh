#!/usr/bin/env bash
# The same platform as the kind lab, on EKS: Gateway API and InferencePool
# CRDs, Istio 1.32.0 with InferencePool support, the namespace, the Service,
# the Istio Gateway and the load generator, from the same manifests and
# pinned versions. The model servers are vLLM on the GPU nodes.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

step "CRDs: Gateway API ${GATEWAY_API_VERSION}, InferencePool (Inference Extension ${GAIE_VERSION})"
fetch "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  "${GATEWAY_API_SHA256}" "${OUT}/gateway-api-${GATEWAY_API_VERSION}.yaml"
fetch "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" \
  "${GAIE_SHA256}" "${OUT}/inference-extension-${GAIE_VERSION}.yaml"
k apply --server-side -f "${OUT}/gateway-api-${GATEWAY_API_VERSION}.yaml" >/dev/null
k apply --server-side -f "${OUT}/inference-extension-${GAIE_VERSION}.yaml" >/dev/null
k wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/inferencepools.inference.networking.k8s.io >/dev/null

step "Istio ${ISTIO_VERSION}"
fetch "${ISTIO_CHARTS}/base-${ISTIO_VERSION}.tgz" "${ISTIO_BASE_SHA256}" "${OUT}/istio-base-${ISTIO_VERSION}.tgz"
fetch "${ISTIO_CHARTS}/istiod-${ISTIO_VERSION}.tgz" "${ISTIOD_SHA256}" "${OUT}/istiod-${ISTIO_VERSION}.tgz"
h upgrade --install istio-base "${OUT}/istio-base-${ISTIO_VERSION}.tgz" -n istio-system --create-namespace \
  --set defaultRevision=default --wait --timeout 5m >/dev/null
h upgrade --install istiod "${OUT}/istiod-${ISTIO_VERSION}.tgz" -n istio-system \
  -f "${REPO_ROOT}/platform/istiod-values.yaml" --wait --timeout 10m >/dev/null

step "vLLM on the GPU nodes, Service, Gateway, load generator"
apply_file "${MANIFESTS}/namespace.yaml"
apply_file "${EKS_ROOT}/manifests/vllm.yaml"
apply_file "${MANIFESTS}/model/service.yaml"
apply_file "${MANIFESTS}/gateway/gateway.yaml"
k -n "${NS}" create configmap loadgen --from-file="${REPO_ROOT}/loadgen/loadgen.py" \
  --from-file="${REPO_ROOT}/loadgen/probe.py" --dry-run=client -o yaml | k apply -f - >/dev/null
apply_file "${MANIFESTS}/loadgen/loadgen.yaml"
k -n "${NS}" wait --for=condition=Programmed gateway/inference-gateway --timeout=300s >/dev/null
k -n "${NS}" wait --for=condition=Ready pod/loadgen --timeout=300s >/dev/null
note "waiting for vLLM (image pull and model download): up to 20 minutes"
k -n "${NS}" rollout status deploy/model-server --timeout=1200s >/dev/null
k -n "${NS}" get pods -o wide | show
first="$(k -n "${NS}" get pods -l app=model-server -o name | head -1)"
k -n "${NS}" logs "${first}" --tail=400 | grep -E 'vLLM API server version|Maximum concurrency|GPU KV cache size|max_num_seqs|prefix caching' | head -6 | show || true

step "checks"
expect_eq "three vLLM replicas Ready" "3" "$(ready_replicas "${NS}" model-server)"
expect_eq "one replica per GPU node" "3" "$(k -n "${NS}" get pods -l app=model-server -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')"
expect_eq "Gateway programmed" "True" "$(k -n "${NS}" get gateway inference-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
models="$(k -n "${NS}" exec loadgen -- python3 -c "import urllib.request; print(urllib.request.urlopen('$(service_url | sed 's#/v1/completions#/v1/models#')').read().decode())")"
expect_eq "vLLM serves the model under its served name" "${MODEL_NAME}" "$(jq -r '.data[0].id' <<< "${models}")"
finish
