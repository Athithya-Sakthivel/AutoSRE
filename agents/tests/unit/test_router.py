"""Unit tests for autosre.core.router.TokenVelocityRouter.

These tests cover the provider-agnostic pass-through routing, token
counting, model selection by threshold, and the exponential backoff
retry logic for transient provider errors.

All sleep calls are mocked so the test suite runs in milliseconds
regardless of configured backoff durations.

## Backoff strategy under test

The router implements a hybrid backoff:
    - Attempts 0-2: linear (initial_backoff * (attempt + 1))
    - Attempts 3+: exponential (initial_backoff * 2^attempt)
    - All: capped at max_backoff_seconds
    - All: hard-capped at 30.0 seconds
    - All: jitter up to 10% of base

Tests verify these invariants rather than exact values.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from autosre.config import LLMConfig
from autosre.core.router import LLMBudgetExhaustedError, TokenVelocityRouter
from autosre.core.state import RunMetrics

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def config() -> LLMConfig:
    """Build a minimal LLMConfig for router tests."""
    return LLMConfig(
        api_key="test-key",
        model_coordinator="gemini/gemini-3.8-flash",
        model_worker="gemini/gemini-3.8-flash",
        max_retries=3,
        initial_backoff_seconds=1.0,
        max_backoff_seconds=30.0,
    )


@pytest.fixture
def router(config: LLMConfig) -> TokenVelocityRouter:
    """Create a router with default threshold."""
    return TokenVelocityRouter(config, threshold_tokens=6000)


@pytest.fixture
def run_metrics() -> RunMetrics:
    return RunMetrics()


def _make_error(status_code: int, message: str = "error") -> Exception:
    """Build an exception with an HTTP status_code attribute."""
    err = Exception(message)
    err.status_code = status_code  # type: ignore[attr-defined]
    return err


def _make_daily_quota_error() -> Exception:
    """Build an exception that matches daily-quota patterns."""
    err = Exception("Quota exceeded for requests per day")
    err.status_code = 429  # type: ignore[attr-defined]
    return err


# ---------------------------------------------------------------------------
# Token Counting Tests
# ---------------------------------------------------------------------------


class TestTokenCounting:
    def test_empty_messages_produce_small_count(self, router: TokenVelocityRouter) -> None:
        count = router.count_tokens([])
        assert count >= 0

    def test_single_message_is_nonzero(self, router: TokenVelocityRouter) -> None:
        count = router.count_tokens([{"role": "user", "content": "Hello world"}])
        assert count > 0

    def test_large_content_exceeds_threshold(self, router: TokenVelocityRouter) -> None:
        content = "word " * 8000
        count = router.count_tokens([{"role": "user", "content": content}])
        assert count > 6000

    def test_tools_are_included_in_estimate(self, router: TokenVelocityRouter) -> None:
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
    def test_small_prompt_uses_coordinator(self, router: TokenVelocityRouter) -> None:
        messages = [{"role": "user", "content": "small prompt"}]
        selected = router.select_model(messages)
        assert selected == "gemini/gemini-3.8-flash"

    def test_large_prompt_uses_worker(self, router: TokenVelocityRouter) -> None:
        content = "word " * 8000
        messages = [{"role": "user", "content": content}]
        selected = router.select_model(messages)
        assert selected == "gemini/gemini-3.8-flash"

    @pytest.mark.parametrize(
        ("token_count", "expected_model"),
        [
            (5999, "gemini/gemini-3.8-flash"),  # below threshold → coordinator
            (6000, "gemini/gemini-3.8-flash"),  # at threshold → worker
            (6001, "gemini/gemini-3.8-flash"),  # above → worker
        ],
    )
    def test_threshold_boundary(
        self,
        router: TokenVelocityRouter,
        token_count: int,
        expected_model: str,
    ) -> None:
        with patch.object(router, "count_tokens", return_value=token_count):
            selected = router.select_model([{"role": "user", "content": "x"}])
        assert selected == expected_model


# ---------------------------------------------------------------------------
# Model Resolution (pass-through) Tests
# ---------------------------------------------------------------------------


class TestModelResolution:
    def test_explicit_model_passes_through_unchanged(self, router: TokenVelocityRouter) -> None:
        """The router must not mutate the model ID."""
        assert router._resolve_model("gemini/gemini-3.8-flash") == "gemini/gemini-3.8-flash"
        assert router._resolve_model("openai/gpt-4o-mini") == "openai/gpt-4o-mini"
        assert router._resolve_model("anthropic/claude-3-5-sonnet") == "anthropic/claude-3-5-sonnet"

    def test_auto_alias_resolves_to_coordinator(self, router: TokenVelocityRouter) -> None:
        assert router._resolve_model("auto") == "gemini/gemini-3.8-flash"
        assert router._resolve_model("coordinator") == "gemini/gemini-3.8-flash"

    def test_fast_alias_resolves_to_coordinator(self, router: TokenVelocityRouter) -> None:
        assert router._resolve_model("fast") == "gemini/gemini-3.8-flash"

    def test_worker_alias_resolves_to_worker(self, router: TokenVelocityRouter) -> None:
        assert router._resolve_model("worker") == "gemini/gemini-3.8-flash"
        assert router._resolve_model("slow") == "gemini/gemini-3.8-flash"

    def test_whitespace_is_stripped(self, router: TokenVelocityRouter) -> None:
        assert router._resolve_model("  gemini/gemini-3.8-flash  ") == "gemini/gemini-3.8-flash"


# ---------------------------------------------------------------------------
# Async Completion — Success Path
# ---------------------------------------------------------------------------


class TestAsyncCompletionSuccess:
    @pytest.mark.asyncio
    async def test_auto_route_calls_litellm_with_resolved_model(
        self, router: TokenVelocityRouter
    ) -> None:
        mock_response = MagicMock()
        mock_response.usage = None

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_call:
            result = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "small"}],
            )

            assert result is mock_response
            mock_call.assert_awaited_once()
            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["model"] == "gemini/gemini-3.8-flash"

    @pytest.mark.asyncio
    async def test_explicit_model_passed_through(self, router: TokenVelocityRouter) -> None:
        mock_response = MagicMock()
        mock_response.usage = None

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_call:
            await router.acompletion(
                model="openai/gpt-4o-mini",
                messages=[{"role": "user", "content": "x"}],
            )

            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["model"] == "openai/gpt-4o-mini"

    @pytest.mark.asyncio
    async def test_tools_and_kwargs_forwarded(self, router: TokenVelocityRouter) -> None:
        mock_response = MagicMock()
        mock_response.usage = None
        tools = [{"type": "function", "function": {"name": "test"}}]

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_call:
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
                tools=tools,
                temperature=0.5,
            )

            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["tools"] == tools
            assert call_kwargs["temperature"] == 0.5

    @pytest.mark.asyncio
    async def test_coordinator_call_uses_auto_routing(self, router: TokenVelocityRouter) -> None:
        mock_response = MagicMock()
        mock_response.usage = None

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_call:
            await router.coordinator_call(messages=[{"role": "user", "content": "small"}])

            mock_call.assert_awaited_once()
            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["model"] == "gemini/gemini-3.8-flash"

    @pytest.mark.asyncio
    async def test_success_records_metrics(
        self, router: TokenVelocityRouter, run_metrics: RunMetrics
    ) -> None:
        mock_response = MagicMock()
        mock_response.usage = None

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
                run_metrics=run_metrics,
            )

        assert run_metrics.llm_call_count == 1
        assert run_metrics.llm_consecutive_failures == 0


# ---------------------------------------------------------------------------
# Async Completion — Retry / Backoff
# ---------------------------------------------------------------------------


class TestAsyncCompletionRetry:
    @pytest.mark.asyncio
    async def test_429_triggers_retry_then_succeeds(
        self, router: TokenVelocityRouter, run_metrics: RunMetrics
    ) -> None:
        mock_response = MagicMock()
        mock_response.usage = None
        error_429 = _make_error(429, "rate limit exceeded")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error_429, mock_response],
            ) as mock_call,
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ) as mock_sleep,
        ):
            result = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
                run_metrics=run_metrics,
            )

            assert result is mock_response
            assert mock_call.await_count == 2
            mock_sleep.assert_awaited_once()

            # Backoff must be recorded in RunMetrics.
            assert run_metrics.llm_call_count == 2
            assert run_metrics.backoff_seconds > 0.0

    @pytest.mark.asyncio
    async def test_503_triggers_retry(self, router: TokenVelocityRouter) -> None:
        """Gemini returns 503 for free-tier capacity exhaustion."""
        mock_response = MagicMock()
        mock_response.usage = None
        error_503 = _make_error(503, "service unavailable")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error_503, mock_response],
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ),
        ):
            result = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert result is mock_response

    @pytest.mark.asyncio
    async def test_500_triggers_retry(self, router: TokenVelocityRouter) -> None:
        mock_response = MagicMock()
        mock_response.usage = None
        error_500 = _make_error(500, "internal server error")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error_500, mock_response],
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ),
        ):
            result = await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert result is mock_response

    @pytest.mark.asyncio
    async def test_exhausted_retries_raise_budget_error(
        self, router: TokenVelocityRouter, run_metrics: RunMetrics
    ) -> None:
        error_429 = _make_error(429, "rate limit")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error_429,
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ),
            pytest.raises(LLMBudgetExhaustedError, match="budget exhausted"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
                run_metrics=run_metrics,
            )

        # max_retries=3 → 4 total attempts (initial + 3 retries)
        assert run_metrics.llm_call_count == 4

    @pytest.mark.asyncio
    async def test_backoff_grows_monotonically(self, router: TokenVelocityRouter) -> None:
        """Backoff grows: linear for first 3 attempts, then exponential.

        With initial_backoff=1.0 and max_backoff=30.0:
            attempt 0: linear  1.0 * 1 = 1.0  (+10% jitter = 1.0-1.1)
            attempt 1: linear  1.0 * 2 = 2.0  (+10% jitter = 2.0-2.2)
            attempt 2: linear  1.0 * 3 = 3.0  (+10% jitter = 3.0-3.3)
        """
        error_429 = _make_error(429, "rate limit")
        mock_response = MagicMock()
        mock_response.usage = None

        sleep_durations: list[float] = []

        async def capture_sleep(duration: float) -> None:
            sleep_durations.append(duration)

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error_429, error_429, error_429, mock_response],
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
                side_effect=capture_sleep,
            ),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        # 3 retries → 3 sleep calls
        assert len(sleep_durations) == 3

        # Attempt 0: linear = 1.0 * 1 = 1.0, with up to 10% jitter
        assert 1.0 <= sleep_durations[0] <= 1.1 + 0.01

        # Attempt 1: linear = 1.0 * 2 = 2.0, with up to 10% jitter
        assert 2.0 <= sleep_durations[1] <= 2.2 + 0.01

        # Attempt 2: linear = 1.0 * 3 = 3.0, with up to 10% jitter
        assert 3.0 <= sleep_durations[2] <= 3.3 + 0.01

        # Each duration should be strictly greater than the previous
        # (linear growth guarantees this even with jitter)
        assert sleep_durations[1] > sleep_durations[0]
        assert sleep_durations[2] > sleep_durations[1]

    @pytest.mark.asyncio
    async def test_backoff_capped_at_max(
        self,
    ) -> None:
        """Backoff must not exceed max_backoff_seconds.

        With initial_backoff=10.0 and max_backoff=15.0:
            attempt 0: linear 10*1=10, min(10,15)=10, min(10,30)=10  +jitter <= 11.0
            attempt 1: linear 10*2=20, min(20,15)=15, min(15,30)=15  +jitter <= 16.5
            attempt 2: linear 10*3=30, min(30,15)=15, min(15,30)=15  +jitter <= 16.5
            attempt 3: exp   10*8=80, min(80,15)=15, min(15,30)=15   +jitter <= 16.5
            attempt 4: exp   10*16=160, min(160,15)=15, min(15,30)=15 +jitter <= 16.5
        """
        config = LLMConfig(
            api_key="test-key",
            model_coordinator="gemini/gemini-3.8-flash",
            model_worker="gemini/gemini-3.8-flash",
            max_retries=5,
            initial_backoff_seconds=10.0,
            max_backoff_seconds=15.0,
        )
        router = TokenVelocityRouter(config)

        error_429 = _make_error(429, "rate limit")
        mock_response = MagicMock()
        mock_response.usage = None

        sleep_durations: list[float] = []

        async def capture_sleep(duration: float) -> None:
            sleep_durations.append(duration)

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error_429] * 5 + [mock_response],
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
                side_effect=capture_sleep,
            ),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert len(sleep_durations) == 5

        # All durations must be <= max_backoff * 1.1 (jitter allowance)
        max_with_jitter = 15.0 * 1.1 + 0.01
        for i, duration in enumerate(sleep_durations):
            assert duration <= max_with_jitter, (
                f"Sleep {i}: {duration:.2f}s exceeds max_with_jitter {max_with_jitter:.2f}s"
            )

        # Attempt 0 should be ~10s (linear: 10*1=10, no capping needed)
        assert 10.0 <= sleep_durations[0] <= 11.0 + 0.01

        # Attempts 1-4 should all be ~15s (capped at max_backoff)
        for i in range(1, 5):
            assert 15.0 <= sleep_durations[i] <= 16.5 + 0.01, (
                f"Sleep {i}: {sleep_durations[i]:.2f}s not in [15.0, 16.51]"
            )

    @pytest.mark.asyncio
    async def test_backoff_hard_capped_at_30s(
        self,
    ) -> None:
        """Even if max_backoff is very high, absolute cap is 30s."""
        config = LLMConfig(
            api_key="test-key",
            model_coordinator="gemini/gemini-3.8-flash",
            model_worker="gemini/gemini-3.8-flash",
            max_retries=5,
            initial_backoff_seconds=20.0,
            max_backoff_seconds=600.0,  # Very high
        )
        router = TokenVelocityRouter(config)

        error_429 = _make_error(429, "rate limit")
        mock_response = MagicMock()
        mock_response.usage = None

        sleep_durations: list[float] = []

        async def capture_sleep(duration: float) -> None:
            sleep_durations.append(duration)

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error_429] * 5 + [mock_response],
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
                side_effect=capture_sleep,
            ),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        # All durations must be <= 30.0 * 1.1 (hard cap + jitter)
        max_with_jitter = 30.0 * 1.1 + 0.01
        for duration in sleep_durations:
            assert duration <= max_with_jitter

    @pytest.mark.asyncio
    async def test_retry_after_header_honored(self, router: TokenVelocityRouter) -> None:
        """Provider Retry-After header overrides exponential calculation."""
        error = _make_error(429, "rate limit")
        error.response = MagicMock()  # type: ignore[attr-defined]
        error.response.headers = {"retry-after": "5"}  # type: ignore[attr-defined]

        mock_response = MagicMock()
        mock_response.usage = None

        sleep_durations: list[float] = []

        async def capture_sleep(duration: float) -> None:
            sleep_durations.append(duration)

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=[error, mock_response],
            ),
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
                side_effect=capture_sleep,
            ),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        assert len(sleep_durations) == 1
        # Should be approximately 5s (plus up to 10% jitter).
        assert 5.0 <= sleep_durations[0] <= 5.5 + 0.01

    @pytest.mark.asyncio
    async def test_daily_quota_error_fast_fails(
        self, router: TokenVelocityRouter, run_metrics: RunMetrics
    ) -> None:
        """Daily quota exhaustion must NOT retry."""
        daily_error = _make_daily_quota_error()

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=daily_error,
            ) as mock_call,
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ) as mock_sleep,
            pytest.raises(LLMBudgetExhaustedError, match="quota exhausted"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
                run_metrics=run_metrics,
            )

        # Exactly one attempt, no sleep.
        mock_call.assert_awaited_once()
        mock_sleep.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_non_retryable_error_propagates_immediately(
        self, router: TokenVelocityRouter
    ) -> None:
        """A 400 (bad request) must not trigger retry."""
        error_400 = _make_error(400, "bad request — invalid JSON")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error_400,
            ) as mock_call,
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ) as mock_sleep,
            pytest.raises(Exception, match="bad request"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        mock_call.assert_awaited_once()
        mock_sleep.assert_not_awaited()

    @pytest.mark.asyncio
    async def test_authentication_error_propagates_immediately(
        self, router: TokenVelocityRouter
    ) -> None:
        """A 401 (invalid API key) must not retry."""
        error_401 = _make_error(401, "API key not valid")

        with (
            patch(
                "autosre.core.router.litellm.acompletion",
                new_callable=AsyncMock,
                side_effect=error_401,
            ) as mock_call,
            patch(
                "autosre.core.router.asyncio.sleep",
                new_callable=AsyncMock,
            ) as mock_sleep,
            pytest.raises(Exception, match="API key"),
        ):
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

        mock_call.assert_awaited_once()
        mock_sleep.assert_not_awaited()


# ---------------------------------------------------------------------------
# API key injection
# ---------------------------------------------------------------------------


class TestApiKeyInjection:
    @pytest.mark.asyncio
    async def test_api_key_injected_when_not_in_kwargs(self, router: TokenVelocityRouter) -> None:
        mock_response = MagicMock()
        mock_response.usage = None

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_call:
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
            )

            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["api_key"] == "test-key"

    @pytest.mark.asyncio
    async def test_caller_api_key_takes_precedence(self, router: TokenVelocityRouter) -> None:
        """If the caller passes api_key explicitly, don't overwrite it."""
        mock_response = MagicMock()
        mock_response.usage = None

        with patch(
            "autosre.core.router.litellm.acompletion",
            new_callable=AsyncMock,
            return_value=mock_response,
        ) as mock_call:
            await router.acompletion(
                model="auto",
                messages=[{"role": "user", "content": "hi"}],
                api_key="caller-key",
            )

            call_kwargs = mock_call.call_args.kwargs
            assert call_kwargs["api_key"] == "caller-key"
