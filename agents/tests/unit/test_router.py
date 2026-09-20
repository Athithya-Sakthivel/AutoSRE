"""Unit tests for TokenVelocityRouter."""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from autosre.config import LLMConfig
from autosre.core.router import TokenVelocityRouter


@pytest.fixture
def llm_config() -> LLMConfig:
    return LLMConfig(
        api_key="test-key",
        base_url="https://api.groq.com/openai/v1",
        provider="groq",
        model_coordinator="qwen/qwen3.8-27b",
        model_worker="groq/compound",
    )


@pytest.fixture
def router(
    llm_config: LLMConfig,
) -> TokenVelocityRouter:
    return TokenVelocityRouter(
        llm_config,
        threshold_tokens=6000,
    )


class TestTokenCounting:
    def test_empty_messages_have_no_fake_response_tokens(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        assert router.count_tokens([]) == 0

    def test_single_message_is_nonzero(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        tokens = router.count_tokens(
            [
                {
                    "role": "user",
                    "content": "Hello",
                }
            ]
        )

        assert tokens > 0

    def test_large_content_is_large(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        large_text = "word " * 10000

        tokens = router.count_tokens(
            [
                {
                    "role": "user",
                    "content": large_text,
                }
            ]
        )

        assert tokens > 9000

    def test_tools_are_included_in_estimate(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        messages = [
            {
                "role": "user",
                "content": "Use the tool.",
            }
        ]

        tools = [
            {
                "type": "function",
                "function": {
                    "name": "check",
                    "description": "A" * 500,
                    "parameters": {
                        "type": "object",
                    },
                },
            }
        ]

        assert router.count_tokens(
            messages,
            tools=tools,
        ) > router.count_tokens(messages)


class TestModelSelection:
    def test_small_prompt_uses_qwen(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        assert (
            router.select_model(
                [
                    {
                        "role": "user",
                        "content": "Short",
                    }
                ]
            )
            == "qwen/qwen3.8-27b"
        )

    def test_large_prompt_uses_compound(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        large_text = "word " * 7000

        assert (
            router.select_model(
                [
                    {
                        "role": "user",
                        "content": large_text,
                    }
                ]
            )
            == "groq/compound"
        )

    def test_large_prompt_with_custom_tools_stays_on_qwen(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        large_text = "word " * 7000

        tools = [
            {
                "type": "function",
                "function": {
                    "name": "check",
                },
            }
        ]

        model = router.select_model(
            [
                {
                    "role": "user",
                    "content": large_text,
                }
            ],
            tools=tools,
        )

        assert model == "qwen/qwen3.8-27b"

    @pytest.mark.parametrize(
        ("estimated_tokens", "expected_model"),
        [
            (
                5999,
                "qwen/qwen3.8-27b",
            ),
            (
                6000,
                "groq/compound",
            ),
            (
                6001,
                "groq/compound",
            ),
        ],
    )
    def test_switches_exactly_at_6k_threshold(
        self,
        router: TokenVelocityRouter,
        monkeypatch: pytest.MonkeyPatch,
        estimated_tokens: int,
        expected_model: str,
    ) -> None:
        monkeypatch.setattr(
            router,
            "count_tokens",
            lambda messages, **kwargs: estimated_tokens,
        )

        model = router.select_model(
            [
                {
                    "role": "user",
                    "content": "boundary",
                }
            ]
        )

        assert model == expected_model


class TestModelResolution:
    def test_configured_models_are_normalized_for_groq(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        assert router._resolve_model("coordinator") == "qwen/qwen3.8-27b"

        assert router._resolve_model("worker") == "groq/compound"

        assert router._resolve_model("fast") == "qwen/qwen3.8-27b"

        assert router._resolve_model("slow") == "groq/compound"

    def test_groq_qwen_prefixed_id_is_normalized(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        assert router._resolve_model("groq/qwen/qwen3.8-27b") == "qwen/qwen3.8-27b"

    def test_explicit_model_passes_through(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        assert router._resolve_model("gpt-4") == "gpt-4"


class TestAsyncCompletion:
    @staticmethod
    def _response() -> MagicMock:
        response = MagicMock()

        response.usage = MagicMock(
            prompt_tokens=10,
            completion_tokens=5,
            total_tokens=15,
        )

        response.choices = [MagicMock(message=MagicMock(content="Response"))]

        return response

    @pytest.mark.asyncio
    async def test_auto_route_small_prompt_uses_qwen(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.acompletion(
                model="coordinator",
                messages=[
                    {
                        "role": "user",
                        "content": "Short",
                    }
                ],
                temperature=0.3,
            )

        kwargs = mock_completion.call_args.kwargs

        assert kwargs["model"] == "qwen/qwen3.8-27b"

        assert kwargs["temperature"] == 0.3

        assert kwargs["base_url"] == "https://api.groq.com/openai/v1"

        assert kwargs["custom_llm_provider"] == "openai"

        assert kwargs["api_key"] == "test-key"

    @pytest.mark.asyncio
    async def test_auto_route_large_prompt_uses_compound(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        large_text = "word " * 7000

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.acompletion(
                model="coordinator",
                messages=[
                    {
                        "role": "user",
                        "content": large_text,
                    }
                ],
            )

        kwargs = mock_completion.call_args.kwargs

        assert kwargs["model"] == "groq/compound"

    @pytest.mark.asyncio
    async def test_explicit_worker_bypasses_threshold(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.acompletion(
                model="worker",
                messages=[
                    {
                        "role": "user",
                        "content": "tiny",
                    }
                ],
            )

        assert mock_completion.call_args.kwargs["model"] == "groq/compound"

    @pytest.mark.asyncio
    async def test_explicit_fast_bypasses_threshold(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        large_text = "word " * 7000

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.acompletion(
                model="fast",
                messages=[
                    {
                        "role": "user",
                        "content": large_text,
                    }
                ],
            )

        assert mock_completion.call_args.kwargs["model"] == "qwen/qwen3.8-27b"

    @pytest.mark.asyncio
    async def test_explicit_model_does_not_auto_route(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.acompletion(
                model="gpt-4",
                messages=[
                    {
                        "role": "user",
                        "content": "Test",
                    }
                ],
            )

        assert mock_completion.call_args.kwargs["model"] == "gpt-4"

    @pytest.mark.asyncio
    async def test_passes_tools_and_other_kwargs(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        tools = [
            {
                "type": "function",
                "function": {
                    "name": "check",
                },
            }
        ]

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.acompletion(
                model="coordinator",
                messages=[
                    {
                        "role": "user",
                        "content": "Test",
                    }
                ],
                temperature=0.5,
                max_tokens=500,
                tools=tools,
            )

        kwargs = mock_completion.call_args.kwargs

        assert kwargs["temperature"] == 0.5
        assert kwargs["max_tokens"] == 500
        assert kwargs["tools"] == tools

    @pytest.mark.asyncio
    async def test_auto_routed_qwen_429_falls_back_to_compound(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        class RateLimitError(Exception):
            status_code = 429

        mock_completion = AsyncMock(
            side_effect=[
                RateLimitError("too many requests"),
                self._response(),
            ]
        )

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            response = await router.acompletion(
                model="coordinator",
                messages=[
                    {
                        "role": "user",
                        "content": "Short",
                    }
                ],
            )

        assert response is not None
        assert mock_completion.await_count == 2

        assert mock_completion.call_args_list[0].kwargs["model"] == "qwen/qwen3.8-27b"

        assert mock_completion.call_args_list[1].kwargs["model"] == "groq/compound"

    @pytest.mark.asyncio
    async def test_coordinator_call_uses_auto_routing(
        self,
        router: TokenVelocityRouter,
    ) -> None:
        mock_completion = AsyncMock(return_value=self._response())

        with patch(
            "autosre.core.router.litellm.acompletion",
            mock_completion,
        ):
            await router.coordinator_call(
                messages=[
                    {
                        "role": "user",
                        "content": "Test",
                    }
                ],
                temperature=0.3,
            )

        assert mock_completion.call_args.kwargs["model"] == "qwen/qwen3.8-27b"
