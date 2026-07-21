"""FastAPI example instrumented with OpenTelemetry (traces, metrics, logs).

Run against the stack:
    pip install -r requirements.txt
    OTEL_SERVICE_NAME=python-api \
    OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
    python main.py
"""
import logging
import random
import time

from fastapi import FastAPI, HTTPException
from opentelemetry import metrics, trace
from opentelemetry._logs import set_logger_provider
from opentelemetry.exporter.otlp.proto.grpc._log_exporter import OTLPLogExporter
from opentelemetry.exporter.otlp.proto.grpc.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

# --- Resource: identifies this service on every signal --------------------
# service.name/version/environment come from OTEL_* env vars when set;
# this is the in-code fallback.
resource = Resource.create(
    {
        "service.name": "python-api",
        "service.version": "1.0.0",
        "deployment.environment": "local",
    }
)

# --- Traces ----------------------------------------------------------------
tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(tracer_provider)
tracer = trace.get_tracer(__name__)

# --- Metrics ---------------------------------------------------------------
metrics.set_meter_provider(
    MeterProvider(
        resource=resource,
        metric_readers=[PeriodicExportingMetricReader(OTLPMetricExporter())],
    )
)
meter = metrics.get_meter(__name__)
order_counter = meter.create_counter(
    "orders_created_total", description="Number of orders created"
)
order_value = meter.create_histogram(
    "order_value", unit="USD", description="Value of created orders"
)

# --- Logs: route stdlib logging through OTLP with trace correlation --------
logger_provider = LoggerProvider(resource=resource)
logger_provider.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter()))
set_logger_provider(logger_provider)
logging.basicConfig(level=logging.INFO)
logging.getLogger().addHandler(LoggingHandler(logger_provider=logger_provider))
log = logging.getLogger("python-api")

# --- App ---------------------------------------------------------------------
app = FastAPI(title="python-api")
FastAPIInstrumentor.instrument_app(app, tracer_provider=tracer_provider)


@app.get("/orders")
def list_orders():
    log.info("listing orders")
    with tracer.start_as_current_span("db.query.orders") as span:
        span.set_attribute("db.system", "postgresql")
        time.sleep(random.uniform(0.01, 0.1))  # simulated work
    return {"orders": []}


@app.post("/orders")
def create_order():
    amount = round(random.uniform(5, 500), 2)
    if random.random() < 0.1:  # simulated failures for the demo
        log.error("payment gateway rejected order", extra={"amount": amount})
        raise HTTPException(status_code=502, detail="payment failed")
    order_counter.add(1, {"payment.method": "card"})
    order_value.record(amount)
    log.info("order created", extra={"amount": amount})
    return {"status": "created", "amount": amount}


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
