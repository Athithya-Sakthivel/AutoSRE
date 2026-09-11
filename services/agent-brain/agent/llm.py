"""Production‑ready LLM wrappers with Azure AD passwordless auth."""

from __future__ import annotations

import json
import logging
import re
from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

import httpx
from infra.config import Settings, load_settings

logger = logging.getLogger(__name__)

DEFAULT_TIMEOUT_SECONDS = 90.0

_client: httpx.AsyncClient | None = None


async def init_llm_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
    _client = httpx.AsyncClient(timeout=DEFAULT_TIMEOUT_SECONDS)
    logger.info("LLM HTTP client initialised")


async def close_llm_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
        logger.info("LLM HTTP client closed")


def _get_client() -> httpx.AsyncClient:
    if _client is None:
        raise RuntimeError("LLM client not initialised – call init_llm_client() first")
    return _client


@dataclass(frozen=True, slots=True)
class LLMResult:
    task: str
    model: str
    content: dict[str, Any]
    raw_text: str
    usage: dict[str, Any] | None = None


class LLMError(RuntimeError):
    pass


# ----------------------------------------------------------------- parsing --


def _strip_fences(text: str) -> str:
    cleaned = text.strip()
    if cleaned.startswith("```"):
        cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
        cleaned = re.sub(r"\s*```$", "", cleaned)
    return cleaned.strip()


def _coerce_json_object(text: str) -> dict[str, Any]:
    candidate = _strip_fences(text)
    try:
        value = json.loads(candidate)
        if isinstance(value, dict):
            return value
        return {"result": value}
    except json.JSONDecodeError:
        pass
    start = candidate.find("{")
    end = candidate.rfind("}")
    if start != -1 and end != -1 and end > start:
        snippet = candidate[start : end + 1]
        value = json.loads(snippet)
        if isinstance(value, dict):
            return value
        return {"result": value}
    return {"text": candidate}


def _extract_text(response_data: Mapping[str, Any]) -> str:
    if "choices" in response_data and isinstance(response_data["choices"], Sequence):
        choices = response_data["choices"]
        if choices:
            choice0 = choices[0]
            if isinstance(choice0, Mapping):
                message = choice0.get("message")
                if isinstance(message, Mapping):
                    content = message.get("content")
                    if isinstance(content, str):
                        return content
                    if isinstance(content, list):
                        parts = [
                            part.get("text", "") for part in content if isinstance(part, Mapping)
                        ]
                        if parts:
                            return "".join(parts)
                text = choice0.get("text")
                if isinstance(text, str):
                    return text
    if "output_text" in response_data and isinstance(response_data["output_text"], str):
        return response_data["output_text"]
    if "content" in response_data and isinstance(response_data["content"], str):
        return response_data["content"]
    return json.dumps(dict(response_data), ensure_ascii=False)


# ---------------------------------------------------------- auth helpers --


def _is_azure_endpoint(base_url: str) -> bool:
    return "azure" in base_url.lower() or "/openai/v1" in base_url.lower()


async def _get_auth_headers(base_url: str, api_key: str | None) -> dict[str, str]:
    """Return auth headers, preferring Azure AD when appropriate."""
    headers: dict[str, str] = {"Content-Type": "application/json"}

    if _is_azure_endpoint(base_url):
        try:
            from azure.identity import DefaultAzureCredential
        except ImportError:
            logger.warning("azure-identity not installed – cannot use Azure AD")
        else:
            try:
                credential = DefaultAzureCredential()
                token = credential.get_token("https://cognitiveservices.azure.com/.default")
                headers["Authorization"] = f"Bearer {token.token}"
                return headers
            except Exception:
                pass  # fall through to API key

    if api_key:
        if _is_azure_endpoint(base_url):
            headers["api-key"] = api_key
        else:
            headers["Authorization"] = f"Bearer {api_key}"
    return headers


# ------------------------------------------------------- LLM invocations --


async def _post_chat_completion(
    *,
    base_url: str,
    api_key: str | None,
    model: str,
    messages: list[dict[str, str]],
    temperature: float,
    max_tokens: int | None = None,
) -> dict[str, Any]:
    url = base_url.rstrip("/") + "/chat/completions"
    headers = await _get_auth_headers(base_url, api_key)
    payload: dict[str, Any] = {"model": model, "messages": messages, "temperature": temperature}
    if max_tokens is not None:
        payload["max_tokens"] = max_tokens

    client = _get_client()
    response = await client.post(url, headers=headers, json=payload)
    response.raise_for_status()
    return response.json()


async def _run_task(
    task: str,
    *,
    model: str,
    base_url: str,
    api_key: str | None,
    system_prompt: str,
    payload: Mapping[str, Any],
    temperature: float,
    max_tokens: int | None = None,
) -> LLMResult:
    user_prompt = json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True)
    response_data = await _post_chat_completion(
        base_url=base_url,
        api_key=api_key,
        model=model,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_prompt},
        ],
        temperature=temperature,
        max_tokens=max_tokens,
    )
    raw_text = _extract_text(response_data)
    parsed = _coerce_json_object(raw_text)
    usage = response_data.get("usage") if isinstance(response_data.get("usage"), Mapping) else None
    return LLMResult(
        task=task,
        model=model,
        content=parsed,
        raw_text=raw_text,
        usage=dict(usage) if usage else None,
    )


# ----------------------------------------------------------------- public --


async def triage(payload: Mapping[str, Any], settings: Settings | None = None) -> dict[str, Any]:
    settings = settings or load_settings()
    result = await _run_task(
        "triage",
        model=settings.cohere_model,
        base_url=settings.cohere_base_url,
        api_key=None,  # Azure AD handles auth
        system_prompt=(
            "You are the triage model for an SRE incident agent. "
            "Classify the alert, extract the affected service/resource, and return JSON only. "
            "Required keys: service_name, resource_id, severity, status, summary, investigation_hypothesis. "
            "severity must be one of debug, info, warning, error, critical. "
            f"Default status should be triaged. Service context: {settings.service_name}."
        ),
        payload=payload,
        temperature=0.1,
        max_tokens=700,
    )
    return result.content


async def generate_fix(
    payload: Mapping[str, Any], settings: Settings | None = None
) -> dict[str, Any]:
    settings = settings or load_settings()
    result = await _run_task(
        "generate_fix",
        model=settings.cohere_model,
        base_url=settings.cohere_base_url,
        api_key=None,  # Azure AD handles auth
        system_prompt=(
            "You are the fix-generation model for an SRE incident agent. "
            "Use the investigation evidence and code snippet to propose exactly one primary action. "
            "Return JSON only with keys: proposed_action, fix_confidence, rationale, notes. "
            "proposed_action must contain tool_name and args. "
            "tool_name should be create_pr, restart_aca_revision, or another safe remediation action from the agent system. "
            "fix_confidence must be a number from 0 to 1. "
            f"Service context: {settings.service_name}."
        ),
        payload=payload,
        temperature=0.2,
        max_tokens=900,
    )
    return result.content


async def verify(payload: Mapping[str, Any], settings: Settings | None = None) -> dict[str, Any]:
    settings = settings or load_settings()
    if not settings.phi4_base_url:
        raise LLMError("PHI4_BASE_URL is required for verification calls")
    result = await _run_task(
        "verify",
        model=settings.phi4_model,
        base_url=settings.phi4_base_url,
        api_key=None,  # Azure AD handles auth
        system_prompt=(
            "You are the verification model for an SRE incident agent. "
            "Assess whether the observed traces and logs indicate recovery to baseline. "
            "Return JSON only with keys: error_resolved, confidence, reasoning, baseline_comparison. "
            "error_resolved must be true only if the evidence clearly supports recovery. "
            f"Service context: {settings.service_name}."
        ),
        payload=payload,
        temperature=0.0,
        max_tokens=500,
    )
    return result.content


async def call_llm(
    task: str, payload: Mapping[str, Any], settings: Settings | None = None
) -> dict[str, Any]:
    task_key = task.strip().lower()
    if task_key == "triage":
        return await triage(payload, settings=settings)
    if task_key == "generate_fix":
        return await generate_fix(payload, settings=settings)
    if task_key == "verify":
        return await verify(payload, settings=settings)
    raise ValueError(f"Unsupported LLM task: {task}")


__all__ = [
    "LLMError",
    "LLMResult",
    "call_llm",
    "close_llm_client",
    "generate_fix",
    "init_llm_client",
    "triage",
    "verify",
]
