# Galileo Instrumented AI Agent Demo

**COMMUNITY DEVELOPED | SUPPORTED**

A simple chat web UI backed by a LangGraph agent that swaps LLM providers live — **OpenAI**, [**NVIDIA NIM**](https://build.nvidia.com/explore/discover) (kimi-k2.6/Llama), and a **local tiny model** via Ollama.

The app is instrumented with **Galileo** and supports OTEL that can fan out to **any** backend (Galileo, Splunk O11y Cloud, Arize Phoenix, Langfuse, Jaeger, …).

The application only speaks standard OTLP + GenAI semantic conventions. The Collector config (`observability/collector/otel-collector.yaml` or the K8s ConfigMap) is the single place that knows about a backend.

## Prerequisites

- Docker + Docker Compose
- Python 3.11+
- [Ollama](https://ollama.com/download/mac)
- 3rd party LLM API keys:
    - `NVIDIA_API_KEY` (To acquire: <https://build.nvidia.com/models> )
    - `OPENAI_API_KEY` (optional, it might incur cost)
- Clone [this](https://github.com/sonykey2003/ai_agent_demo) repo. 

## How To Demo

Open [http://localhost:8000](http://localhost:8000/) and chat. Use the **Model** dropdown to switch LLM.

The chat session will appear on Galileo portal -\> your\_project -\> your\_log\_stream.


## Quick start - Set It Up In Docker 

> The **OTel Collector runs in Docker**; the **app runs locally** with Python.

**Step 1 — Pull the local model** (one time)

```bash
ollama pull qwen2.5:0.5b
```

**Step 2 — Create and fill in **`.env`

```
cp .env.example .env
```

Then open `.env` and set your Galileo values (from your Galileo console -\> Settings -\> API Keys):

```bash
GALILEO_API_KEY=...
GALILEO_PROJECT=...
GALILEO_LOG_STREAM=...
GALILEO_OTEL_ENDPOINT=...      # your console host with console->api, then /otel/traces
```

Optional: add `NVIDIA_API_KEY` (for the NIM model which has a free endpoint) and/or `OPENAI_API_KEY`.

**Step 3 — Install the backend dependencies**

```bash
python -m venv .venv
source .venv/bin/activate
pip install -r backend/requirements.txt
```

**Step 4 — Start the Collector**

```bash
docker compose up -d otel-collector
```

**Step 5 — Run the app**

```bash
uvicorn app.main:app --app-dir backend -host 0.0.0.0 --port 8000
```

**Step 6 — Open and test**

Go to [http://localhost:8000](http://localhost:8000/), send a message, and switch models with the **Model** dropdown. Your chat appears in Galileo -\> your project -\> your log stream.

**Handy commands**

```
docker compose logs -f otel-collector                  # Debug locally to see the spans send to Galileo
docker compose up -d --force-recreate otel-collector   # reload after editing .env
docker compose down                                    # stop the Collector
```

## Appendix: Switching LLM

- **Per request:** the **Model** dropdown in the UI.
- **Default:** set `LLM_PROVIDER=openai|nim|local` in `.env`.

Keys and models are per-provider in `.env` (see `.env.example`). NIM and OpenAI are both OpenAI-compatible, so only `base_url` / `model` / `api_key` differ — self-hosted NIM works too, just point `NIM_BASE_URL` at your microservice.

## Appendix: How This App Is Instrumented

### 1) App side — three pieces, in `backend/app/telemetry/otel.py`

That's the entire instrumentation. Piece `(c)` is what makes every chat a clean trace: an **agent** span wrapping the **LLM call** (model, prompt, tokens, latency) and any **tool** spans, all in standard OpenInference / `gen_ai.*` attributes Galileo ingests natively. Two `.env` knobs control it: `TELEMETRY_ENABLED` (`false` skips export) and `OTEL_EXPORTER_OTLP_ENDPOINT` (where to send OTLP — the Collector).

### 2) Collector side — route spans to Galileo

The Collector (`observability/collector/otel-collector.yaml`) receives OTLP and forwards it. Galileo's OTel endpoint ingests OpenInference directly, so Galileo is just one exporter:

```yaml
exporters:
  otlp_http/galileo:
    # All settings come from .env (single source of truth).
    traces_endpoint: ${env:GALILEO_OTEL_ENDPOINT}
    headers:
      Galileo-API-Key: ${env:GALILEO_API_KEY}
      project:         ${env:GALILEO_PROJECT}
      logstream:       ${env:GALILEO_LOG_STREAM}

service:
  pipelines:
    traces:
      receivers:  [otlp]
      processors: [batch]
      exporters:  [otlp_http/galileo]
```

### 3) Turn it on

The `GALILEO_*` values live in `.env` (set in **Quick start** Step 3). After editing them, reload the Collector with `docker compose up -d --force-recreate otel-collector`, send a message in the UI, and the trace appears in your Galileo project / log stream.

### (Optional) Swap or fan out to another vendor

Because the app is vendor-neutral, you change **only the Collector** — add an exporter and list it in the pipeline. For example, send to Galileo **and** Arize Phoenix at once:

```yaml
exporters:
  otlp_http/galileo: { ... }                       # as above
  otlp_http/phoenix: { endpoint: http://phoenix:6006 }
service:
  pipelines:
    traces:
      exporters: [otlp_http/galileo, otlp_http/phoenix]
```

> Tip: add a `debug` exporter (`exporters: [debug, otlp_http/galileo]`) to also print every span to `docker compose logs -f otel-collector` while you're learning what gets captured.

## (Optional) Set It Up K8S Deployment Option

> Prereqs: a running Kubernetes cluster with your `kubectl` context set, plus Docker to build the image. Do the steps **in order**.

**Step 1 — Build the backend image** (build context is the **repo root**, not `backend/`)

```bash
docker build -t agent-chat-demo:latest -f backend/Dockerfile .
```

**Step 2 — Make the image reachable by your cluster** (pick the one that matches)

```bash
kind load docker-image agent-chat-demo:latest      # kind
minikube image load agent-chat-demo:latest         # minikube
# remote cluster: push to a registry, then set that image in deploy/k8s/backend.yaml
```

**Step 3 — Create the secret** (model + Galileo keys)

```
cp deploy/k8s/secrets.example.yaml deploy/k8s/secrets.yaml
```

Edit `deploy/k8s/secrets.yaml` and fill in `GALILEO_API_KEY`, `GALILEO_PROJECT`, `GALILEO_LOG_STREAM`, `GALILEO_OTEL_ENDPOINT` (and `NVIDIA_API_KEY` / `OPENAI_API_KEY` if used).

**Step 4 — Apply the manifests in this order**

```bash
kubectl apply -f deploy/k8s/namespace.yaml
kubectl apply -f deploy/k8s/secrets.yaml
kubectl apply -f deploy/k8s/ollama.yaml
kubectl apply -f deploy/k8s/otel-collector.yaml
kubectl apply -f deploy/k8s/backend.yaml
kubectl apply -f deploy/k8s/ingress.yaml      # optional (requires an ingress controller)
```

**Step 5 — Wait until all pods are Ready**

```bash
kubectl -n agent-demo get pods -w
```

The Ollama pod auto-pulls `qwen2.5:0.5b` on first start, so give it a minute.

**Step 6 — Access the app**

```
kubectl -n agent-demo port-forward svc/backend 8000:80
```

Open [http://localhost:8000](http://localhost:8000/). Traces flow to Galileo via the in-cluster Collector.

## Offline evaluation

A lightweight **test suite for the agent**. LLM output is non-deterministic, so instead of `assert ==`, each case pins an `input` to expected substrings, and the harness runs the **real agent** (same providers, tools, guardrails) over the dataset.

Use it as a **quality gate** before shipping a change (prompt, model, or tool) and to **compare models** on identical cases. It exits non-zero if any case fails, so it slots straight into CI.

```bash
source .venv/bin/activate
python eval/run_eval.py --provider local --dataset eval/datasets/smoke.jsonl
#  --provider  local | nim | openai   (omit to use LLM_PROVIDER from .env)
#  --dataset   path to a .jsonl       (default: eval/datasets/smoke.jsonl)
```

Dataset — one JSON object per line; every `expected_contains` substring must appear in the answer (case-insensitive):

```json
{"input": "What is 21 * 2?", "expected_contains": ["42"]}
```

## Project layout

| Path | Purpose |
| --- | --- |
| `backend/app/main.py` | FastAPI app: `/chat` (SSE), `/providers`, `/healthz`, serves UI |
| `backend/app/providers.py` | OpenAI-compatible model factory (swappable providers) |
| `backend/app/agent/` | LangGraph agent, demo tools, pluggable guardrails |
| `backend/app/telemetry/otel.py` | Vendor-neutral OpenTelemetry setup |
| `backend/app/static/index.html` | Minimal streaming chat UI |
| `observability/collector/` | Collector config (the vendor fan-out point) |
| `deploy/k8s/` | Kubernetes manifests |
| `eval/` | Offline evaluation harness + datasets |

