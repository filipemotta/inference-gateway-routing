# Serving LLMs on Kubernetes: the lab

Companion repository for the article *Serving LLMs on Kubernetes: Why Your Service Is the Wrong Backend*. A Kubernetes Service splits connections, not work. This lab sends the same seeded LLM workload to three model servers through a plain Service and through an InferencePool with an Endpoint Picker, measures time to first token (TTFT), total latency, queues and prefix-cache hits side by side, and then takes the Endpoint Picker away to show what each failure mode does. Every script asserts what it claims and prints the numbers it measured.

| Script | Scenario | What it proves |
|---|---|---|
| `scripts/01-context.sh` | What one LLM request looks like | One streamed request: the first token waits for the prefill of the whole prompt, every next token costs the inter-token latency. The same prompt again on the same replica has its prefix in that replica's KV cache and its TTFT drops several times; on another replica it is cold again. Eight requests at once on a replica that runs four: four run, four wait (`vllm:num_requests_running`, `vllm:num_requests_waiting`) |
| `scripts/02-service.sh` | The Service as the backend | The workload through the Service's ClusterIP on keep-alive connections (kube-proxy picks a pod per connection) and through the Istio gateway with the Service as the route backend (Envoy picks per request, `LEAST_REQUEST`). Either way each conversation lands on almost every replica, so its prefix is prefilled again on each, and the prefix-cache hit rate stays low |
| `scripts/03-inference-pool.sh` | The InferencePool and the Endpoint Picker | Same gateway, same workload, the InferencePool as the backend: the Endpoint Picker keeps each conversation on one replica, the prefix-cache hit rate goes up, and TTFT p50, p90 and p99 and total latency go down against both baselines. The pool's `failureMode` is written in the manifest, `FailClose`, and the API keeps it |
| `scripts/04-epp-down.sh` | The Endpoint Picker on the critical path | With the Endpoint Picker scaled to zero and `FailClose`, every request on the pool route gets HTTP 500 at the gateway (`ext_proc_error_gRPC_error_14`), while the route to the plain Service keeps working and the InferencePool status stays green. With `FailOpen` every request is answered, the access log looks healthy, and latency and cache hits fall back to the baseline of scenario 2. The script checks the failure mode in the gateway's Envoy configuration, not only in the InferencePool object (see Limits), and reads the gateway metrics the alerts in `observability/` use: the refused requests in `istio_requests_total` and the ext_proc counters `streams_failed` and `failure_mode_allowed` (saved as `out/04-gateway-*.prom`) |

The model servers in kind are the [vLLM simulator](https://github.com/llm-d/llm-d-inference-sim) (`llm-d-inference-sim`): it speaks the vLLM OpenAI API, streams tokens, simulates a KV cache with prefix caching, and exposes the vLLM Prometheus metrics the Endpoint Picker reads, without a GPU. Its latency profile is the "7-8B model on an L40S-class GPU" row of the simulator's own latency reference: 30 ms plus 0.8 ms per uncached prompt token before the first token, 30 ms per next token, four requests at once per replica.

The workload (`loadgen/loadgen.py`, standard library only, run in a pod): 180 streamed completions with Poisson arrivals at 3 per second, 16 conversations that each repeat a 600-word shared prefix (a system prompt and history) followed by a short question or, in 15% of the requests, a long pasted document, and 8 to 64 output tokens per request (`min_tokens` equal to `max_tokens`, so every run asks for the same work). Seed 42: every scenario sends the same requests at the same offsets. Every measured run starts from freshly restarted model servers, with cold caches.

## The EKS part: real GPUs, real vLLM

The same scenarios 2, 3 and 4 also run on EKS with GPUs, in `eks/`: the very same Gateway, routes, InferencePool, Endpoint Picker and load generator manifests, with vLLM v0.32.0 serving `Qwen/Qwen2.5-1.5B-Instruct` on three g5.xlarge nodes (one NVIDIA A10G, 24 GB, each). Terraform in three stacks (`eks/terraform`): an S3 state bucket, a VPC with one NAT gateway, and EKS 1.37 with a system node group (2x t4g.large) and a GPU node group (3x g5.xlarge, Bottlerocket NVIDIA AMI, which ships the NVIDIA driver and device plugin; tainted so only the model servers run there). The GPU node group spans four AZs, because on-demand GPU capacity in one AZ can run out (`InsufficientInstanceCapacity`). The lab was planned on g6.xlarge (NVIDIA L4); when it was built, on-demand g6.xlarge and g6.2xlarge capacity was exhausted in four AZs of us-east-1, so it runs on g5.xlarge, one instance type for all replicas. To try another type, change `eks.node_groups.gpu.instance_types` in `eks/terraform/02-eks/variables.tf` and `GPU_INSTANCE_TYPE` in `eks/scripts/lib.sh`. The workload is scaled to the real model: longer prefixes, more conversations, longer answers, a higher rate (`eks/scripts/lib.sh`, overridable with `EKS_LOAD_ARGS`). Between runs the scripts reset every replica's prefix cache through vLLM's `/reset_prefix_cache` instead of restarting it.

On EKS the scenario scripts run unchanged (`LAB_TARGET=eks`) and print the same side-by-side numbers, with three differences worth knowing before you read them. vLLM does not name the replica in its responses (the simulator sends `x-inference-pod`), so requests per replica come from `vllm:request_success_total` and the replicas-per-conversation checks are reported as not measurable. The thresholds of the checks were calibrated on the simulator, whose replicas run four requests at once and hold a small KV cache; a 1.5B model on a 24 GB GPU batches dozens of requests and keeps every prefix of this workload in cache, so on EKS those latency and cache checks are recorded as observations (`[OBS]`) instead of pass or fail. `00-infra.sh` suspends `AZRebalance` on the GPU Auto Scaling group: when capacity puts every GPU node in one AZ, the group otherwise rebalances later and terminates nodes that are serving the model.

These are the steps the published EKS numbers come from, run one at a time:

```bash
export AWS_PROFILE=<profile of the AWS account to use>       # required, never defaulted
export EXPECTED_AWS_ACCOUNT=<12-digit account ID>            # the lab refuses any other account
bash eks/scripts/00-infra.sh                     # state bucket, VPC, EKS 1.37, system and GPU node groups
bash eks/scripts/01-platform.sh                  # CRDs, Istio, vLLM on the GPU nodes (pulls the image and the model)
LAB_TARGET=eks bash scripts/02-service.sh        # the same scenario scripts as in kind
LAB_TARGET=eks bash scripts/03-inference-pool.sh
LAB_TARGET=eks bash scripts/04-epp-down.sh
bash eks/scripts/teardown.sh                     # always, also after a failed step
```

`eks/scripts/run-all.sh` chains the same steps and adds a trap that runs `teardown.sh` on exit, failure or Ctrl-C, plus a three-hour watchdog. It was not exercised end to end: the measured run went step by step, with GPU capacity retries between `00-infra.sh` attempts. Treat its trap and watchdog as untested, keep an eye on the clock and run `teardown.sh` yourself if anything looks wrong. The `AZRebalance` suspension and its check in `00-infra.sh` were added after the measured run, where the same command was applied by hand; that part of the script has not run either.

It creates billable resources in your account: about US$ 3.30 per hour while it runs, most of it the three g5.xlarge (on-demand, us-east-1). `teardown.sh` destroys the stacks in reverse, deletes network interfaces the VPC CNI can leave behind, and then checks independently for leftover instances, volumes, interfaces, Elastic IPs, NAT gateways, load balancers, the VPC, IAM roles, the cluster and the state bucket. The EKS API endpoint is public and allow-listed to your address only; the EKS part uses its own kubeconfig (`eks/out/kubeconfig`) and refuses to run unless its context points at the API server of the cluster it created. CI only validates it statically.

## Requirements

Docker (Docker Desktop on macOS, or Docker Engine on Linux), about 3 CPUs and 4 GiB of memory free, `curl`, `jq` and `bash`. Everything else is downloaded by `tools/install-cli.sh` into `./bin`, pinned and checked against the published SHA-256, or fetched by the scripts into `./out` and checked against a SHA-256 pinned in `scripts/lib.sh`:

- kubectl v1.37.2, kind v0.33.0, Helm v4.3.2; promtool from Prometheus 3.16.0 for the alert tests (`bash tools/install-cli.sh promtool`)
- Node image `kindest/node:v1.37.0` (pinned by digest, the default of kind v0.33.0)
- Gateway API v1.6.1 (standard CRDs), Gateway API Inference Extension v1.6.2 (InferencePool CRD)
- Istio 1.32.0 (Helm charts `base` and `istiod`, with `ENABLE_GATEWAY_API_INFERENCE_EXTENSION=true`)
- Endpoint Picker: `ghcr.io/llm-d/llm-d-router-endpoint-picker:v1.0.0` (llm-d-router v1.0.0; manifests derived from its `llm-d-router-gateway` chart)
- Model servers: `ghcr.io/llm-d/llm-d-inference-sim:v1.2.0`; load generator: `python:3.14.10-slim-trixie` (both pinned by digest)
- EKS part: Terraform 1.11 or later with the AWS provider 6.x, the AWS CLI, and `vllm/vllm-openai:v0.32.0` (pinned by digest)

Tested on macOS (Apple silicon, Docker Desktop with 5 CPUs and 8 GiB). The workflow in `.github/workflows/lab.yml` runs the same lab on Linux amd64 in GitHub Actions.

## Run

```bash
bash scripts/test-all.sh
```

It creates the cluster, runs the four scenarios, prints a summary of assertions and the side-by-side table, and deletes the cluster at the end, also when a step fails or you press Ctrl-C. To keep the cluster for exploration, run `KEEP=1 bash scripts/test-all.sh` and remove it later with `bash scripts/teardown.sh`. The raw results of every run are in `out/` (one JSON per run, `out/side-by-side.txt`).

Scenarios run in order after `bash scripts/00-cluster.sh`: 3 compares itself with the results of 2, and 4 with those of 2 and 3.

## Safety

The lab never reads or writes `~/.kube/config`. It uses its own kubeconfig in `out/`, passes the context explicitly to every `kubectl` and `helm` call, and refuses to run if that context does not point at a local kind API server. Helm and the downloads use empty registry and Docker configurations of their own, so your Docker credential helper is never called. Nothing outside the kind cluster and `./bin` and `./out` is touched.

## Limits

The simulator models the latency of a GPU, it does not reproduce one: the kind numbers show the mechanism (prefix-cache locality, queueing at a replica's concurrency limit), the EKS part shows what a real model on a real GPU does with the same routing. The EKS model is small (1.5B parameters) and its KV cache on a 24 GB GPU is large compared with this workload, so cache eviction plays a smaller part there than on a busy production server.

The Endpoint Picker used here is the full-featured one from [llm-d-router](https://github.com/llm-d/llm-d-router): since the Gateway API Inference Extension v1.6.0 it lives there, and the Inference Extension repository keeps the InferencePool API, the protocol and a lightweight reference picker for conformance tests. The llm-d-router chart sets `failureMode: FailOpen` on the pools it creates; the InferencePool API default is `FailClose`. This lab's pool writes `FailClose` explicitly, and `validate.sh` fails on any InferencePool in the repository that leaves `failureMode` out.

With Istio 1.32.0, changing `failureMode` on an existing InferencePool updated the Service Istio generates for the pool but not the gateway's ext_proc configuration until istiod recomputed the route (an istiod restart, or a change to the HTTPRoute's spec, did it). Scenario 4 therefore checks the mode in the gateway's Envoy configuration (`pilot-agent request GET config_dump`) and restarts istiod when the change has not arrived. The Endpoint Picker runs as one replica, the chart's default; high availability (leader election) is not covered.

## Alerts

`observability/alerts.yaml` is a plain Prometheus rule file (load it with `rule_files`, or paste its groups into a PrometheusRule if you run the Prometheus Operator). One alert per way the Endpoint Picker can fail you:

| Alert | Fires when | Reads |
|---|---|---|
| `InferencePoolRequestsRefusedAtGateway` | `FailClose`: more than 5% of a pool's requests get a 500 from the gateway without reaching a model server, for 2 minutes | `istio_requests_total` with `response_code="500"`, `destination_workload="unknown"`, on the Service Istio generates for the pool (`<pool>-ip-<8 hex digits>`) |
| `InferencePoolPickerBypassed` | `FailOpen`: the gateway lets requests through without the picker, for 2 minutes | `envoy_http_ext_proc_failure_mode_allowed` |
| `EndpointPickerUnavailable` | no Endpoint Picker target is scraped successfully, for 1 minute | `up{job="model-server-epp"}` |
| `PrefixCacheHitRateDropped` | the prefix-cache hit rate of a model falls more than 15% below its median of the previous 6 hours, for 15 minutes | `vllm:prefix_cache_hits_total`, `vllm:prefix_cache_queries_total` |
| `ModelTimeToFirstTokenP99High` | TTFT p99 above 2.5 s with more than 0.1 requests per second, for 10 minutes | `vllm:time_to_first_token_seconds_bucket` |

The thresholds are parameters, marked `PARAMETER` in the file: set them from your own SLOs and traffic. What the rules assume about your setup:

- The gateway's Istio metrics are scraped (port 15020, `/stats/prometheus`, the `prometheus.io/*` annotations Istio puts on the gateway pod). The ext_proc counters exist only because `manifests/gateway/gateway.yaml` adds a `proxyStatsMatcher` for them through `spec.infrastructure.annotations`; Istio keeps a minimal set of Envoy stats otherwise.
- The Endpoint Picker's metrics port (9090) is scraped by a job named `model-server-epp` (with the Prometheus Operator, a ServiceMonitor on the `model-server-epp` Service gives that job name). The endpoint requires a bearer token whose identity may `get` the non-resource URL `/metrics`; without it the target is down and the alert fires, which is deliberate: you are just as blind.
- The model servers' `/metrics` are scraped and carry `model_name`, as vLLM and the simulator both do.

The rule names, selectors and label sets come from the lab: scenario 4 saves the gateway's metrics around each phase and asserts that the refused requests show up exactly as the first alert selects them and that `failure_mode_allowed` counts every request let through under `FailOpen`. The lab runs no Prometheus, so the rules themselves are tested with `promtool test rules` on synthetic series (`observability/alerts.test.yaml`): each alert fires in its bad case and stays silent in healthy and look-alike cases (a model server answering 500, a plain Service with no upstream, a one-minute blip, an idle model, a short dip, a slow tail under 1%, three requests a minute). `tools/test-alerts.sh` runs them and then removes one guard at a time from the rules, checking that the tests catch every removal.

## Static validation

```bash
bash validate.sh
```

Runs `bash -n` and `shellcheck` on every script, `terraform fmt`, `init -backend=false` and `validate` on every stack, `tools/check-failure-mode.sh` (every InferencePool must set `spec.endpointPickerRef.failureMode` to `FailOpen` or `FailClose`; it first runs against fixtures that must fail), `tools/test-alerts.sh` (needs promtool: `bash tools/install-cli.sh promtool`), and `kubeconform` on every manifest (the InferencePool, the Istio DestinationRule and the kind cluster config have no schema in kubeconform's catalog and are skipped by it; the lab validates them by applying them).

## License

MIT
