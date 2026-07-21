# React example (Grafana Faro)

Browser telemetry — errors, web vitals, console logs, custom events, user
sessions, and distributed traces — sent to Alloy's Faro receiver
(`:12347`), which forwards logs to Loki and traces to Tempo.

Faro is the Grafana-native choice for frontend/RUM telemetry. If you
prefer pure OpenTelemetry JS, you can instead point the OTel web SDK's
OTLP HTTP exporter at Alloy `:4318` — but Faro covers errors, vitals, and
sessions out of the box, and its tracing instrumentation is OTel
underneath.

## Setup

1. `npm install`
2. Import the module once, before rendering (first line of `main.tsx`):

   ```ts
   import "./telemetry";
   ```

3. Set `VITE_FARO_URL` per environment (defaults to
   `http://localhost:12347/collect`).

## What you get

- **Errors** — unhandled exceptions/rejections with stack traces
  (upload sourcemaps to Alloy's `faro.receiver` for readable frames).
- **Web vitals** — LCP, CLS, INP, TTFB as metrics.
- **Traces** — fetch/XHR auto-instrumented; `traceparent` propagation
  means a slow API call shows browser + backend spans in one Tempo trace.
- **Custom signals** — `faro.api.pushEvent / pushError / pushMeasurement / pushLog`
  (see `src/OrderButton.tsx`).

## Production notes

- Restrict `cors_allowed_origins` and set an `api_key` on Alloy's
  `faro.receiver`; pass the key via `apiKey` in `initializeFaro`.
- Lower `sessionTracking.samplingRate` for high-traffic apps; error
  capture stays at 100% regardless.
- Never propagate trace headers to third-party origins
  (`propagateTraceHeaderCorsUrls` controls this).
