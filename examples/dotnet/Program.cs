// ASP.NET Core minimal API instrumented with OpenTelemetry.
// Traces + metrics + logs are exported over OTLP to Alloy.
using System.Diagnostics;
using System.Diagnostics.Metrics;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

var builder = WebApplication.CreateBuilder(args);

// Resource attributes identify the service on every signal.
// OTEL_SERVICE_NAME / OTEL_EXPORTER_OTLP_ENDPOINT env vars override these.
var resource = ResourceBuilder.CreateDefault()
    .AddService(serviceName: "dotnet-api", serviceVersion: "1.0.0")
    .AddAttributes(new Dictionary<string, object>
    {
        ["deployment.environment"] = builder.Environment.EnvironmentName.ToLowerInvariant(),
    });

// Custom instruments for business metrics.
var meter = new Meter("DotnetApi");
var ordersCreated = meter.CreateCounter<long>("orders_created_total", description: "Number of orders created");
var activitySource = new ActivitySource("DotnetApi");

builder.Services.AddOpenTelemetry()
    .WithTracing(tracing => tracing
        .SetResourceBuilder(resource)
        .AddSource(activitySource.Name)
        .AddAspNetCoreInstrumentation(o => o.RecordException = true)
        .AddHttpClientInstrumentation()
        .AddOtlpExporter()) // reads OTEL_EXPORTER_OTLP_ENDPOINT, default http://localhost:4317
    .WithMetrics(metrics => metrics
        .SetResourceBuilder(resource)
        .AddMeter(meter.Name)
        .AddAspNetCoreInstrumentation()
        .AddHttpClientInstrumentation()
        .AddRuntimeInstrumentation()
        .AddOtlpExporter());

// Logs through the same pipeline — trace/span IDs are attached automatically.
builder.Logging.AddOpenTelemetry(logging =>
{
    logging.SetResourceBuilder(resource);
    logging.IncludeFormattedMessage = true;
    logging.IncludeScopes = true;
    logging.AddOtlpExporter();
});

var app = builder.Build();

app.MapGet("/orders", (ILogger<Program> log) =>
{
    log.LogInformation("Listing orders");
    using var span = activitySource.StartActivity("db.query.orders");
    span?.SetTag("db.system", "postgresql");
    return Results.Ok(new { orders = Array.Empty<object>() });
});

app.MapPost("/orders", (ILogger<Program> log) =>
{
    var amount = Random.Shared.NextDouble() * 500;
    if (Random.Shared.NextDouble() < 0.1) // simulated failures for the demo
    {
        log.LogError("Payment gateway rejected order of {Amount:C}", amount);
        return Results.StatusCode(502);
    }
    ordersCreated.Add(1, new KeyValuePair<string, object?>("payment.method", "card"));
    log.LogInformation("Order created for {Amount:C}", amount);
    return Results.Ok(new { status = "created", amount });
});

app.Run();
