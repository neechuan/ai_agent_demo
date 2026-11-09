# Resolved Issues

## No traces in Galileo although the Collector reaches the backend

**Resolved:** 2026-11-08

### Symptom

- The OTel Collector could reach the Galileo OTLP endpoint
  (`https://api.multitenant.galileocloud.io/otel/traces`) and Galileo accepted
  every export with HTTP 200.
- The Galileo console (`console.multitenant.galileocloud.io`) showed **no
  traces** in the `Chat` project. The `platform`, `bank` and `default` log streams
  existed but each one had 0 traces.
- After each chat turn, the Collector logged a warning from the
  **`otlp_http/galileo_default`** exporter:

  ```text
  Partial success response ... "otelcol.component.id": "otlp_http/galileo_default"
  "message": "Group 0: No GenAI patterns detected in spans. Ensure spans contain
  standard OTEL GenAI attributes or are from a supported framework.",
  "dropped_spans": 3
  ```

### Root cause

FastAPI **0.162+ has built-in OpenTelemetry tracing**, and it is **on by
default** once a global `TracerProvider` exists. `setup_telemetry()` in
[backend/app/telemetry/otel.py](backend/app/telemetry/otel.py) sets one, so
FastAPI wrapped every request in three spans of its own (`scope=fastapi`):
`POST /chat`, `fastapi.endpoint` and `fastapi.dependencies`. FastAPI's
`POST /chat` became the **root of every trace**.

This conflicts with the app's design. `otel.py` intentionally does *not* enable
HTTP auto-instrumentation, because the app's own `agent_chat.http` `POST /chat`
span should be the root. The Collector then split each trace:

| Spans | `domain.name` | Routed to | Outcome |
|---|---|---|---|
| 3 FastAPI spans (including the real root) | missing | `traces/galileo_default` | Galileo dropped them because they have no `gen_ai.*` attributes |
| 12 app and LangChain spans | `platform` | `traces/galileo_platform` | Galileo accepted them, but their top span's parent was the dropped FastAPI root, so the trace never showed up |

The `routing` connector in
[otel-collector.galileo.yaml](observability/collector/otel-collector.galileo.yaml)
routes each **span** separately (`context: span`). A span without `domain.name`
therefore leaves its trace and goes to the default pipeline.

### Fix

1. [backend/app/main.py](backend/app/main.py) disables FastAPI's built-in
   tracing:

   ```python
   app = FastAPI(
       title="Vendor-Agnostic AI Agent Chat Demo",
       lifespan=lifespan,
       telemetry={"tracing": False},
   )
   ```

2. [backend/requirements.txt](backend/requirements.txt) requires at least
   `fastapi>=0.162`, the first version with the `telemetry=` option.

No Collector or Galileo configuration changes were needed.

### Verification

A test chat (`domain=platform`) through the fixed app gave these results:

- The app exported 12 spans, none of them FastAPI spans, all with
  `domain.name=platform` and one root (the app's own `POST /chat`).
- The Collector logged no `Partial success` warnings.
- The trace appeared in Galileo under **Project `Chat` → log stream
  `platform`**.

### Applying the fix

- **Local app:** restart uvicorn (`./5-run-app.sh`).
- **Docker backend:** `docker compose up -d --build backend`.
- In the Galileo console, open the **domain** log stream (`platform`, `bank`,
  `healthcare`, `insurance` or `restaurant`), not `default`. Only spans
  without `domain.name` go to `GALILEO_LOG_STREAM`.

### Troubleshooting tips

- A reachable endpoint or an HTTP 200 response does **not** mean Galileo
  ingested the trace. Check the Collector logs for `Partial success response`.
  Galileo reports dropped spans in that message.
- The Python OTLP exporter does not log partial-success responses, so they only
  appear in the Collector logs:
  `docker compose logs -f --since=1m otel-collector`.
- Every span needs `domain.name` (stamped by `_DomainStampingSpanProcessor` in
  `otel.py`). Any span created outside that scope, such as by a framework's
  auto-instrumentation, splits the trace across log streams.
