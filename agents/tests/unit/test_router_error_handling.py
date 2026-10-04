"""Unit tests for LLM error classification and router error handling strategies."""

from __future__ import annotations

import contextlib
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from autosre.config import LLMConfig
from autosre.core.router import (
    LLMBudgetExhaustedError,
    LLMErrorCategory,
    TokenVelocityRouter,
    _compile_patterns,
    classify_llm_error,
)


def _make_error(status_code: int, message: str = "error") -> Exception:
    err = Exception(message)
    err.status_code = status_code  # type: ignore[attr-defined]
    return err


def _mock_response() -> MagicMock:
    response = MagicMock()
    response.usage = None
    response.model = "gemini/gemini-3.5-flash-lite"
    return response


_DEFAULT_QUOTA_PATTERNS = _compile_patterns(
    [
        r"quota exceeded",
        r"daily.*limit",
        r"\bRPD\b",
        r"requests per day",
        r"resource has been exhausted",
        r"exceeded your current quota",
        r"rate limit.*daily",
    ]
)
_DEFAULT_CAPACITY_PATTERNS = _compile_patterns(
    [
        r"high demand",
        r"\boverloaded\b",
        r"\bcapacity\b",
        r"try again later",
        r"temporarily unavailable",
    ]
)
_DEFAULT_AUTH_PATTERNS = _compile_patterns(
    [
        r"invalid api key",
        r"permission denied",
        r"denied access",
        r"\bunauthorized\b",
        r"api key not valid",
        r"project has been denied",
    ]
)


class TestErrorClassification:
    """Test error classification logic."""

    @pytest.mark.parametrize(
        ("status_code", "error_text", "expected_category"),
        [
            (429, "quota exceeded for requests per day", LLMErrorCategory.QUOTA_EXHAUSTED),
            (429, "rate limit exceeded", LLMErrorCategory.TRANSIENT),
            (503, "high demand", LLMErrorCategory.CAPACITY_EXHAUSTED),
            (503, "overloaded server", LLMErrorCategory.CAPACITY_EXHAUSTED),
            (503, "service unavailable", LLMErrorCategory.TRANSIENT),
            (401, "invalid api key", LLMErrorCategory.AUTHENTICATION),
            (403, "permission denied", LLMErrorCategory.AUTHENTICATION),
            (403, "your project has been denied access", LLMErrorCategory.AUTHENTICATION),
            (400, "invalid request", LLMErrorCategory.VALIDATION),
            (404, "model not found", LLMErrorCategory.VALIDATION),
            (500, "internal server error", LLMErrorCategory.TRANSIENT),
            (502, "bad gateway", LLMErrorCategory.TRANSIENT),
            (504, "gateway timeout", LLMErrorCategory.TRANSIENT),
        ],
    )
    def test_classify_error(
        self,
        status_code: int,
        error_text: str,
        expected_category: LLMErrorCategory,
    ) -> None:
        error = _make_error(status_code, error_text)
        category = classify_llm_error(
            error,
            quota_patterns=_DEFAULT_QUOTA_PATTERNS,
            capacity_patterns=_DEFAULT_CAPACITY_PATTERNS,
            auth_patterns=_DEFAULT_AUTH_PATTERNS,
        )
        assert category == expected_category


class TestRouterErrorHandling:
    """Test router behavior for each error category."""

    @pytest.fixture
    def router(self) -> TokenVelocityRouter:
        config = LLMConfig(
            api_key="test-key",
            model_coordinator="gemini/gemini-3.8-flash",
            model_worker="gemini/gemini-3.8-flash",
            fallback_models=["gemini/gemini-3.5-flash-lite", "gemini/gemini-2.0-flash"],
            max_retries=3,
            initial_backoff_seconds=1.0,
            max_backoff_seconds=30.0,
        )
        return TokenVelocityRouter(config, threshold_tokens=6000)

    @pytest.mark.asyncio
    async def test_quota_exhausted_rotates_immediately(self, router: TokenVelocityRouter) -> None:
        error = _make_error(429, "quota exceeded for requests per day")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error, _mock_response()],
            ) as mock_call,
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
        ):
            result, model = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

            assert model == "gemini/gemini-3.5-flash-lite"
            assert mock_call.await_count == 2

    @pytest.mark.asyncio
    async def test_capacity_exhausted_rotates_immediately(
        self, router: TokenVelocityRouter
    ) -> None:
        error = _make_error(503, "This model is currently experiencing high demand")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error, _mock_response()],
            ) as mock_call,
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
        ):
            result, model = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

            assert model == "gemini/gemini-3.5-flash-lite"
            assert mock_call.await_count == 2

    @pytest.mark.asyncio
    async def test_transient_retries_then_rotates(self, router: TokenVelocityRouter) -> None:
        """TRANSIENT errors exhaust retries on the primary model (max_retries=3
        → 4 attempts), then the router rotates to the next fallback model,
        which succeeds on its first attempt. Total: 5 LLM calls."""
        error = _make_error(500, "internal server error")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                # 4 errors exhaust primary retries, 1 success on fallback
                side_effect=[error, error, error, error, _mock_response()],
            ) as mock_call,
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
        ):
            result, model = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

            assert model == "gemini/gemini-3.5-flash-lite"
            assert mock_call.await_count == 5

    @pytest.mark.asyncio
    async def test_authentication_fails_immediately(self, router: TokenVelocityRouter) -> None:
        error = _make_error(401, "invalid api key")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error,
            ) as mock_call,
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
            pytest.raises(LLMBudgetExhaustedError, match="authentication"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert mock_call.await_count == 1

    @pytest.mark.asyncio
    async def test_validation_fails_immediately(self, router: TokenVelocityRouter) -> None:
        error = _make_error(400, "invalid request")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error,
            ) as mock_call,
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
            pytest.raises(LLMBudgetExhaustedError, match="validation"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert mock_call.await_count == 1

    @pytest.mark.asyncio
    async def test_circuit_breaker_prevents_repeated_failures(
        self, router: TokenVelocityRouter
    ) -> None:
        router.circuit_breaker.threshold = 3
        error = _make_error(429, "quota exceeded for requests per day")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error,
            ),
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
        ):
            for _ in range(3):
                with contextlib.suppress(LLMBudgetExhaustedError):
                    await router.acompletion(
                        model="auto",
                        messages=[{"role": "user", "content": "hi"}],
                    )

        assert await router.circuit_breaker.is_open("gemini/gemini-3.8-flash")

    @pytest.mark.asyncio
    async def test_permission_denied_403_fails_immediately(
        self, router: TokenVelocityRouter
    ) -> None:
        error = _make_error(403, "Your project has been denied access")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error,
            ) as mock_call,
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
            pytest.raises(LLMBudgetExhaustedError, match="authentication"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert mock_call.await_count == 1

    @pytest.mark.asyncio
    async def test_error_messages_contain_required_substrings(
        self, router: TokenVelocityRouter
    ) -> None:
        error = _make_error(429, "quota exceeded")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error,
            ),
            patch("autosre.core.router.asyncio.sleep", new_callable=AsyncMock),
            pytest.raises(
                LLMBudgetExhaustedError,
                match="(?=.*budget exhausted)(?=.*quota exhausted)",
            ),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )
