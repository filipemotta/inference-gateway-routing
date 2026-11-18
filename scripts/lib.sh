#!/usr/bin/env bash
# Shared helpers sourced by the lab scripts. Not meant to be run directly.
# shellcheck shell=bash
# The variables below are read by the scripts that source this file.
# shellcheck disable=SC2034

# Decimal point and plain messages whatever the operator's locale.
export LC_ALL=C

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${REPO_ROOT}/out"
MANIFESTS="${REPO_ROOT}/manifests"
mkdir -p "${OUT}"
export REPO_ROOT OUT MANIFESTS
export PATH="${REPO_ROOT}/bin:${PATH}"

CLUSTER_NAME="infergw"
KUBE_CONTEXT="kind-${CLUSTER_NAME}"
K8S_VERSION="v1.37.0"
NS="llm"
export CLUSTER_NAME KUBE_CONTEXT K8S_VERSION NS

# --- pinned dependencies, each checked against its SHA-256 -------------------
ISTIO_VERSION="1.32.0"
ISTIO_CHARTS="https://blob.istio.io/istio-release/charts"
ISTIO_BASE_SHA256="505ce0d9b6cf5d73a9998728fdf0821510a237470567e6c332164937c6850f05"
ISTIOD_SHA256="17d275e3661e2e943a1ab630386bacab0cda76ea007978351a3a10fe9f4050d4"
# Gateway API: the version Istio 1.32 lists as supported.
GATEWAY_API_VERSION="v1.6.1"
GATEWAY_API_SHA256="24d931f22abd8e40c973264319ead7cfa09d0fb7716b7ab1ee2ff174cb063a73"
# Gateway API Inference Extension: the InferencePool CRD (v1 only).
GAIE_VERSION="v1.6.2"
GAIE_SHA256="f410dfca474608c02903087b47f1ac081706dfb6dfe7f83d00a7cc7e00c4ad0d"
export ISTIO_VERSION GATEWAY_API_VERSION GAIE_VERSION

# The lab never reads or writes your ~/.kube/config: it has its own.
export KUBECONFIG="${OUT}/kubeconfig"
# Helm and the CLIs never consult your Docker credential helper (it can hang
# a non-interactive shell): empty registry and Docker configs of their own.
HELM_REGISTRY_CONFIG="${OUT}/helm-registry.json"
DOCKER_CONFIG="${OUT}/docker-config"
HELM_CACHE_HOME="${OUT}/helm-cache"
HELM_CONFIG_HOME="${OUT}/helm-config"
mkdir -p "${DOCKER_CONFIG}" "${HELM_CACHE_HOME}" "${HELM_CONFIG_HOME}"
[ -f "${HELM_REGISTRY_CONFIG}" ] || echo '{}' > "${HELM_REGISTRY_CONFIG}"
[ -f "${DOCKER_CONFIG}/config.json" ] || echo '{}' > "${DOCKER_CONFIG}/config.json"
export HELM_REGISTRY_CONFIG DOCKER_CONFIG HELM_CACHE_HOME HELM_CONFIG_HOME

# Safety: every kubectl and helm call passes the context explicitly, and the
# lab refuses to run if that context does not point at a local kind API server.
assert_lab_context() {
  local cluster server
  cluster="$(kubectl config view -o jsonpath="{.contexts[?(@.name==\"${KUBE_CONTEXT}\")].context.cluster}" 2>/dev/null || true)"
  server="$(kubectl config view -o jsonpath="{.clusters[?(@.name==\"${cluster}\")].cluster.server}" 2>/dev/null || true)"
  if [ -z "${cluster}" ] || [[ ! "${server}" =~ ^https://(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
    echo "refusing to run: context ${KUBE_CONTEXT} is missing or does not point at a local kind API server (server='${server}')" >&2
    exit 3
  fi
}

k() { kubectl --context "${KUBE_CONTEXT}" "$@"; }
h() { helm --kube-context "${KUBE_CONTEXT}" "$@"; }

ensure_clis() { bash "${REPO_ROOT}/tools/install-cli.sh" kubectl kind helm >/dev/null; }

sha256_of() { local s; s="$(shasum -a 256 "$1" 2>/dev/null || sha256sum "$1")"; printf '%s' "${s%% *}"; }
# fetch <url> <sha256> <dest>: download once into out/, verify, reuse after.
fetch() {
  local url="$1" want="$2" dest="$3"
  if [ ! -f "${dest}" ] || [ "$(sha256_of "${dest}")" != "${want}" ]; then
    curl -sSfL "${url}" -o "${dest}.tmp"
    if [ "$(sha256_of "${dest}.tmp")" != "${want}" ]; then
      echo "checksum mismatch for ${url} (want ${want}, got $(sha256_of "${dest}.tmp"))" >&2
      rm -f "${dest}.tmp"
      exit 1
    fi
    mv "${dest}.tmp" "${dest}"
  fi
}

step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
show() { sed 's/^/      /'; }

# --- assertions: failures are counted, the script exits non-zero at the end ---
PASSED=0
FAILED=0
pass() { PASSED=$((PASSED + 1)); printf '    [PASS] %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '    [FAIL] %s\n' "$1"; }

# expect_eq <description> <expected> <actual>
expect_eq() {
  if [ "$2" = "$3" ]; then pass "$1 (got $3)"; else fail "$1 (expected $2, got $3)"; fi
}
# expect_match <description> <extended regex> <actual>
expect_match() {
  if grep -Eq -- "$2" <<< "$3"; then pass "$1"; else fail "$1 (no match for /$2/ in: $(head -c 600 <<< "$3"))"; fi
}
# expect_ge <description> <minimum> <actual integer>
expect_ge() {
  if [[ "$3" =~ ^-?[0-9]+$ ]] && [ "$3" -ge "$2" ]; then pass "$1 (got $3, minimum $2)"; else fail "$1 (got $3, minimum $2)"; fi
}
# expect_le <description> <maximum> <actual integer>
expect_le() {
  if [[ "$3" =~ ^-?[0-9]+$ ]] && [ "$3" -le "$2" ]; then pass "$1 (got $3, maximum $2)"; else fail "$1 (got $3, maximum $2)"; fi
}
# expect_true <description> <jq filter that must print true> <json>
# The filter sees the JSON; the description should carry the measured values.
expect_true() {
  if [ "$(jq -r "$2" <<< "$3" 2>/dev/null)" = true ]; then pass "$1"; else fail "$1 (jq: $2)"; fi
}

# expect_true_if <description> <jq filter: the value that must not be null>
#   <jq filter that must print true> <json>: like expect_true, but only when
# the measured value exists. The replicas per conversation need the model
# server to name itself in each response (the simulator does, vLLM does not).
expect_true_if() {
  if [ "$(jq -r "$2" <<< "$4" 2>/dev/null)" = null ]; then
    note "[n/a]  $1 (not measurable here: the model server does not name itself in its responses)"
  else
    expect_true "$1" "$3" "$4"
  fi
}

# expect_perf <description> <jq filter that must print true> <json>: a
# latency or cache threshold. The thresholds were set on the simulator, which
# keeps the replicas busy enough to queue. On a real GPU the outcome depends
# on the hardware, the model and how close the load gets to saturation, so on
# EKS the measured values are recorded as observations, not pass or fail.
expect_perf() {
  if [ "${LAB_TARGET:-kind}" = eks ]; then
    if [ "$(jq -r "$2" <<< "$3" 2>/dev/null)" = true ]; then
      note "[OBS]  $1 (simulator threshold met)"
    else
      note "[OBS]  $1 (simulator threshold not met)"
    fi
  else
    expect_true "$1" "$2" "$3"
  fi
}

finish() {
  printf '\n    result: %s passed, %s failed\n' "${PASSED}" "${FAILED}"
  printf '%s %s %s\n' "$(basename "$0" .sh)" "${PASSED}" "${FAILED}" >> "${OUT}/assertions.txt"
  [ "${FAILED}" -eq 0 ]
}

# wait_until <seconds> <command...>: re-runs the command every 3s until it
# exits 0. Returns 1 on timeout.
wait_until() {
  local deadline=$((SECONDS + $1)); shift
  until "$@" >/dev/null 2>&1; do
    [ "${SECONDS}" -lt "${deadline}" ] || { note "timeout: $*"; return 1; }
    sleep 3
  done
}

apply_file() {
  note "kubectl apply -f ${1#"${REPO_ROOT}"/}"
  k apply -f "$1" >/dev/null
}

# ready_replicas <ns> <deployment> -> readyReplicas as an integer (0 if unset)
ready_replicas() {
  local r
  r="$(k -n "$1" get deploy "$2" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
  printf '%s' "${r:-0}"
}

# --- the model servers and the load generator ---------------------------------

# Restart the model servers so every measured run starts with cold caches and
# empty queues, then wait for the three new pods.
fresh_model_servers() {
  k -n "${NS}" rollout restart deploy/model-server >/dev/null
  k -n "${NS}" rollout status deploy/model-server --timeout=180s >/dev/null
  # rollout status returns when the new pods are Ready; wait for the old ones
  # to be gone so the pod list (and the metrics we read) is the new set.
  # shellcheck disable=SC2329 # called through wait_until
  three_pods() { [ "$(k -n "${NS}" get pods -l app=model-server --no-headers 2>/dev/null | wc -l | tr -d ' ')" = 3 ]; }
  wait_until 120 three_pods
}
# model_endpoints -> ip:8000,ip:8000,ip:8000 of the Ready model server pods
model_endpoints() {
  k -n "${NS}" get pods -l app=model-server --field-selector=status.phase=Running \
    -o jsonpath='{range .items[*]}{.status.podIP}:8000{","}{end}' | sed 's/,$//'
}
# gateway_url -> the in-cluster URL of the gateway's completions endpoint
gateway_url() { printf 'http://inference-gateway-istio.%s.svc.cluster.local/v1/completions' "${NS}"; }
service_url() { printf 'http://model-server.%s.svc.cluster.local:8000/v1/completions' "${NS}"; }

# The workload every scenario sends. Same seed, same requests, same arrival
# times; scenarios only change where the requests go.
# The model name the requests ask for (the simulator's --model).
MODEL_NAME="sim-llm"
# shellcheck disable=SC2054 # the commas are one argument of --max-tokens
LOAD_ARGS=(--seed 42 --requests 180 --rate 3 --conversations 16 --prefix-words 600 --long-share 0.15 --max-tokens 8,16,32,64 --model "${MODEL_NAME}")

# load_requests -> the --requests value of LOAD_ARGS (180 in kind)
load_requests() {
  local i
  for ((i = 0; i < ${#LOAD_ARGS[@]}; i++)); do
    [ "${LOAD_ARGS[i]}" = --requests ] && { printf '%s' "${LOAD_ARGS[i + 1]}"; return; }
  done
}
# loadgen <label> <out file> <loadgen args...>: runs one load in the loadgen
# pod, saves the full output, prints the human summary and stores the RESULT
# json in <out file>.json.
loadgen() {
  local label="$1" file="$2"; shift 2
  k -n "${NS}" exec loadgen -- python3 /loadgen/loadgen.py --label "${label}" "$@" > "${file}.log" 2>&1 || true
  grep -E '^\[' "${file}.log" | show
  sed -n 's/^RESULT //p' "${file}.log" | tail -1 > "${file}.json"
  [ -s "${file}.json" ] || { tail -20 "${file}.log" | show; echo '{}' > "${file}.json"; }
}
# per_replica <result json>: one line per model server pod, joining what the
# client saw (requests, by the x-inference-pod header) with what the sampler
# read from that pod's /metrics (by IP). Run right after the load: it maps
# the current pods' IPs to their names.
per_replica() {
  local names
  names="$(k -n "${NS}" get pods -l app=model-server -o json | jq -c '[.items[] | {key: "\(.status.podIP):8000", value: .metadata.name}] | from_entries')"
  jq -r --argjson n "${names}" '.label as $l | .per_pod_requests as $r | .pods | to_entries[]
    | (($n[.key]) // .key) as $name
    | "\($l) \($name): \($r[$name] // $r[.key] // 0) requests, waiting max \(.value.waiting_max) mean \(.value.waiting_mean), running max \(.value.running_max), prefix hit \(.value.prefix_hit_rate)"' "$1"
}
# j <json file> <jq filter>: read one value from a result
j() { jq -r "$2" "$1"; }

# The same scenario scripts run against the EKS part with LAB_TARGET=eks:
# eks/scripts/lib.sh then points every helper above at the EKS cluster.
if [ "${LAB_TARGET:-kind}" = eks ] && [ -z "${EKS_LIB_LOADED:-}" ]; then
  # shellcheck source=/dev/null
  source "${REPO_ROOT}/eks/scripts/lib.sh"
fi
