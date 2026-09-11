"""Tests for the Cosmos DB rate limiter logic (mocked)."""

from __future__ import annotations

from unittest.mock import MagicMock, patch

import pytest
from agent.rate_limiter import async_check_rate_limit


@pytest.mark.asyncio
async def test_check_rate_limit_allowed():
    # Simulate a bucket with count 1, historical sum = 1
    mock_container = MagicMock()
    mock_container.patch_item.return_value = {"id": "b1", "count": 2}  # after increment
    mock_container.query_items.return_value = [{"count": 1}]

    with patch("agent.rate_limiter._rate_limit_container", return_value=mock_container):
        result = await async_check_rate_limit("res1")
        assert result.allowed is True
        assert result.count <= 10  # threshold default


@pytest.mark.asyncio
async def test_check_rate_limit_blocked():
    # Historical sum exceeds threshold
    mock_container = MagicMock()
    mock_container.patch_item.return_value = {"id": "b1", "count": 11}
    mock_container.query_items.return_value = [{"count": 5}, {"count": 6}]

    with patch("agent.rate_limiter._rate_limit_container", return_value=mock_container):
        result = await async_check_rate_limit("res1")
        assert result.allowed is False
