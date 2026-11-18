#!/usr/bin/env bash
# Step 0: the cluster every scenario runs on.
#   kind v0.33.0, Kubernetes v1.37.0 (platform node + model node)
#   -> Gateway API v1.6.1 CRDs and the InferencePool CRD (Inference Extension v1.6.2)
#   -> Istio 1.32.0 (Helm: base + istiod) with InferencePool support on
#   -> the three model servers, their Service, the Istio Gateway, the load generator
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ensure_clis

step "kind cluster ${CLUSTER_NAME} ($(kind version))"
if grep -qx "${CLUSTER_NAME}" <<< "$(kind get clusters 2>/dev/null)"; then
  note "already exists"
  kind export kubeconfig --name "${CLUSTER_NAME}" >/dev/null
else
  kind create cluster --config "${REPO_ROOT}/kind/cluster.yaml" --wait 180s
fi
assert_lab_context
# The control plane node is the platform node: platform pods may run there.
k taint nodes "${CLUSTER_NAME}-control-plane" node-role.kubernetes.io/control-plane:NoSchedule- >/dev/null 2>&1 || true
k get nodes -L lab.infergw/role | show

step "CRDs: Gateway API ${GATEWAY_API_VERSION}, InferencePool (Inference Extension ${GAIE_VERSION})"
fetch "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml" \
  "${GATEWAY_API_SHA256}" "${OUT}/gateway-api-${GATEWAY_API_VERSION}.yaml"
fetch "https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml" \
  "${GAIE_SHA256}" "${OUT}/inference-extension-${GAIE_VERSION}.yaml"
k apply --server-side -f "${OUT}/gateway-api-${GATEWAY_API_VERSION}.yaml" >/dev/null
k apply --server-side -f "${OUT}/inference-extension-${GAIE_VERSION}.yaml" >/dev/null
k wait --for=condition=Established --timeout=60s crd/gateways.gateway.networking.k8s.io crd/httproutes.gateway.networking.k8s.io crd/inferencepools.inference.networking.k8s.io >/dev/null

step "Istio ${ISTIO_VERSION} (Helm charts from ${ISTIO_CHARTS}, checksums verified)"
fetch "${ISTIO_CHARTS}/base-${ISTIO_VERSION}.tgz" "${ISTIO_BASE_SHA256}" "${OUT}/istio-base-${ISTIO_VERSION}.tgz"
fetch "${ISTIO_CHARTS}/istiod-${ISTIO_VERSION}.tgz" "${ISTIOD_SHA256}" "${OUT}/istiod-${ISTIO_VERSION}.tgz"
h upgrade --install istio-base "${OUT}/istio-base-${ISTIO_VERSION}.tgz" -n istio-system --create-namespace \
  --set defaultRevision=default --wait --timeout 5m >/dev/null
h upgrade --install istiod "${OUT}/istiod-${ISTIO_VERSION}.tgz" -n istio-system \
  -f "${REPO_ROOT}/platform/istiod-values.yaml" --wait --timeout 10m >/dev/null
k -n istio-system get deploy | show

step "model servers, Service, Gateway, load generator"
apply_file "${MANIFESTS}/namespace.yaml"
apply_file "${MANIFESTS}/model/model-server.yaml"
apply_file "${MANIFESTS}/model/service.yaml"
apply_file "${MANIFESTS}/gateway/gateway.yaml"
k -n "${NS}" create configmap loadgen --from-file="${REPO_ROOT}/loadgen/loadgen.py" \
  --from-file="${REPO_ROOT}/loadgen/probe.py" --dry-run=client -o yaml | k apply -f - >/dev/null
apply_file "${MANIFESTS}/loadgen/loadgen.yaml"
k -n "${NS}" rollout status deploy/model-server --timeout=300s >/dev/null
k -n "${NS}" wait --for=condition=Programmed gateway/inference-gateway --timeout=300s >/dev/null
k -n "${NS}" wait --for=condition=Ready pod/loadgen --timeout=300s >/dev/null
k -n "${NS}" rollout status deploy/inference-gateway-istio --timeout=300s >/dev/null
k -n "${NS}" get pods -o wide | show

step "Checks"
expect_eq "Kubernetes server version" "${K8S_VERSION}" "$(k version -o json | jq -r .serverVersion.gitVersion)"
expect_eq "two nodes Ready" "2" "$(k get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
expect_eq "istiod image tag" "${ISTIO_VERSION}" "$(k -n istio-system get deploy istiod -o jsonpath='{.spec.template.spec.containers[0].image}' | sed -E 's/.*://')"
expect_eq "istiod has InferencePool support on" "true" \
  "$(k -n istio-system get deploy istiod -o json | jq -r '.spec.template.spec.containers[0].env[] | select(.name=="ENABLE_GATEWAY_API_INFERENCE_EXTENSION") | .value')"
expect_eq "InferencePool CRD serves v1" "v1" "$(k get crd inferencepools.inference.networking.k8s.io -o jsonpath='{.spec.versions[?(@.served==true)].name}')"
expect_eq "Gateway programmed" "True" "$(k -n "${NS}" get gateway inference-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}')"
expect_eq "three model servers Ready" "3" "$(ready_replicas "${NS}" model-server)"
expect_eq "model servers all on the model node" "${CLUSTER_NAME}-worker" \
  "$(k -n "${NS}" get pods -l app=model-server -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | paste -sd' ' -)"
expect_eq "simulator version" "v1.2.0" "$(k -n "${NS}" get deploy model-server -o jsonpath='{.spec.template.spec.containers[0].image}' | sed -E 's/@.*//; s/.*://')"
finish
