#!/usr/bin/env bash
# Scenario 1, context: what one LLM request looks like to an operator.
#   - one streamed request: the first token waits for the prefill of the whole
#     prompt (TTFT), every next token costs the inter-token latency (ITL);
#   - the same prompt again on the same replica: its prefix is in that
#     replica's KV cache, so the prefill is skipped and TTFT drops;
#   - the same prompt on another replica: cold cache, full TTFT again;
#   - eight requests at once on one replica with max-num-seqs 4: four run,
#     four wait (vllm:num_requests_running / vllm:num_requests_waiting).
# The requests go straight to pod IPs, so it is the model server talking.
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
assert_lab_context

fresh_model_servers
IFS=, read -r -a PODS <<< "$(model_endpoints)"
A="${PODS[0]}"
B="${PODS[1]}"
probe() { k -n "${NS}" exec loadgen -- python3 /loadgen/probe.py "$@"; }
result() { sed -n 's/^RESULT //p' <<< "$1" | tail -1; }

step "one streamed request: 600-word prompt, 16 tokens, replica ${A}"
out="$(probe stream "http://${A}/v1/completions" 600 16 7)"
head -3 <<< "${out}" | show; note "      ..."; grep -E '^token' <<< "${out}" | tail -1 | show
first="$(result "${out}")"
note "${first}"

step "the same prompt again, same replica (prefix in its KV cache)"
second="$(result "$(probe stream "http://${A}/v1/completions" 600 16 7)")"
note "${second}"

step "the same prompt on another replica (${B}, cold cache)"
other="$(result "$(probe stream "http://${B}/v1/completions" 600 16 7)")"
note "${other}"

step "vLLM metrics of replica ${A}"
metrics="$(k -n "${NS}" exec loadgen -- python3 -c "
import urllib.request
for l in urllib.request.urlopen('http://${A}/metrics').read().decode().splitlines():
    if l.startswith(('vllm:num_requests', 'vllm:kv_cache_usage', 'vllm:prefix_cache', 'vllm:cache_config_info')):
        print(l)")"
show <<< "${metrics}"
hits="$(grep '^vllm:prefix_cache_hits_total' <<< "${metrics}" | awk '{ print int($NF) }')"
queries="$(grep '^vllm:prefix_cache_queries_total' <<< "${metrics}" | awk '{ print int($NF) }')"

step "eight requests at once on replica ${A} (max-num-seqs 4)"
burst="$(result "$(probe burst "http://${A}/v1/completions" 8 64 "${A}")")"
note "${burst}"
printf '%s\n%s\n%s\n%s\n' "${first}" "${second}" "${other}" "${burst}" > "${OUT}/01-context.json"

step "Checks"
ttft1="$(jq -r '.ttft_ms | floor' <<< "${first}")"
itl1="$(jq -r '.itl_ms | floor' <<< "${first}")"
ttft2="$(jq -r '.ttft_ms | floor' <<< "${second}")"
ttft3="$(jq -r '.ttft_ms | floor' <<< "${other}")"
expect_eq "16 tokens streamed" "16" "$(jq -r .tokens <<< "${first}")"
# 30 ms + about 600 prompt tokens x 0.8 ms: the first token pays the prefill.
expect_ge "TTFT pays the prefill: at least 10x the inter-token latency (TTFT ${ttft1} ms, ITL ${itl1} ms)" "$((itl1 * 10))" "${ttft1}"
expect_ge "inter-token latency is the configured 30 ms or more" 30 "${itl1}"
# Cached prefix: only the overhead and the few uncached tokens are left.
expect_le "same prompt, same replica: TTFT at most a quarter of the cold one (${ttft2} ms vs ${ttft1} ms)" "$((ttft1 / 4))" "${ttft2}"
expect_ge "same prompt, other replica: cold again, TTFT at least 3x the cached one (${ttft3} ms vs ${ttft2} ms)" "$((ttft2 * 3))" "${ttft3}"
expect_ge "prefix cache hits counted on the warm replica (hits ${hits} of ${queries} queried tokens)" 500 "${hits}"
expect_eq "eight requests on one replica: four running at the peak" "4" "$(jq -r '.running_peak | floor' <<< "${burst}")"
expect_eq "eight requests on one replica: four waiting at the peak" "4" "$(jq -r '.waiting_peak | floor' <<< "${burst}")"
finish
