#!/usr/bin/env python3
"""Small probes for the context scenario.

  stream <url> <words> <max_tokens> [seed]
      One streamed completion. Prints the arrival time of every chunk, then
      a JSON line: TTFT, mean gap between tokens (inter-token latency), total.
  burst <url> <n> <max_tokens> <metrics endpoint>
      n concurrent streamed completions to one model server, while its
      /metrics is sampled: prints the peak of running and waiting requests.

The last line of the output is "RESULT <json>". Standard library only.
"""
import http.client
import json
import random
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, "/loadgen")
from loadgen import WORDS, scrape  # noqa: E402


def prompt(seed, n):
    rng = random.Random(seed)
    return "You are the operations assistant. " + " ".join(rng.choice(WORDS) for _ in range(n))


def stream(url, text, max_tokens, show=True):
    u = urllib.parse.urlparse(url)
    conn = http.client.HTTPConnection(u.hostname, u.port or 80, timeout=120)
    body = json.dumps({"model": "sim-llm", "prompt": text, "max_tokens": max_tokens,
                       "min_tokens": max_tokens, "ignore_eos": True, "stream": True})
    t0 = time.monotonic()
    conn.request("POST", u.path, body=body, headers={"Content-Type": "application/json"})
    resp = conn.getresponse()
    times = []
    for line in resp:
        line = line.strip()
        if line.startswith(b"data:") and line[5:].strip() != b"[DONE]":
            chunk = json.loads(line[5:])
            if any(c.get("text") for c in chunk.get("choices", [])):
                times.append(time.monotonic() - t0)
                if show:
                    print(f"token {len(times):3d} at {times[-1] * 1000:8.1f} ms")
    conn.close()
    gaps = [b - a for a, b in zip(times, times[1:])]
    return {"status": resp.status, "pod": resp.getheader("x-inference-pod", ""), "tokens": len(times),
            "ttft_ms": round(times[0] * 1000, 1) if times else None,
            "itl_ms": round(sum(gaps) / len(gaps) * 1000, 1) if gaps else None,
            "total_ms": round(times[-1] * 1000, 1) if times else None}


def main():
    mode = sys.argv[1]
    if mode == "stream":
        url, words, max_tokens = sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
        seed = int(sys.argv[5]) if len(sys.argv) > 5 else 1
        print("RESULT " + json.dumps(stream(url, prompt(seed, words), max_tokens)))
    elif mode == "burst":
        url, n, max_tokens, metrics = sys.argv[2], int(sys.argv[3]), int(sys.argv[4]), sys.argv[5]
        peak = {"running": 0.0, "waiting": 0.0}
        done = threading.Event()

        def sample():
            while not done.is_set():
                try:
                    m = scrape(metrics)
                    peak["running"] = max(peak["running"], m.get("vllm:num_requests_running", 0.0))
                    peak["waiting"] = max(peak["waiting"], m.get("vllm:num_requests_waiting", 0.0))
                except OSError:
                    pass
                time.sleep(0.1)

        results = []
        threads = [threading.Thread(target=lambda i=i: results.append(stream(url, prompt(100 + i, 50), max_tokens, False)))
                   for i in range(n)]
        s = threading.Thread(target=sample)
        s.start()
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        done.set()
        s.join()
        ttft = sorted(r["ttft_ms"] for r in results if r["ttft_ms"] is not None)
        print("RESULT " + json.dumps({"n": n, "ok": len(ttft), "running_peak": peak["running"],
                                      "waiting_peak": peak["waiting"], "ttft_ms_min": ttft[0] if ttft else None,
                                      "ttft_ms_max": ttft[-1] if ttft else None}))
    else:
        sys.exit(f"unknown mode {mode}")


if __name__ == "__main__":
    main()
