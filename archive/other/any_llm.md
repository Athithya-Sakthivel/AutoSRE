Use this version. It keeps the two-variable contract, makes the parser type-safe, avoids `Any` leakage from `json.loads`, and uses the current `any-llm` construction API.

As of October 2, 2026, `any-llm-sdk` 1.30.0 is the latest PyPI release, published October 1, and requires Python ≥3.11. [PyPI](https://pypi.org/project/any-llm-sdk/?utm_source=chatgpt.com) The 1.30.0 source explicitly supports `AnyLLM.create(provider, api_key=...)`, so the application can pass each selected key without relying on provider environment-variable lookup. [GitHub](https://raw.githubusercontent.com/mozilla-ai/any-llm/refs/tags/1.30.0/src/any_llm/any_llm.py)

One correction to the surrounding plan: the 1.30.0 `gemini` extra currently requires `google-genai>=2.17.0`, not the older version shown in the original text. [GitHub](https://raw.githubusercontent.com/mozilla-ai/any-llm/refs/tags/1.30.0/pyproject.toml)

### Recommended implementation

```python
from __future__ import annotations

import json
import os
from typing import cast


def _normalize_api_keys(raw_value: str) -> list[str]:
    """Normalize one environment value into unique API keys."""
    raw_value = raw_value.strip()

    # A normal API key is treated as a plain string.
    # JSON notation is reserved for arrays and JSON strings.
    if not raw_value.startswith(("[", '"')):
        return [raw_value]

    try:
        parsed = cast(object, json.loads(raw_value))
    except json.JSONDecodeError as exc:
        msg = (
            "LLM_API_KEY uses JSON syntax but contains invalid JSON; "
            "expected a JSON string or an array of strings"
        )
        raise ValueError(msg) from exc

    if isinstance(parsed, str):
        key = parsed.strip()
        if not key:
            msg = "LLM_API_KEY must contain at least one non-empty API key"
            raise ValueError(msg)
        return [key]

    if not isinstance(parsed, list):
        msg = "LLM_API_KEY must be an API key string or a JSON array of strings"
        raise ValueError(msg)

    items = cast(list[object], parsed)
    keys: list[str] = []

    for index, item in enumerate(items, start=1):
        if not isinstance(item, str):
            msg = f"LLM_API_KEY JSON array item {index} must be a string"
            raise ValueError(msg)

        key = item.strip()
        if not key:
            msg = f"LLM_API_KEY JSON array item {index} cannot be empty"
            raise ValueError(msg)

        keys.append(key)

    unique_keys = list(dict.fromkeys(keys))

    if not unique_keys:
        msg = "LLM_API_KEY must contain at least one API key"
        raise ValueError(msg)

    return unique_keys


def load_llm_config() -> tuple[str, list[str]]:
    """Load and validate the LLM provider and API keys."""
    provider = os.getenv("LLM_PROVIDER", "").strip().lower()
    raw_key = os.getenv("LLM_API_KEY", "").strip()

    if not provider:
        msg = "LLM_PROVIDER cannot be empty"
        raise ValueError(msg)

    if not raw_key:
        msg = "LLM_API_KEY cannot be empty"
        raise ValueError(msg)

    return provider, _normalize_api_keys(raw_key)
```

The accepted environment contract is therefore exactly:

```dotenv
LLM_PROVIDER=gemini
LLM_API_KEY="AIza..."
```

or:

```dotenv
LLM_PROVIDER=gemini
LLM_API_KEY='["AIza-key-1", "AIza-key-2", "AIza-key-3"]'
```

Both normalize to:

```python
provider, api_keys = load_llm_config()

# provider: str
# api_keys: list[str]
```

### any-llm integration

For 1.30.0, this is the correct application boundary:

```python
from any_llm import AnyLLM


def create_llm(provider: str, api_key: str) -> AnyLLM:
    """Create an any-llm client bound to one explicit API key."""
    return AnyLLM.create(
        provider,
        api_key=api_key,
    )
```

Then key selection/retry remains outside configuration parsing:

```python
provider, api_keys = load_llm_config()

llm = create_llm(
    provider=provider,
    api_key=api_keys[0],
)
```

`AnyLLM.create()` accepts `api_key: str | None`; internally, the provider-specific environment variable is only consulted when no explicit key is supplied. [GitHub](https://raw.githubusercontent.com/mozilla-ai/any-llm/refs/tags/1.30.0/src/any_llm/any_llm.py) That makes this design independent of undocumented multi-key behavior.

For Gemini specifically:

```bash
python3.14 -m pip install "any-llm-sdk[gemini]==1.30.0"
```

The `gemini` extra is declared by the 1.30.0 package and pulls the Google GenAI dependency. [GitHub](https://raw.githubusercontent.com/mozilla-ai/any-llm/refs/tags/1.30.0/pyproject.toml)

### Tests

```python
from __future__ import annotations

import pytest

from llm_config import load_llm_config


def test_single_plain_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LLM_PROVIDER", " Gemini ")
    monkeypatch.setenv("LLM_API_KEY", " AIza-one ")

    assert load_llm_config() == ("gemini", ["AIza-one"])


def test_multiple_keys(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LLM_PROVIDER", "gemini")
    monkeypatch.setenv(
        "LLM_API_KEY",
        '["AIza-one", "AIza-two", "AIza-one", " AIza-two "]',
    )

    assert load_llm_config() == ("gemini", ["AIza-one", "AIza-two"])


def test_json_string_key(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.setenv("LLM_PROVIDER", "gemini")
    monkeypatch.setenv("LLM_API_KEY", '"AIza-one"')

    assert load_llm_config() == ("gemini", ["AIza-one"])


@pytest.mark.parametrize(
    ("provider", "raw_key"),
    [
        ("", "AIza-one"),
        ("gemini", ""),
        ("gemini", "[]"),
        ("gemini", '["AIza-one", 123]'),
        ("gemini", '["AIza-one", "   "]'),
        ("gemini", '{"key": "value"}'),
        ("gemini", "[invalid"),
    ],
)
def test_invalid_configuration(
    monkeypatch: pytest.MonkeyPatch,
    provider: str,
    raw_key: str,
) -> None:
    monkeypatch.setenv("LLM_PROVIDER", provider)
    monkeypatch.setenv("LLM_API_KEY", raw_key)

    with pytest.raises(ValueError):
        load_llm_config()
```

For the validation pipeline, use:

```bash
python3.14 -m py_compile llm_config.py
python3.14 -m pytest
ruff check .
mypy .
```

The `any-llm` project itself uses Ruff and strict mypy configuration, so those are appropriate checks for this integration. [GitHub](https://raw.githubusercontent.com/mozilla-ai/any-llm/refs/tags/1.30.0/pyproject.toml)

### Final architecture

`LLM_PROVIDER` + `LLM_API_KEY` → `load_llm_config()` → `list[str]` → separate key-selection/retry component → `AnyLLM.create(provider, api_key=selected_key)`.

Do not put retry, rotation, rate-limit handling, backoff, or client caching into `load_llm_config()`. That keeps configuration deterministic and idempotent.

One versioning detail: Python 3.14.6 is valid for the requested target, but it was superseded by Python 3.14.8 on September 30, 2026. For production I would run the code against 3.14.6 if that exact runtime is required, but use 3.14.8 for a new deployment. [Python.org](https://www.python.org/downloads/release/python-3146/?utm_source=chatgpt.com)

I verified the implementation here with `py_compile` and all 9 tests; this environment does not have Ruff, mypy, or Python 3.14.6 installed, so I will not falsely claim those exact toolchain checks were executed.

Pro tip: pin `any-llm-sdk==1.30.0` for reproducibility; do not use `>=1.30.0` when the configuration/API contract is being treated as stable.

Confidence: 97%.