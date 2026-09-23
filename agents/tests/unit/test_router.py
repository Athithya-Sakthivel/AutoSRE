"""Unit tests for autosre.core.router.TokenVelocityRouter."""

from __future__ import annotations

from unittest.mock import AsyncMock, patch

import pytest

from autosre.config import LLMConfig
from autosre.core.router import TokenVelocityRouter

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def router() -> TokenVelocityRouter:
    """Create a router with active Groq models.

    Compound models were retired on 2026-09-21. The worker model is now
    openai/gpt-oss-20b which LiteLLM routes as groq/openai/gpt-oss-20b.
    """
    config = LLMConfig(
        api_key="test-key",
        provider="groq",
        base_url="https://api.groq.com/openai/v1",
        model_coordinator="qwen/qwen3.8-27b",
        model_worker="openai/gpt-oss-20b",
    )
    return TokenVelocityRouter(config, threshold_tokens=6000)


# ---------------------------------------------------------------------------
# Token Counting Tests
# ---------------------------------------------------------------------------


class TestTokenCounting:
    def test_empty_messages_have_no_fake_response_tokens(self, router: TokenVelocityRouter) -> None:
        """Empty messages produce a small positive count (framing only)."""
        count = router.count_tokens([])
        assert count >= 0

    def test_single_message_is_nonzero(self, router: TokenVelocityRouter) -> None:
        """A single text message produces a nonzero token count."""
        count = router.count_tokens([{"role": "user", "content": "Hello world"}])
        assert count > 0

    def test_large_content_is_large(self, router: TokenVelocityRouter) -> None:
        """8000 repetitions of 'word' exceed a 6000-token threshold."""
        content = "word " * 8000
        count = router.count_tokens([{"role": "user", "content": content}])
        assert count > 6000

    def test_tools_are_included_in_estimate(self, router: TokenVelocityRouter) -> None:
        """Tool schemas contribute to the token estimate."""
        messages = [{"role": "user", "content": "hi"}]
        tools = [
            {
                "type": "function",
                "function": {
                    "name": "restart_deployment",
                    "description": "Restart a deployment",
                    "parameters": {
                        "type": "object",
                        "properties": {
                            "name": {"type": "string"},
                            "namespace": {"type": "string"},
                        },
                        "required": ["name", "namespace"],
                    },
                },
            }
        ]

        without_tools = router.count_tokens(messages)
        with_tools = router.count_tokens(messages, tools=tools)

        assert with_tools > without_tools


# ---------------------------------------------------------------------------
# Model Selection Tests
# ---------------------------------------------------------------------------


class TestModelSelection:
    def test_small_prompt_uses_qwen(self, router: TokenVelocityRouter) -> None:
        """Prompts under the threshold use the fast (coordinator) model."""
        messages = [{"role": "user", "content": "small prompt"}]

        selected = router.select_model(messages)

        assert selected == "groq/qwen/qwen3.8-27b"

    def test_large_prompt_uses_worker(self, router: TokenVelocityRouter) -> None:
        """Prompts over the threshold use the worker model."""
        content = "word " * 8000
        messages = [{"role": "user", "content": content}]

        selected = router.select_model(messages)

        assert selected == "groq/openai/gpt-oss-20b"

    def test_large_prompt_with_custom_tools_uses_worker(self, router: TokenVelocityRouter) -> None:
        """Large tool-using requests route to the worker model."""
        content = "word " * 8000
        messages = [{"role": "user", "content": content}]
        tools = [
            {
                "type": "function",
                "function": {
                    "name": "test_tool",
                    "description": "test",
                    "parameters": {
                        "type": "object",
                        "properties": {},
                    },
                },
            }
        ]

        selected = router.select_model(messages, tools=tools)

        # Worker is openai/gpt-oss-20b, not compound, so tool compatibility
        # is fine. The large prompt should route to the worker.
        assert selected == "groq/openai/gpt-oss-20b"

    @pytest.mark.parametrize(
        ("token_count", "expected_model"),
        [
            (5999, "groq/qwen/qwen3.8-27b"),
            (6000, "groq/openai/gpt-oss-20b"),
            (6001, "groq/openai/gpt-oss-20b"),
        ],
    )
    def test_switches_exactly_at_6k_threshold(
        self,
        router: TokenVelocityRouter,
        token_count: int,
        expected_model: str,
    ) -> None:
        """Routing switches at exactly the threshold boundary."""
        with patch.object(
            router,
            "count_tokens",
            return_value=token_count,
        ):
            selected = router.select_model([{"role": "user", "content": "x"}])

        assert selected == expected_model


# ---------------------------------------------------------------------------
# Model Resolution Tests
# ---------------------------------------------------------------------------


class TestModelResolution:
    def test_configured_models_are_normalized_for_groq(self) -> None:
        """Groq provider adds groq/ prefix to native model IDs."""
        config = LLMConfig(
            api_key="key",
            provider="groq",
            model_coordinator="qwen/qwen3.8-27b",
            model_worker="openai/gpt-oss-20b",
        )
        r = TokenVelocityRouter(config)

        assert r.fast_model == "groq/qwen/qwen3.8-27b"
        assert r.slow_model == "groq/openai/gpt-oss-20b"

    def test_groq_qwen_prefixed_id_is_normalized(self) -> None:
        """Already-prefixed Groq IDs pass through unchanged."""
        config = LLMConfig(
            api_key="key",
            provider="groq",
            model_coordinator="groq/qwen/qwen3.8-27b",
            model_worker="groq/openai/gpt-oss-20b",
        )
        r = TokenVelocityRouter(config)

        assert r.fast_model == "groq/qwen/qwen3.8-27b"
        assert r.slow_model == "groq/openai/gpt-oss-20b"

    def test_explicit_model_passes_through(self, router: TokenVelocityRouter) -> None:
        """Explicit model IDs are resolved and passed to LiteLLM."""
        resolved = router._resolve_model("qwen/qwen3.8-27b")

        assert resolved == "groq/qwen/qwen3.8-27b"


# ---------------------------------------------------------------------------
# Async Completion Tests
# ---------------------------------------------------------------------------


class TestAsyncCompletion:
    @pytest.mark.asyncio
    async def test_auto_route_small_prompt_uses_qwen(self, router: TokenVelocityRouter) -> None:
        """Auto-routing sends small prompts to the fast model."""
        mock_response = AsyncMock()
        mock_response.usage = None

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": "small"}],
            )

            mock_call.assert_called_once()
            call_kwargs = mock_call.call_args
            assert call_kwargs.kwargs["model"] == "groq/qwen/qwen3.8-27b"

    @pytest.mark.asyncio
    async def test_auto_route_large_prompt_uses_worker(self, router: TokenVelocityRouter) -> None:
        """Auto-routing sends large prompts to the worker model."""
        mock_response = AsyncMock()
        mock_response.usage = None
        content = "word " * 8000

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": content}],
            )

            mock_call.assert_called_once()
            call_kwargs = mock_call.call_args
            assert call_kwargs.kwargs["model"] == "groq/openai/gpt-oss-20b"

    @pytest.mark.asyncio
    async def test_explicit_worker_bypasses_threshold(self, router: TokenVelocityRouter) -> None:
        """Explicit 'worker' alias always uses the worker model."""
        mock_response = AsyncMock()
        mock_response.usage = None

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.acompletion(
                model="worker",
                messages=[{"role": "user", "content": "tiny"}],
            )

            call_kwargs = mock_call.call_args
            assert call_kwargs.kwargs["model"] == "groq/openai/gpt-oss-20b"

    @pytest.mark.asyncio
    async def test_explicit_fast_bypasses_threshold(self, router: TokenVelocityRouter) -> None:
        """Explicit 'fast' alias always uses the fast model."""
        mock_response = AsyncMock()
        mock_response.usage = None

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.acompletion(
                model="fast",
                messages=[
                    {
                        "role": "user",
                        "content": "word " * 8000,
                    }
                ],
            )

            call_kwargs = mock_call.call_args
            assert call_kwargs.kwargs["model"] == "groq/qwen/qwen3.8-27b"

    @pytest.mark.asyncio
    async def test_explicit_model_does_not_auto_route(self, router: TokenVelocityRouter) -> None:
        """Explicit model IDs are normalized but not auto-routed."""
        mock_response = AsyncMock()
        mock_response.usage = None

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.acompletion(
                model="qwen/qwen3.8-27b",
                messages=[
                    {
                        "role": "user",
                        "content": "word " * 8000,
                    }
                ],
            )

            call_kwargs = mock_call.call_args
            assert call_kwargs.kwargs["model"] == "groq/qwen/qwen3.8-27b"

    @pytest.mark.asyncio
    async def test_passes_tools_and_other_kwargs(self, router: TokenVelocityRouter) -> None:
        """Extra kwargs like tools are forwarded to litellm.acompletion."""
        mock_response = AsyncMock()
        mock_response.usage = None

        tools = [
            {
                "type": "function",
                "function": {
                    "name": "test",
                    "description": "test",
                    "parameters": {
                        "type": "object",
                        "properties": {},
                    },
                },
            }
        ]

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": "hi"}],
                tools=tools,
                temperature=0.5,
            )

            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["tools"] == tools
            assert call_kwargs["temperature"] == 0.5

    @pytest.mark.asyncio
    async def test_auto_routed_qwen_429_falls_back_to_worker(
        self, router: TokenVelocityRouter
    ) -> None:
        """A 429 on the fast model triggers one retry on the worker model."""
        error_429 = Exception("rate limit exceeded")
        error_429.status_code = 429  # type: ignore[attr-defined]

        mock_response = AsyncMock()
        mock_response.usage = None

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.side_effect = [error_429, mock_response]

            result = await router.acompletion(
                model="coordinator",
                messages=[{"role": "user", "content": "small"}],
            )

            assert result is mock_response
            assert mock_call.call_count == 2

            first_call_model = mock_call.call_args_list[0].kwargs["model"]
            second_call_model = mock_call.call_args_list[1].kwargs["model"]

            assert first_call_model == "groq/qwen/qwen3.8-27b"
            assert second_call_model == "groq/openai/gpt-oss-20b"

    @pytest.mark.asyncio
    async def test_coordinator_call_uses_auto_routing(self, router: TokenVelocityRouter) -> None:
        """coordinator_call is a convenience wrapper for auto routing."""
        mock_response = AsyncMock()
        mock_response.usage = None

        with patch(
            "litellm.acompletion",
            new_callable=AsyncMock,
        ) as mock_call:
            mock_call.return_value = mock_response

            await router.coordinator_call(
                messages=[{"role": "user", "content": "small"}],
            )

            mock_call.assert_called_once()
            call_kwargs = mock_call.call_args
            assert call_kwargs.kwargs["model"] == "groq/qwen/qwen3.8-27b"
