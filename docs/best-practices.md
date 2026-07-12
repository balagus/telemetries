# Telemetry best practices

Guidance for running this stack beyond the local demo.

## Instrumentation

- **OpenTelemetry everywhere.** Every app speaks OTLP to Alloy; no app
  talks to Loki/Tempo/Mimir directly. This keeps apps vendor-neutral and
  lets you change backends, add processing, or fan out without touching
  application code.
- **Set resource attributes consistently** on every service:
  `service.name`, `service.version`, `deployment.environment`, and
  (in k8s) `service.namespace`/`service.instance.id`. These drive
  correlation, dashboards, and Loki labels. Prefer `OTEL_SERVICE_NAME` /
  `OTEL_RESOURCE_ATTRIBUTES` env vars over hardcoding so the same build
  runs in every environment.
- **Follow semantic conventions** for span/metric/attribute names
  (`http.request.method`, `db.system`, ...) — dashboards, service graphs,
  and Grafana Drilldown depend on them.
- **Prefer auto-instrumentation first**, then add manual spans only
  around business logic worth seeing (payment processing, batch steps).
  Custom metrics should be business-level (`orders_created_total`), not
  re-implementations of what auto-instrumentation already emits.
- **Correlate logs with traces**: emit logs through the OTel logging
  bridge (as all four examples do) so `trace_id`/`span_id` ride along and
  Grafana can jump logs ⇄ traces both ways.

## Cardinality and cost

- **Metrics**: never use unbounded values (user ID, order ID, full URL
  path) as metric labels — each combination is a new time series. Put
  high-cardinality detail in span attributes or log fields instead;
  that's what traces and logs are for.
- **Loki labels**: keep the label set tiny (`service_name`,
  `deployment_environment`, maybe `level`). Everything else belongs in
  structured metadata or the log body — Loki indexes labels only, so
  small label sets are what make it cheap.
- **Trace sampling**: head sampling (`OTEL_TRACES_SAMPLER=parentbased_traceidratio`,
  `OTEL_TRACES_SAMPLER_ARG=0.1`) is the simple lever. For "keep all
  errors and slow requests, sample the rest" add tail sampling in Alloy
  (`otelcol.processor.tail_sampling`) — it must then see *all* spans of a
  trace, which matters once you scale Alloy horizontally (use a
  load-balancing exporter keyed by trace ID).

## Storage and retention

- All three backends write to object storage (MinIO here; S3/GCS/Azure
  in production) — that is the long-term storage layer, and it's cheap.
  Retention knobs in this repo:
  - Loki: `limits_config.retention_period` (90d) enforced by the compactor
  - Tempo: `compactor.compaction.block_retention` (60d)
  - Mimir: `limits.compactor_blocks_retention_period` (1y)
- Typical shape: short trace retention, medium log retention, long
  metric retention — metrics are the cheapest per unit of insight over
  time, and Tempo's metrics-generator preserves RED trends long after
  the raw traces expire.
- Use recording rules in Mimir for expensive queries you dashboard
  frequently.

## Security

- **Change every credential in `.env.example`** and don't commit `.env`.
- Terminate TLS in front of Alloy and Grafana (reverse proxy or native
  TLS) for any non-local deployment; enable auth on the OTLP endpoints
  (e.g. `otelcol.auth.basic`/bearer in Alloy) so only your apps can push.
- The Faro endpoint is internet-facing by definition: restrict
  `cors_allowed_origins`, set an `api_key`, and keep rate limiting on.
- Keep Loki/Tempo/Mimir off the public network entirely — only Alloy
  (ingest) and Grafana (query) need exposure. In production enable
  multi-tenancy (`X-Scope-OrgID`) if multiple teams share the stack.
- Scrub sensitive data at the edge: `otelcol.processor.attributes` /
  `otelcol.processor.redaction` in Alloy can delete or hash attributes
  (emails, tokens, IPs) before anything is stored.

## Scaling path

This compose file runs each backend as a single binary — right for dev,
small teams, and up to moderate volume. The same configs carry over when
you outgrow it:

1. **Vertical + object storage** (this repo): already durable; single
   node is the only limit.
2. **Simple scalable / read-write mode**: Loki and Mimir split into
   read/write/backend targets behind a load balancer.
3. **Microservices on Kubernetes**: deploy the official Helm charts
   (`loki`, `tempo-distributed`, `mimir-distributed`, `k8s-monitoring`)
   with the same storage schema — data written by the single binaries
   remains readable.

Run Alloy as close to the apps as possible (sidecar/daemonset/host
agent) and let it batch and retry — apps should never block on, or know
about, the storage backends.

## Operating the stack itself

- Monitor the monitors: Alloy exposes its own metrics on `:12345`;
  Loki/Tempo/Mimir expose `/metrics` — scrape them with Alloy
  (`prometheus.scrape`) into Mimir and alert on ingestion failures,
  queue growth, and compactor lag.
- Watch for backpressure: OTLP export failures in app logs usually mean
  Alloy limits (memory_limiter) or backend ingestion limits need raising.
- Test retention/deletion policies before you need them for compliance
  (Loki supports per-stream deletion requests via the compactor).
