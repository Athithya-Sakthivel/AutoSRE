"""Tests for WebSocket /ws/{thread_id} endpoint."""

from __future__ import annotations

from unittest.mock import patch


def test_websocket_connect_and_receive_state(client, mock_graph):
    """Test that a WebSocket connection receives a state message."""
    # Mock the manager's handle_socket to directly send a message
    with patch("main.manager.handle_socket", new_callable=lambda: _fake_handle_socket):
        with client.websocket_connect("/ws/test-thread") as websocket:
            data = websocket.receive_json()
            assert data["type"] == "connected"
            assert data["thread_id"] == "test-thread"


# Helper: a fake handle_socket that sends a minimal connected event
async def _fake_handle_socket(websocket, thread_id: str):
    await websocket.accept()
    await websocket.send_json({"type": "connected", "thread_id": thread_id})
