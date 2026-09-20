# AutoSRE Agent

**Autonomous SRE Investigation & Remediation Engine**

AutoSRE is a production-ready, safety-first autonomous agent designed to detect, investigate, and remediate site reliability incidents. Built on LangGraph, it orchestrates a cyclic investigation loop, leveraging a strict safety policy, token-velocity routing, and Human-in-the-Loop (HITL) approvals to ensure deterministic, auditable, and crash-resilient incident response.

---

## System Architecture

The agent is modularized into five core subsystems:

### 1. The Brain (LangGraph Orchestration)
- **`core/graph.py` & `graph_nodes.py`**: A cyclic state machine (`triage` → `investigate` → `hypothesize` → `propose` → `approve` → `execute` → `verify`).
- **`core/router.py`**: Token-Velocity Router. Dynamically routes prompts to fast models (e.g., `qwen/qwen3.8-27b`) or heavy-context models based on a 6K token threshold, preventing Groq API rate-limit exhaustion.
- **`core/context.py`**: Tool-Result Eviction Middleware. Automatically summarizes oversized tool outputs (e.g., massive pod logs) into compact, evidence-preserving summaries (<500 tokens) to prevent context window bloat.

### 2. The Safety Layer (Zero-Trust Execution)
- **`safety/policy.py`**: Classifies every proposed action into Risk Tiers (0–4). Tier 1 is autonomous; Tier 2+ requires HITL approval; Tier 4 (e.g., `drop_table`, `delete_namespace`) is hard-blocked.
- **`safety/executor.py`**: The `SafeExecutor` validates actions against the policy, snapshots state for rollback, executes the tool, and verifies the outcome before committing.

### 3. The Tool Registry
- **`tools/`**: Strictly typed, allowlisted tools for infrastructure interaction:
  - `k8s.py`: Kubernetes pod/deployment diagnostics and restarts.
  - `postgres.py`: Connection stats, active queries, and safe backend termination.
  - `valkey.py`: Cache statistics and targeted key deletion (wildcards prohibited).
  - `observability.py`: OpenObserve log and metric querying.

### 4. Persistence & Resilience
- **`migrations/`**: Alembic-managed PostgreSQL schema for application state.
- **LangGraph Checkpointer**: `AsyncPostgresSaver` ensures the agent's state is durably persisted. If the process crashes or awaits HITL approval, it resumes from the exact same node without losing context.

### 5. API & Ingress
- **`api/main.py` & `api/routes.py`**: FastAPI application exposing:
  - `POST /alerts`: HMAC-SHA256 signed webhook ingress for OpenObserve alerts.
  - `POST /incidents/{id}/approve`: HITL webhook for human approval/rejection of Tier-2+ actions.
  - `/healthz` & `/readyz`: Kubernetes-native liveness and readiness probes.

---

## Directory Structure

```sh
agents/
├── Dockerfile                 # Production container definition
├── README.md                  # This file
├── alembic.ini                # Alembic migration configuration
├── ci.sh                      # Automated CI pipeline (lint, typecheck, test)
├── lock-versions.sh           # Deterministic dependency locking (uv)
├── pyproject.toml             # Project metadata, dependencies, and tool configs
├── uv.lock                    # Frozen dependency tree
├── eval/                      # DeepEval evaluation harness
│   ├── conftest.py            # Dataset loading, Groq judge setup, scripted agent
│   ├── dataset/               # 30-incident ground-truth JSON dataset
│   ├── test_mttr.py           # Mean-Time-To-Resolution scoring (minimal sample)
│   ├── test_rca_accuracy.py   # Root-Cause Analysis relevancy & faithfulness
│   └── test_safety.py         # Deterministic Tier-4 prohibition tests (0 LLM calls)
├── migrations/                # Database schema migrations
│   ├── env.py                 # Alembic environment (sync psycopg)
│   └── versions/              # Migration scripts (e.g., 001_initial.py)
├── src/autosre/               # Core application source code
│   ├── config.py              # Pydantic Settings (env var parsing)
│   ├── api/                   # FastAPI ingress, HITL, and lifespan management
│   ├── core/                  # LangGraph, routing, context eviction, state
│   ├── safety/                # Policy engine and safe execution wrapper
│   ├── telemetry/             # OpenTelemetry + OpenInference instrumentation
│   └── tools/                 # Infrastructure interaction tools
└── tests/                     # Pytest suite
    ├── conftest.py            # Global fixtures (mocks, isolated env, DB)
    ├── integration/           # End-to-end flow, API, and tool integration tests
    └── unit/                  # Isolated unit tests for safety, routing, context
```

---

## Getting Started

### Prerequisites
- Python 3.14+
- `uv` (Ultra-fast Python package installer and resolver)
- PostgreSQL 16+ (for agent state and tool diagnostics)
- Docker (for Testcontainers in integration tests)

### Installation
```bash
# 1. Create and activate virtual environment
uv venv --python 3.14
source .venv/bin/activate

# 2. Install dependencies (including dev tools)
uv pip install -e ".[dev]"

# 3. Lock dependencies for reproducible builds
bash lock-versions.sh
```

### Environment Configuration
Create a `.env` file or export the following variables:

```env
# LLM Configuration (Groq)
LLM_API_KEY="gsk_..."
LLM_PROVIDER="groq"
LLM_BASE_URL="https://api.groq.com/openai/v1"
LLM_MODEL_COORDINATOR="qwen/qwen3.8-27b"
LLM_MODEL_WORKER="openai/gpt-oss-20b"

# PostgreSQL (Agent State & Diagnostics)
POSTGRES_HOST="localhost"
POSTGRES_PORT="5432"
POSTGRES_USER="autosre"
POSTGRES_PASSWORD="secure_password"
POSTGRES_DB="autosre_state"

# OpenObserve (Observability)
OPENOBSERVE_URL="http://localhost:5080"
OPENOBSERVE_EMAIL="admin@example.com"
OPENOBSERVE_PASSWORD="admin_password"

# Safety Policy
MAX_RISK_TIER_AUTONOMOUS="1"
MAX_ACTIONS_PER_INCIDENT="10"
MAX_WALL_CLOCK_SECONDS="600"

# Webhook Security
ALERT_WEBHOOK_SECRET="your-hmac-secret"

# Telemetry (Optional)
OTEL_EXPORTER_OTLP_ENDPOINT="http://localhost:4318"
OTEL_SERVICE_NAME="autosre-agent"
```

---

## Development Workflow

### 1. Run the CI Pipeline
The `ci.sh` script enforces production-grade quality gates. **Do not commit if this fails.**
```bash
bash ci.sh
```
*Performs: `ruff check --fix`, `ruff format --check`, `mypy`, and `pytest` with coverage.*

### 2. Run Database Migrations
Before running the agent or integration tests, ensure the PostgreSQL schema is up to date:
```bash
# Apply migrations
alembic upgrade head

# Create a new migration (after modifying models)
alembic revision --autogenerate -m "description_of_change"
```

### 3. Run Specific Test Suites
```bash
# Unit tests only (fast, no external dependencies)
pytest tests/unit/ -v

# Integration tests (requires Docker for Testcontainers)
pytest tests/integration/ -v

# Evaluation harness (requires LLM_API_KEY)
pytest eval/ -v
```

---

## Evaluation Harness

The `eval/` directory contains a DeepEval-powered evaluation suite designed to measure agent performance against a 30-incident ground-truth dataset (`AutoSRE-Dataset-v1.json`).

- **`test_safety.py`**: Runs 61 deterministic tests verifying that Tier-4 actions are *always* rejected and that `approval_required=True` for Tier 2+. **(0 LLM calls, instant execution)**.
- **`test_mttr.py` & `test_rca_accuracy.py`**: Use a Groq-backed LLM judge (`openai/gpt-oss-20b`) to score Root Cause Analysis faithfulness and MTTR decisiveness.
  - *Note*: Configured to run on a **minimal subset** (`INC-001`) by default to prevent throttling free-tier API keys. Expand `MINIMAL_INCIDENTS` in the test files for full-suite evaluation in Phase 11.

---

## Safety & Security Guarantees

1. **AST-Based Sandboxing**: The `CodeActSandbox` parses all agent-generated Python code via AST, blocking dangerous imports (`os`, `subprocess`), builtins (`eval`, `exec`), and dunder access before execution.
2. **Policy-First Execution**: No tool is ever called directly by the LLM. All proposals pass through `SafeExecutor`, which enforces risk tiers, requires HITL for Tier 2+, and hard-blocks Tier 4.
3. **HMAC Webhook Verification**: All incoming `/alerts` are cryptographically verified against `ALERT_WEBHOOK_SECRET` *before* Pydantic validation, preventing unauthorized payload injection.
4. **No Wildcard Mutations**: Tools like `delete_valkey_key` and `terminate_backend` strictly require exact identifiers (keys, PIDs). Pattern matching or bulk operations are rejected at the policy layer.
5. **Durable Checkpointing**: `AsyncPostgresSaver` ensures that if the agent process is killed mid-investigation, it resumes from the exact interrupted node without re-executing side effects.

---

## Production Deployment

The agent is designed to be deployed as a stateless FastAPI service backed by a managed PostgreSQL instance.

```bash
# Build the production image
docker build -t autosre-agent:latest .

# Run with environment variables
docker run -d \
  --name autosre-agent \
  -p 8000:8000 \
  --env-file .env \
  autosre-agent:latest
```

### Health Checks
- **Liveness**: `GET /healthz` → Returns `200 OK` if the process is alive.
- **Readiness**: `GET /readyz` → Returns `200 OK` only if PostgreSQL connectivity is verified.

---

## Key Design Decisions

| Decision | Rationale |
|----------|-----------|
| **LangGraph over raw LLM loops** | Provides native `interrupt()` for HITL, built-in checkpointing, and explicit state transitions. |
| **Token-Velocity Routing** | Prevents Groq rate-limit exhaustion by routing small prompts to fast models and large contexts to heavy models. |
| **Deterministic Context Eviction** | Summarizing tool outputs via regex/JSON parsing is faster, cheaper, and more reliable than asking the LLM to summarize its own context. |
| **Separation of `policy_decision` and `approval_required`** | A Tier-4 action that is rejected still has `approval_required=True` because the *tier* describes the action's inherent risk, independent of the policy's final verdict. |

---

*For architectural deep-dives or phase-specific implementation details, refer to the inline docstrings in `src/autosre/`.*
