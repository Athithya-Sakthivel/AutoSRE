"""Unit tests for LLM call parsing and fallback behaviours."""

from __future__ import annotations

from unittest.mock import patch

import pytest
from agent.llm import LLMError, triage, verify


@pytest.mark.asyncio
async def test_triage_returns_expected_keys():
    mock_response = {
        "choices": [{"message": {"content": '{"service_name":"svc","severity":"error"}'}}]
    }
    with patch("agent.llm._get_client") as mock_client:
        mock_client.return_value.post.return_value.json.return_value = mock_response
        result = await triage({"alert": "test"}, settings=None)  # settings will be loaded
        assert "service_name" in result
        assert "severity" in result


@pytest.mark.asyncio
async def test_verify_requires_phi4_base_url(monkeypatch):
    from infra.config import load_settings

    settings = load_settings()
    monkeypatch.setattr(settings, "phi4_base_url", "")
    with pytest.raises(LLMError, match="PHI4_BASE_URL"):
        await verify({}, settings=settings)
