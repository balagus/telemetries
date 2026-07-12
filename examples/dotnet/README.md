# .NET (ASP.NET Core) example

Sends traces, metrics, and logs to Alloy via OTLP gRPC.

```bash
OTEL_SERVICE_NAME=dotnet-api \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
dotnet run
```

Generate traffic:

```bash
curl localhost:5000/orders
curl -X POST localhost:5000/orders
```

Notes:

- The OTLP exporter defaults to `http://localhost:4317`; in containers set
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://alloy:4317`.
- `AddAspNetCoreInstrumentation` + `AddHttpClientInstrumentation` cover
  incoming/outgoing HTTP automatically; use `ActivitySource`/`Meter` for
  custom spans and business metrics as shown in `Program.cs`.
- For zero-code instrumentation of existing apps, see the
  [OpenTelemetry .NET automatic instrumentation](https://opentelemetry.io/docs/zero-code/dotnet/)
  (profiler-based, no source changes required).
