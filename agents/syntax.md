# AutoSRE Agent: Syntax and Error Resolution Reference

This document systematically catalogs all errors, bugs, and syntax corrections encountered during the development of the AutoSRE Agent. It serves as a definitive reference for maintaining compatibility with Python 3.14, LangGraph 1.2+, Pydantic 2.10+, Ruff strict mode, Mypy strict mode, and the Groq API.

Paste this document into a new chat session to instantly restore deep context regarding the project's architectural constraints and resolved edge cases.

---

## 1. Python 3.14 Specifics

### Error: Multiprocessing Fork Deadlock Warning
- **Error Title**: `DeprecationWarning: This process is multi-threaded, use of fork() may lead to deadlocks in the child.`
- **Root Cause**: Python 3.14 changed the default multiprocessing start method away from `fork` on all platforms. Using `fork` in a multi-threaded environment (like pytest with coverage) is unsafe.
- **Incorrect Syntax**: `CTX = mp.get_context("fork")`
- **Correct Latest Syntax**:
  ```python
  import multiprocessing as mp
  import sys

  if sys.platform.startswith("linux"):
      CTX = mp.get_context("forkserver")
  else:
      CTX = mp.get_context("spawn")
  ```

### Error: Missing Datetime/Timezone Imports
- **Error Title**: `F821 Undefined name 'datetime'` / `Undefined name 'timezone'`
- **Root Cause**: Ruff auto-fixes or manual edits removed standard library imports.
- **Correct Latest Syntax**:
  ```python
  from datetime import datetime, timezone
  # Usage: datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")
  ```

---

## 2. LangGraph 1.2+ Syntax & Behavior

### Error: GraphInterrupt Not Raised
- **Error Title**: `Failed: DID NOT RAISE GraphInterrupt`
- **Root Cause**: In LangGraph 1.2+, `interrupt()` no longer raises an exception to the caller. It pauses execution, persists state, and returns normally. The interrupt payload is accessed via the state.
- **Incorrect Syntax**:
  ```python
  with pytest.raises(GraphInterrupt):
      await graph.ainvoke(state, config=config)
  ```
- **Correct Latest Syntax**:
  ```python
  paused = await graph.ainvoke(state, config=config)
  assert "__interrupt__" in paused
  assert paused["__interrupt__"][0].value["action"]["tool_name"] == "scale_deployment"

  # To resume, pass the resume value directly to ainvoke with the SAME thread_id
  resumed = await graph.ainvoke({"decisions": [{"type": "approve"}]}, config=config)
  ```

### Error: StateGraph Missing Type Arguments
- **Error Title**: `Missing type arguments for generic type "StateGraph" [type-arg]`
- **Root Cause**: Mypy strict mode requires generic types to be parameterized.
- **Incorrect Syntax**: `graph: StateGraph = StateGraph(AgentState)`
- **Correct Latest Syntax**: `graph: StateGraph[AgentState] = StateGraph(AgentState)`

### Error: Add Node Overload Mismatch
- **Error Title**: `No overload variant of "add_node" of "StateGraph" matches argument types`
- **Root Cause**: LangGraph 1.2+ strictly types node functions. They must accept `(state: AgentState, config: RunnableConfig)` and return a dict of state updates.
- **Correct Latest Syntax**:
  ```python
  from langchain_core.runnables import RunnableConfig
  from autosre.core.state import AgentState

  async def my_node(state: AgentState, config: RunnableConfig) -> dict[str, Any]:
      # Extract dependencies
      ctx = config["configurable"]["graph_context"]
      return {"current_phase": "next_phase"}
  ```

### Error: Infinite Loop / OOM During Testing
- **Error Title**: Test hangs indefinitely and exhausts system memory.
- **Root Cause**: A routing bug or mock misconfiguration causes the graph to cycle infinitely, accumulating unbounded state in memory.
- **Correct Latest Syntax**: Always include a `recursion_limit` in the invocation config.
  ```python
  config = {
      "configurable": {"thread_id": "test-1", "graph_context": ctx, "sre_context": sre_ctx},
      "recursion_limit": 30, # Hard cap to prevent OOM
  }
  await graph.ainvoke(state, config=config)
  ```

---

## 3. FastAPI & Pydantic 2.10+

### Error: Ruff B008 (Depends in Defaults)
- **Error Title**: `B008 Do not perform function call 'Depends' in argument defaults`
- **Root Cause**: Ruff flags function calls in default arguments as they are evaluated at definition time, not request time.
- **Incorrect Syntax**: `runner: IncidentRunner = Depends(get_runner)`
- **Correct Latest Syntax**:
  ```python
  from typing import Annotated
  from fastapi import Depends

  async def endpoint(runner: Annotated[IncidentRunner, Depends(get_runner)]):
      pass
  ```

### Error: Ruff B904 (Exception Chaining)
- **Error Title**: `B904 Within an except clause, raise exceptions with raise ... from err`
- **Root Cause**: Raising a new exception inside an `except` block without chaining obscures the original traceback.
- **Incorrect Syntax**:
  ```python
  except Exception as e:
      raise HTTPException(status_code=503, detail="DB not ready")
  ```
- **Correct Latest Syntax**:
  ```python
  except Exception as e:
      raise HTTPException(status_code=503, detail="DB not ready") from e
  ```

### Error: Pydantic Settings Validation Missing Fields
- **Error Title**: `pydantic_core._pydantic_core.ValidationError: 6 validation errors for Settings (llm, postgres, etc. missing)`
- **Root Cause**: Calling `Settings()` directly in tests does not trigger the nested `env_prefix` resolution that the `get_settings()` factory handles.
- **Incorrect Syntax**: `return Settings()`
- **Correct Latest Syntax**:
  ```python
  from autosre.config import get_settings

  @pytest.fixture
  def test_settings(monkeypatch):
      # monkeypatch.setenv(...) for all required vars
      return get_settings()
  ```

---

## 4. Ruff & Mypy Strict Rules

### Error: Redundant Cast
- **Error Title**: `Redundant cast to "GraphContext" [redundant-cast]`
- **Root Cause**: Mypy automatically narrows types after an `isinstance` check. Explicit casting is redundant and flagged.
- **Incorrect Syntax**:
  ```python
  if isinstance(ctx, GraphContext):
      return cast(GraphContext, ctx)
  ```
- **Correct Latest Syntax**:
  ```python
  if isinstance(ctx, GraphContext):
      return ctx # Mypy knows this is GraphContext
  ```

### Error: TypedDict Literal Mismatch
- **Error Title**: `Incompatible types (expression has type "str", TypedDict item "status" has type "Literal['proposed', 'confirmed', 'rejected']")`
- **Root Cause**: Assigning a dynamic `str` to a `Literal` field fails strict type checking.
- **Correct Latest Syntax**: Validate the string against the allowed literals before assignment, or use a targeted ignore after validation.
  ```python
  valid_statuses = {"proposed", "confirmed", "rejected"}
  raw_status = str(item.get("status", "proposed")).strip()
  if raw_status not in valid_statuses:
      raw_status = "proposed"

  # Assign with ignore if mypy still complains about the dynamic derivation
  status=raw_status,  # type: ignore[typeddict-item]
  ```

### Error: Nested If Statements (SIM102)
- **Error Title**: `SIM102 Use a single if statement instead of nested if statements`
- **Correct Latest Syntax**: Combine conditions using `and`.
  ```python
  # Incorrect
  if isinstance(node, ast.Attribute):
      if node.attr in {"eval", "exec"}:
          raise Error()

  # Correct
  if isinstance(node, ast.Attribute) and node.attr in {"eval", "exec"}:
      raise Error()
  ```

### Error: Missing Iterator Import
- **Error Title**: `F821 Undefined name 'Iterator'`
- **Correct Latest Syntax**: `from collections.abc import Iterator` (Do not use `typing.Iterator` in Python 3.9+).

---

## 5. Groq API & DeepEval Integration

### Error: Model Decommissioned / Not Found
- **Error Title**: `openai.NotFoundError: Error code: 404 - {'error': {'message': 'The model llama-3.3-70b-versatile does not exist or you do not have access to it.'}}` OR `model_decommissioned`
- **Root Cause**: Groq frequently rotates free-tier model IDs. `llama-3.3-70b-versatile` and `llama3-70b-8192` have been deprecated for developer tiers.
- **Correct Latest Syntax**: Use `openai/gpt-oss-20b` or `llama3-70b-8192` (verify current availability, but `openai/gpt-oss-20b` is the stable fallback).
  ```python
  EVAL_JUDGE_MODEL = "openai/gpt-oss-20b"
  ```

### Error: DeepEval OpenAI Key Configuration
- **Error Title**: `deepeval.errors.DeepEvalError: OpenAI API key is not configured.`
- **Root Cause**: DeepEval defaults to OpenAI. Groq is OpenAI-compatible, but requires explicit `base_url` and key mapping.
- **Correct Latest Syntax**:
  ```python
  import os
  from deepeval.models import OpenAIModel

  # Map the project's LLM_API_KEY to what DeepEval expects
  os.environ.setdefault("OPENAI_API_KEY", os.getenv("LLM_API_KEY"))
  os.environ.setdefault("GROQ_API_KEY", os.getenv("LLM_API_KEY"))

  judge = OpenAIModel(
      model="openai/gpt-oss-20b",
      api_key=os.getenv("OPENAI_API_KEY"),
      base_url="https://api.groq.com/openai/v1",
      temperature=0.0,
  )
  ```

### Error: DeepEval Deprecation Warning
- **Error Title**: `DeprecationWarning: 'LLMTestCaseParams' is deprecated and will be removed in a future release. Use 'SingleTurnParams' instead.`
- **Correct Latest Syntax**:
  ```python
  from deepeval.test_case import LLMTestCase, SingleTurnParams

  # Usage:
  evaluation_params=[
      SingleTurnParams.INPUT,
      SingleTurnParams.ACTUAL_OUTPUT,
      SingleTurnParams.EXPECTED_OUTPUT,
  ]
  ```

---

## 6. Testing & CI Quirks

### Error: Pytest cache_clear on Plain Function
- **Error Title**: `AttributeError: 'function' object has no attribute 'cache_clear'`
- **Root Cause**: The `get_settings` function in `config.py` is not decorated with `@lru_cache`, so it lacks the `cache_clear` method.
- **Correct Latest Syntax**:
  ```python
  if hasattr(get_settings, "cache_clear"):
      get_settings.cache_clear()
  ```

### Error: Testcontainers Postgres Deprecation
- **Error Title**: `DeprecationWarning: testcontainers.postgres is deprecated, use testcontainers.community.postgres instead`
- **Correct Latest Syntax**:
  ```python
  from testcontainers.community.postgres import PostgresContainer
  ```

### Error: AgentRunResult Missing Attributes
- **Error Title**: `AttributeError: 'AgentRunResult' object has no attribute 'approval_required'`
- **Root Cause**: The `AgentRunResult` dataclass was missing fields expected by the safety evaluation tests.
- **Correct Latest Syntax**:
  ```python
  @dataclass
  class AgentRunResult:
      # ... existing fields ...
      approval_required: bool = False
      policy_decision: str = "allowed"

  # Crucial Logic: approval_required is a property of the tier, not the outcome.
  # A Tier-4 rejected action still has approval_required=True.
  approval_required = action_tier is not None and action_tier >= 2
  ```

---

## 7. Telemetry Initialization Order

### Error: Telemetry Not Initialized
- **Error Title**: `RuntimeError: init_telemetry() must be called before instrument_fastapi()`
- **Root Cause**: `instrument_fastapi(app)` was called in `create_app()` before the lifespan ran `init_telemetry()`.
- **Correct Latest Syntax**: Move instrumentation inside the lifespan, strictly after initialization.
  ```python
  @asynccontextmanager
  async def lifespan(app: FastAPI) -> AsyncIterator[None]:
      settings: Settings = app.state.settings

      # 1. Initialize telemetry FIRST
      shutdown_telemetry_fn = init_telemetry(settings)

      # 2. NOW it is safe to instrument
      instrument_fastapi(app)

      yield
      # ... cleanup ...
  ```

---

## 8. Dependency Resolution (CodeAct Sandbox)

### Error: ModuleNotFoundError in Sandbox
- **Error Title**: `ModuleNotFoundError: No module named 'numpy'` / `'pandas'`
- **Root Cause**: The CodeAct sandbox allowlisted these modules but they were not installed in the virtual environment.
- **Correct Latest Syntax**: Add to `pyproject.toml` dependencies.
  ```toml
  dependencies = [
      # ...
      "numpy==2.5.3",
      "pandas==3.0.6",
  ]
  ```

---

## Summary of Critical Invariants

1. **LangGraph Nodes**: Must be `async def node(state: AgentState, config: RunnableConfig) -> dict[str, Any]`.
2. **Groq Models**: Always use `openai/gpt-oss-20b` or verify current free-tier availability. Never use `llama-3.3-70b-versatile`.
3. **Safety Policy**: `approval_required` is derived strictly from `action_tier >= 2`. It is independent of `policy_decision`. A rejected Tier-4 action still has `approval_required=True`.
4. **FastAPI Dependencies**: Always use `Annotated[Type, Depends(func)]`. Never `Type = Depends(func)`.
5. **Multiprocessing**: Always use `forkserver` on Linux in Python 3.14+ to avoid multi-threaded deadlock warnings.
6. **DeepEval**: Map `LLM_API_KEY` to `OPENAI_API_KEY` and explicitly set `base_url="https://api.groq.com/openai/v1"`. Use `SingleTurnParams`, not `LLMTestCaseParams`.
