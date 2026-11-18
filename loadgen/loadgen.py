#!/usr/bin/env python3
"""Seeded, open-loop load generator for OpenAI-compatible /v1/completions.

Every run with the same seed sends the same requests at the same offsets:
a few "conversations", each one a long shared prefix (a system prompt plus
history) followed by a short question or a long pasted document, with a
varied max_tokens. Requests are streamed, so the time to first token (TTFT)
is measured on the client: from the request leaving to the first SSE event
carrying text. While the run lasts, a sampler reads the vLLM metrics of every
model server pod (waiting and running requests, KV cache usage, prefix cache
counters) so the summary can say how the load was spread.

Standard library only: it runs from a ConfigMap in a stock python image.
The last line of the output is "RESULT <json>", for the lab scripts.
"""
import argparse
import http.client
import json
import queue
import random
import re
import sys
import threading
import time
import urllib.parse

WORDS = (
    "account address agent alert amount answer apply archive audit backup balance batch "
    "billing bucket budget buffer cache capacity cluster commit config contract cost "
    "customer dashboard deadline debug deploy disk domain draft driver error event export "
    "failure feature field filter forecast gateway graph health history incident index "
    "invoice issue job journal kernel label latency ledger limit log manifest memory "
    "message metric migration mirror model monitor network node notice offset order "
    "owner packet partner patch payment pipeline plan policy pool portal priority "
    "process profile project queue quota record region release replica report request "
    "reserve resource review route runbook sample schedule schema secret segment "
    "service session shard signal snapshot source spend storage stream subnet summary "
    "support table target task team tenant ticket timeline token topic trace traffic "
    "trend usage user vendor version volume warning window worker workload zone"
).split()


def words(rng, n):
    return " ".join(rng.choice(WORDS) for _ in range(n))


def build_workload(args):
    """The request list and arrival offsets, fully determined by the seed."""
    rng = random.Random(args.seed)
    prefixes = []
    for c in range(args.conversations):
        prefixes.append(
            f"You are the operations assistant of team {c}. Context follows. " + words(rng, args.prefix_words)
        )
    requests = []
    t = 0.0
    for i in range(args.requests):
        t += rng.expovariate(args.rate)
        conv = rng.randrange(args.conversations)
        if rng.random() < args.long_share:
            # A pasted document: long and unique, nothing in it is cached anywhere.
            suffix = " Document: " + words(rng, args.long_words) + " Summarize it."
            kind = "long"
        else:
            suffix = " Question: " + words(rng, args.short_words) + "?"
            kind = "short"
        max_tokens = rng.choice(args.max_tokens)
        requests.append({"i": i, "at": t, "conv": conv, "kind": kind,
                         "prompt": prefixes[conv] + suffix, "max_tokens": max_tokens})
    return requests


METRIC_RE = re.compile(r"^(vllm:[a-z_]+)(\{[^}]*\})?\s+([0-9.eE+-]+|NaN)$")


def scrape(endpoint, timeout=2.0):
    host, port = endpoint.rsplit(":", 1)
    conn = http.client.HTTPConnection(host, int(port), timeout=timeout)
    try:
        conn.request("GET", "/metrics")
        body = conn.getresponse().read().decode("utf-8", "replace")
    finally:
        conn.close()
    out = {}
    for line in body.splitlines():
        m = METRIC_RE.match(line)
        if m:
            out[m.group(1)] = out.get(m.group(1), 0.0) + float(m.group(3))
    return out


class Sampler(threading.Thread):
    """Polls every pod's /metrics; keeps max and mean of the gauges."""

    GAUGES = ("vllm:num_requests_waiting", "vllm:num_requests_running", "vllm:kv_cache_usage_perc")

    def __init__(self, pods, interval):
        super().__init__(daemon=True)
        self.pods = pods
        self.interval = interval
        self.stop = threading.Event()
        self.stats = {p: {g: {"max": 0.0, "sum": 0.0} for g in self.GAUGES} for p in pods}
        self.samples = {p: 0 for p in pods}

    def run(self):
        while not self.stop.is_set():
            for p in self.pods:
                try:
                    m = scrape(p)
                except OSError:
                    continue
                self.samples[p] += 1
                for g in self.GAUGES:
                    v = m.get(g, 0.0)
                    s = self.stats[p][g]
                    s["max"] = max(s["max"], v)
                    s["sum"] += v
            self.stop.wait(self.interval)


def counters(pods):
    """Prefix cache and request counters of every pod. A busy model server can
    be slow to answer /metrics: retry with a longer timeout, and report None
    for a pod that never answered rather than a zero that would skew rates."""
    out = {}
    for p in pods:
        m = None
        for _ in range(3):
            try:
                m = scrape(p, timeout=10.0)
                break
            except OSError:
                time.sleep(1)
        out[p] = None if m is None else {
            "hits": m.get("vllm:prefix_cache_hits_total", 0.0),
            "queries": m.get("vllm:prefix_cache_queries_total", 0.0),
            "requests": m.get("vllm:request_success_total", 0.0)}
    return out


class ConnPool:
    """Keep-alive connections shared by all requests. Each connection is
    opened once, so kube-proxy picks its backend once, at connect time."""

    def __init__(self, host, port, size, timeout):
        self.q = queue.Queue()
        for _ in range(size):
            self.q.put(http.client.HTTPConnection(host, port, timeout=timeout))
        self.host, self.port, self.timeout = host, port, timeout

    def get(self):
        return self.q.get()

    def put(self, conn, broken):
        if broken:
            conn.close()
            conn = http.client.HTTPConnection(self.host, self.port, timeout=self.timeout)
        self.q.put(conn)


def send(args, url, pool, req, t0):
    # min_tokens = max_tokens and ignore_eos: every request generates exactly
    # max_tokens tokens, so every scenario asks for the same amount of work.
    body = json.dumps({"model": args.model, "prompt": req["prompt"], "max_tokens": req["max_tokens"],
                       "min_tokens": req["max_tokens"], "ignore_eos": True,
                       "stream": True, "temperature": 0}).encode()
    headers = {"Content-Type": "application/json", "Host": args.host_header or url.netloc}
    rec = {"i": req["i"], "conv": req["conv"], "kind": req["kind"], "max_tokens": req["max_tokens"],
           "status": 0, "ttft_ms": None, "total_ms": None, "pod": "", "error": ""}
    if pool:
        conn = pool.get()
    else:
        headers["Connection"] = "close"
        conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=args.timeout)
    broken = True
    start = time.monotonic()
    rec["sent_s"] = round(start - t0, 3)
    try:
        try:
            conn.request("POST", url.path, body=body, headers=headers)
            resp = conn.getresponse()
        except (BrokenPipeError, ConnectionResetError, http.client.RemoteDisconnected):
            if not pool:
                raise
            # The server closed an idle keep-alive connection (uvicorn, under
            # vLLM, does after a few seconds): reconnect once and resend, as
            # any HTTP client does. The new connection is a new kube-proxy pick.
            conn.close()
            conn = http.client.HTTPConnection(url.hostname, url.port or 80, timeout=args.timeout)
            conn.request("POST", url.path, body=body, headers=headers)
            resp = conn.getresponse()
        rec["status"] = resp.status
        rec["pod"] = resp.getheader("x-inference-pod", "")
        if resp.status != 200:
            rec["error"] = resp.read().decode("utf-8", "replace")[:300]
        else:
            while True:
                line = resp.readline()
                if not line:
                    break
                line = line.strip()
                if not line.startswith(b"data:"):
                    continue
                data = line[5:].strip()
                if data == b"[DONE]":
                    continue
                if rec["ttft_ms"] is None:
                    try:
                        chunk = json.loads(data)
                        if any(c.get("text") for c in chunk.get("choices", [])):
                            rec["ttft_ms"] = round((time.monotonic() - start) * 1000, 1)
                    except ValueError:
                        pass
            broken = resp.getheader("connection", "").lower() == "close"
        rec["total_ms"] = round((time.monotonic() - start) * 1000, 1)
    except (OSError, http.client.HTTPException) as e:
        rec["error"] = f"{type(e).__name__}: {e}"[:300]
    finally:
        if pool:
            pool.put(conn, broken)
        else:
            conn.close()
    return rec


def pct(values, p):
    """Nearest-rank percentile; None for an empty list."""
    if not values:
        return None
    v = sorted(values)
    k = max(0, min(len(v) - 1, int(-(-p * len(v) // 100)) - 1))
    return v[k]


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--url", required=True, help="http://host:port/v1/completions")
    ap.add_argument("--host-header", default="", help="Host header (gateway routes match on it)")
    ap.add_argument("--label", default="run")
    ap.add_argument("--model", default="sim-llm")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--requests", type=int, default=180)
    ap.add_argument("--rate", type=float, default=3.0, help="mean arrivals per second (Poisson)")
    ap.add_argument("--conversations", type=int, default=16)
    ap.add_argument("--prefix-words", type=int, default=600)
    ap.add_argument("--short-words", type=int, default=12)
    ap.add_argument("--long-words", type=int, default=400)
    ap.add_argument("--long-share", type=float, default=0.15)
    ap.add_argument("--max-tokens", type=lambda s: [int(x) for x in s.split(",")], default=[8, 16, 32, 64])
    ap.add_argument("--keepalive", type=int, default=0,
                    help="share N keep-alive connections (0: one connection per request)")
    ap.add_argument("--pods", default="", help="comma-separated ip:port of the model servers, for metrics")
    ap.add_argument("--sample-interval", type=float, default=0.25)
    ap.add_argument("--timeout", type=float, default=120.0)
    ap.add_argument("--dump", action="store_true", help="print every request record")
    args = ap.parse_args()

    url = urllib.parse.urlparse(args.url)
    pods = [p for p in args.pods.split(",") if p]
    workload = build_workload(args)
    pool = ConnPool(url.hostname, url.port or 80, args.keepalive, args.timeout) if args.keepalive else None

    before = counters(pods)
    sampler = Sampler(pods, args.sample_interval)
    sampler.start()
    results = []
    lock = threading.Lock()
    threads = []
    t0 = time.monotonic()

    def worker(r):
        rec = send(args, url, pool, r, t0)
        with lock:
            results.append(rec)

    for r in workload:
        delay = r["at"] - (time.monotonic() - t0)
        if delay > 0:
            time.sleep(delay)
        th = threading.Thread(target=worker, args=(r,), daemon=True)
        th.start()
        threads.append(th)
    for th in threads:
        th.join()
    wall = time.monotonic() - t0
    sampler.stop.set()
    sampler.join()
    after = counters(pods)

    ok = [r for r in results if r["status"] == 200 and r["ttft_ms"] is not None]
    ttft = [r["ttft_ms"] for r in ok]
    total = [r["total_ms"] for r in ok]
    ttft_short = [r["ttft_ms"] for r in ok if r["kind"] == "short"]
    statuses = {}
    for r in results:
        statuses[str(r["status"])] = statuses.get(str(r["status"]), 0) + 1
    # Which replica served each request: the x-inference-pod header when the
    # model server sends it (the simulator does, vLLM does not). Without it,
    # requests per replica come from vllm:request_success_total and the
    # replicas per conversation cannot be measured from the client.
    named = all(r["pod"] for r in ok) and bool(ok)
    seen = [p for p in pods if before[p] is not None and after[p] is not None]
    per_pod = {}
    conv_pods = {}
    if named:
        for r in ok:
            per_pod[r["pod"]] = per_pod.get(r["pod"], 0) + 1
            conv_pods.setdefault(r["conv"], set()).add(r["pod"])
    else:
        for p in seen:
            per_pod[p] = int(after[p]["requests"] - before[p]["requests"])
    hits = sum(after[p]["hits"] - before[p]["hits"] for p in seen)
    queries = sum(after[p]["queries"] - before[p]["queries"] for p in seen)
    pods_out = {}
    for p in pods:
        n = max(1, sampler.samples[p])
        st = sampler.stats[p]
        q = (after[p]["queries"] - before[p]["queries"]) if p in seen else 0
        pods_out[p] = {
            "waiting_max": st["vllm:num_requests_waiting"]["max"],
            "waiting_mean": round(st["vllm:num_requests_waiting"]["sum"] / n, 2),
            "running_max": st["vllm:num_requests_running"]["max"],
            "kv_usage_max": round(st["vllm:kv_cache_usage_perc"]["max"], 3),
            "prefix_hit_rate": round((after[p]["hits"] - before[p]["hits"]) / q, 3) if q else None,
            "metrics_ok": p in seen,
        }
    waiting_max = [v["waiting_max"] for v in pods_out.values()]
    errors = sorted({r["error"] for r in results if r["error"]})[:3]
    summary = {
        "label": args.label, "seed": args.seed, "requests": len(results), "ok": len(ok),
        "statuses": statuses, "wall_s": round(wall, 1),
        "ttft_ms": {"p50": pct(ttft, 50), "p90": pct(ttft, 90), "p99": pct(ttft, 99),
                    "mean": round(sum(ttft) / len(ttft), 1) if ttft else None},
        "ttft_short_ms": {"p50": pct(ttft_short, 50), "p90": pct(ttft_short, 90), "p99": pct(ttft_short, 99)},
        "total_ms": {"p50": pct(total, 50), "p90": pct(total, 90), "p99": pct(total, 99),
                     "mean": round(sum(total) / len(total), 1) if total else None},
        "prefix_hit_rate": round(hits / queries, 3) if queries else None,
        "per_pod_requests": dict(sorted(per_pod.items())),
        "pods_per_conversation_mean": round(sum(len(s) for s in conv_pods.values()) / len(conv_pods), 2)
        if conv_pods else None,
        "pod_header": named,
        "metrics_pods": len(seen),
        "waiting_max_by_pod": waiting_max,
        "pods": pods_out,
        "errors": errors,
    }
    if args.dump:
        for r in sorted(results, key=lambda r: r["i"]):
            print("REQ " + json.dumps(r))
    t, s = summary["ttft_ms"], summary["total_ms"]
    print(f"[{args.label}] {summary['ok']}/{summary['requests']} ok, statuses {statuses}, wall {summary['wall_s']} s")
    print(f"[{args.label}] TTFT ms p50/p90/p99 {t['p50']}/{t['p90']}/{t['p99']} (mean {t['mean']})")
    print(f"[{args.label}] total ms p50/p90/p99 {s['p50']}/{s['p90']}/{s['p99']} (mean {s['mean']})")
    print(f"[{args.label}] prefix cache hit rate {summary['prefix_hit_rate']}, "
          f"pods per conversation {summary['pods_per_conversation_mean']}")
    print(f"[{args.label}] requests per pod {summary['per_pod_requests']}, max waiting per pod {waiting_max}")
    print("RESULT " + json.dumps(summary, sort_keys=True))
    sys.stdout.flush()


if __name__ == "__main__":
    main()
