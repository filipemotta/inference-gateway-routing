#!/usr/bin/env bash
# Shared helpers for the EKS part. Not meant to be run directly.
# It loads the kind lab's helpers (scripts/lib.sh: pinned versions, the load
# generator, the assertions) and then points them at the EKS cluster: its own
# kubeconfig and context, the AWS account check, the model and workload.
# The kind scenario scripts run against EKS with LAB_TARGET=eks.
# shellcheck shell=bash
# shellcheck disable=SC2034 # variables are read by the scripts that source this file

EKS_LIB_LOADED=1
EKS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "${EKS_ROOT}/../scripts/lib.sh"

OUT="${EKS_ROOT}/out"
mkdir -p "${OUT}"
export EKS_ROOT OUT

# --- what the lab runs on ----------------------------------------------------
# Both required and never defaulted: this part of the lab creates billable
# resources (GPU instances), so it only runs where you point it, and only if
# the credentials resolve to the account you expect.
: "${AWS_PROFILE:?export AWS_PROFILE=<profile of the AWS account to use>}"
: "${EXPECTED_AWS_ACCOUNT:?export EXPECTED_AWS_ACCOUNT=<12-digit ID of the account the lab may create resources in>}"
export AWS_PROFILE EXPECTED_AWS_ACCOUNT
AWS_REGION="us-east-1"
EKS_CLUSTER="eks-cluster-infergw"
# Must match eks.node_groups.gpu.instance_types in terraform/02-eks.
GPU_INSTANCE_TYPE="g5.xlarge"
export AWS_REGION EKS_CLUSTER GPU_INSTANCE_TYPE

assert_aws_account() {
  local got
  got="$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)"
  if [ "${got}" != "${EXPECTED_AWS_ACCOUNT}" ]; then
    echo "refusing to run: AWS_PROFILE=${AWS_PROFILE} resolves to account '${got}', not ${EXPECTED_AWS_ACCOUNT}" >&2
    exit 4
  fi
}
assert_aws_account

# The EKS part has its own kubeconfig with one context, and its own Helm and
# Docker configs. ~/.kube/config is never read or written.
export KUBECONFIG="${OUT}/kubeconfig"
KUBE_CONTEXT="eks-infergw"
HELM_REGISTRY_CONFIG="${OUT}/helm-registry.json"
DOCKER_CONFIG="${OUT}/docker-config"
HELM_CACHE_HOME="${OUT}/helm-cache"
HELM_CONFIG_HOME="${OUT}/helm-config"
mkdir -p "${DOCKER_CONFIG}" "${HELM_CACHE_HOME}" "${HELM_CONFIG_HOME}"
[ -f "${HELM_REGISTRY_CONFIG}" ] || echo '{}' > "${HELM_REGISTRY_CONFIG}"
[ -f "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"
export KUBE_CONTEXT HELM_REGISTRY_CONFIG DOCKER_CONFIG HELM_CACHE_HOME HELM_CONFIG_HOME

# Safety: refuse to run unless the lab context points at the API server of the
# cluster this lab created, as read from the EKS API (not from the kubeconfig).
assert_lab_context() {
  local want got entry
  want="$(aws eks describe-cluster --region "${AWS_REGION}" --name "${EKS_CLUSTER}" --query cluster.endpoint --output text 2>/dev/null || true)"
  entry="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}" 2>/dev/null || true)"
  got="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${entry}\")].cluster.server}" 2>/dev/null || true)"
  if [ -z "${want}" ] || [ "${want}" = "None" ] || [ "${got}" != "${want}" ]; then
    echo "refusing to run: context ${KUBE_CONTEXT} ('${got}') is not the lab cluster ('${want}')" >&2
    exit 3
  fi
}

# --- the model and the workload ---------------------------------------------
MODEL_NAME="qwen2.5-1.5b"
# The kind workload scaled to a real model on a real GPU: longer shared
# prefixes, more conversations, longer answers, a higher arrival rate.
# Override with EKS_LOAD_ARGS to try another load.
# shellcheck disable=SC2054 # the commas are one argument of --max-tokens
read -r -a LOAD_ARGS <<< "${EKS_LOAD_ARGS:---seed 42 --requests 600 --rate 10 --conversations 48 --prefix-words 3000 --long-words 1500 --long-share 0.15 --max-tokens 32,64,128,256}"
LOAD_ARGS+=(--model "${MODEL_NAME}" --timeout 300)

# Cold caches between measured runs without reloading the model: vLLM's dev
# endpoint POST /reset_prefix_cache on every replica (VLLM_SERVER_DEV_MODE=1).
fresh_model_servers() {
  local ep ok tries
  for ep in $(model_endpoints | tr ',' ' '); do
    ok=""
    for tries in 1 2 3 4 5 6 7 8 9 10; do
      ok="$(k -n "${NS}" exec loadgen -- python3 -c "
import json, urllib.request
r = urllib.request.urlopen(urllib.request.Request('http://${ep}/reset_prefix_cache', method='POST'), timeout=30)
print(json.loads(r.read()).get('success'))" 2>/dev/null || true)"
      [ "${ok}" = True ] && break
      sleep 3
    done
    note "reset prefix cache on ${ep}: ${ok:-no answer} (attempt ${tries})"
  done
}

# --- terraform ---------------------------------------------------------------
aws_state_bucket() { printf 'infergw-%s-useast1-tfstate' "${EXPECTED_AWS_ACCOUNT}"; }
# tf <stack> <terraform args...>
tf() {
  local stack="$1"; shift
  local dir="${EKS_ROOT}/terraform/${stack}"
  export TF_IN_AUTOMATION=1
  if [ "${stack}" = 00-remote-backend ]; then
    (unset TF_VAR_remote_backend; terraform -chdir="${dir}" "$@")
  else
    terraform -chdir="${dir}" "$@"
  fi
}
# tf_init <stack>: 00 keeps local state; the others use the bucket.
tf_init() {
  if [ "$1" = 00-remote-backend ]; then
    tf "$1" init -input=false -no-color >/dev/null
  else
    tf "$1" init -input=false -no-color -reconfigure -backend-config="bucket=$(aws_state_bucket)" >/dev/null
  fi
}
remote_backend_vars() {
  TF_VAR_remote_backend="$(jq -cn --arg b "$(aws_state_bucket)" --arg r "${AWS_REGION}" '{bucket: $b, region: $r}')"
  export TF_VAR_remote_backend
}
operator_cidr() { printf '%s/32' "$(curl -sSf https://checkip.amazonaws.com | tr -d '[:space:]')"; }
