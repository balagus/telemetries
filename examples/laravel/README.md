# Laravel example

Uses the official OpenTelemetry PHP auto-instrumentation for Laravel.
Traces and metrics go straight to Alloy over OTLP HTTP; logs get trace
context injected and can be shipped via a dedicated OTLP Monolog handler.

## 1. Install

Requires PHP 8.1+ and the `opentelemetry` PECL extension:

```bash
pecl install opentelemetry
# then add to php.ini:
#   extension=opentelemetry.so

composer require \
    open-telemetry/opentelemetry-auto-laravel \
    open-telemetry/exporter-otlp \
    open-telemetry/opentelemetry-logger-monolog \
    php-http/guzzle7-adapter
```

## 2. Configure (.env)

Append the contents of [`.env.otel`](.env.otel) to your app's `.env`.
Auto-instrumentation activates as soon as the extension and env vars are
present — HTTP requests, routing, queue jobs, and Eloquent queries are
traced with no code changes.

## 3. Ship logs with trace correlation

Register the OTLP Monolog handler so Laravel logs land in Loki with
`trace_id`/`span_id` attached — see
[`config/logging.otel.php`](config/logging.otel.php) for the channel
definition to merge into your `config/logging.php`, then set
`LOG_CHANNEL=otel` (or add `otel` to your stack channel).

## 4. Custom spans and metrics

See [`app/Http/Controllers/OrderController.php`](app/Http/Controllers/OrderController.php)
for manual spans and counters around business logic.

## Notes

- `OTEL_PHP_AUTOLOAD_ENABLED=true` is what turns instrumentation on;
  remove it (or set `OTEL_SDK_DISABLED=true`) to switch everything off.
- PHP-FPM runs per-request, so the SDK exports on request shutdown. For
  high-traffic apps keep the OTLP endpoint close (sidecar/localhost Alloy)
  and prefer `http/protobuf` (as configured) over gRPC.
- Octane/long-running workers work too; batching then behaves like other
  daemonized runtimes.
