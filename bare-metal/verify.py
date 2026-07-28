#!/usr/bin/env python3
"""Prove the pipeline works end to end: push OTLP through Alloy, then read the
same telemetry back out of Tempo, Loki and Mimir.

Run it via `./stack.sh verify`, which supplies the endpoints from defaults.sh.
Standalone use works too if the matching environment variables are exported.

Only the standard library is used, so there is nothing to install.
"""
import json
import os
import random
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BIND = os.environ.get("BIND_ADDR", "127.0.0.1")
ALLOY_OTLP = f"http://{BIND}:{os.environ.get('ALLOY_OTLP_HTTP_PORT', '4318')}"
LOKI_URL = os.environ.get("LOKI_URL", f"http://{BIND}:3100")
TEMPO_URL = os.environ.get("TEMPO_URL", f"http://{BIND}:3200")
MIMIR_URL = os.environ.get("MIMIR_URL", f"http://{BIND}:9009")

SERVICE = "telemetry-stack-verify"
trace_id = "%032x" % random.getrandbits(128)
span_id = "%016x" % random.getrandbits(64)
now = time.time_ns()

GREEN, RED, DIM, RESET = "\033[32m", "\033[31m", "\033[2m", "\033[0m"


def post(path, payload):
    req = urllib.request.Request(
        ALLOY_OTLP + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        return r.status


def get(url):
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return r.status, json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()[:200]
    except Exception as e:  # connection refused, timeout, ...
        return 0, str(e)


resource = {"attributes": [{"key": "service.name", "value": {"stringValue": SERVICE}}]}


def push():
    post("/v1/traces", {"resourceSpans": [{"resource": resource, "scopeSpans": [{"spans": [{
        "traceId": trace_id, "spanId": span_id, "name": "GET /orders", "kind": 2,
        "startTimeUnixNano": str(now), "endTimeUnixNano": str(now + 25_000_000),
        "attributes": [{"key": "http.route", "value": {"stringValue": "/orders"}}],
        "status": {"code": 1},
    }]}]}]})

    # Carries the same trace_id as the span, which is what makes the
    # logs <-> traces correlation in Grafana work.
    post("/v1/logs", {"resourceLogs": [{"resource": resource, "scopeLogs": [{"logRecords": [{
        "timeUnixNano": str(now), "severityNumber": 9, "severityText": "INFO",
        "body": {"stringValue": "verify: order placed"},
        "traceId": trace_id, "spanId": span_id,
    }]}]}]})

    post("/v1/metrics", {"resourceMetrics": [{"resource": resource, "scopeMetrics": [{"metrics": [{
        "name": "verify_orders", "unit": "1",
        "sum": {"aggregationTemporality": 2, "isMonotonic": True, "dataPoints": [{
            "asDouble": 42.0, "startTimeUnixNano": str(now), "timeUnixNano": str(now),
            "attributes": [{"key": "status", "value": {"stringValue": "ok"}}],
        }]},
    }]}]}]})


def check_tempo():
    s, b = get(f"{TEMPO_URL}/api/traces/{trace_id}")
    if s == 200 and isinstance(b, dict) and b.get("batches"):
        names = [sp["name"] for bt in b["batches"]
                 for ss in bt.get("scopeSpans", []) for sp in ss.get("spans", [])]
        return True, f"trace {trace_id[:16]}… found, spans={names}"
    return False, f"trace not in Tempo yet (status {s})"


def check_loki():
    q = urllib.parse.quote(f'{{service_name="{SERVICE}"}}')
    url = (f"{LOKI_URL}/loki/api/v1/query_range?query={q}&limit=5"
           f"&start={now - 10**10}&end={now + 10**10}")
    s, b = get(url)
    if s == 200 and isinstance(b, dict) and b.get("data", {}).get("result"):
        stream = b["data"]["result"][0]
        line = stream["values"][0][1]
        linked = trace_id in json.dumps(stream)
        return True, f"log line {line!r}; trace_id attached: {linked}"
    return False, f"log not in Loki yet (status {s})"


def check_mimir():
    q = urllib.parse.quote(f'verify_orders_total{{job="{SERVICE}"}}')
    s, b = get(f"{MIMIR_URL}/prometheus/api/v1/query?query={q}")
    if s == 200 and isinstance(b, dict) and b.get("data", {}).get("result"):
        r = b["data"]["result"][0]
        labels = {k: v for k, v in r["metric"].items() if k != "__name__"}
        return True, f"verify_orders_total = {r['value'][1]} {labels}"
    return False, f"metric not in Mimir yet (status {s})"


def check_span_metrics():
    q = urllib.parse.quote(f'traces_spanmetrics_calls_total{{service="{SERVICE}"}}')
    s, b = get(f"{MIMIR_URL}/prometheus/api/v1/query?query={q}")
    if s == 200 and isinstance(b, dict) and b.get("data", {}).get("result"):
        n = len(b["data"]["result"])
        return True, f"Tempo's generator derived {n} RED series into Mimir"
    return False, "span metrics not generated yet"


def poll(label, fn, timeout=120):
    deadline = time.time() + timeout
    detail = "timed out"
    while time.time() < deadline:
        ok, detail = fn()
        if ok:
            print(f"  {GREEN}PASS{RESET}  {label}\n        {DIM}{detail}{RESET}")
            return True
        time.sleep(2)
    print(f"  {RED}FAIL{RESET}  {label}\n        {DIM}{detail}{RESET}")
    return False


def main():
    print(f"Pushing traces, logs and metrics to Alloy at {ALLOY_OTLP}")
    try:
        push()
    except Exception as e:
        print(f"  {RED}FAIL{RESET}  could not reach Alloy: {e}")
        print("\n  Is the stack running? Try ./stack.sh status")
        return 1
    print(f"  service.name={SERVICE}  trace_id={trace_id}\n")

    print("Reading it back out of the backends "
          "(span metrics take up to a minute to appear):")
    results = [
        poll("Tempo   received the trace", check_tempo),
        poll("Loki    received the log, correlated to the trace", check_loki),
        poll("Mimir   received the metric", check_mimir),
        poll("Mimir   received Tempo's generated span metrics", check_span_metrics, timeout=180),
    ]

    if all(results):
        print(f"\n{GREEN}All checks passed{RESET} — the pipeline works end to end.")
        return 0
    print(f"\n{RED}Some checks failed.{RESET} Check ./stack.sh logs <component>.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
