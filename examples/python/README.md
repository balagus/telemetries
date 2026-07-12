# Python (FastAPI) example

Sends traces, metrics, and logs to Alloy via OTLP gRPC.

```bash
python -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt
OTEL_SERVICE_NAME=python-api \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
python main.py
```

Generate traffic:

```bash
curl localhost:8000/orders
curl -X POST localhost:8000/orders
```

## Zero-code alternative

For existing apps you can skip all SDK code and use auto-instrumentation:

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
OTEL_SERVICE_NAME=python-api \
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317 \
OTEL_LOGS_EXPORTER=otlp OTEL_PYTHON_LOGGING_AUTO_INSTRUMENTATION_ENABLED=true \
opentelemetry-instrument uvicorn main:app
```
