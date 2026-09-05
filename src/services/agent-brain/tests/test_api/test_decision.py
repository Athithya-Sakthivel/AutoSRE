"""Tests for POST /decision/{thread_id} endpoint."""

from __future__ import annotations


def test_human_decision_resumes_workflow(client, mock_graph):
    thread_id = "test-thread"
    mock_graph.ainvoke.return_value = {"status": "approved"}
    response = client.post(
        f"/decision/{thread_id}",
        json={"decision": "approved"},
    )
    assert response.status_code == 200
    data = response.json()
    assert data["status"] == "resumed"
    mock_graph.ainvoke.assert_awaited_once()


def test_human_decision_requires_auth_when_enabled(client, mock_settings):
    mock_settings.require_auth = True
    response = client.post("/decision/some-thread", json={"decision": "approved"})
    assert response.status_code == 401


def test_human_decision_with_invalid_thread_id(client, mock_graph):
    mock_graph.ainvoke.side_effect = Exception("Thread not found")
    response = client.post("/decision/unknown", json={"decision": "approved"})
    # The endpoint catches exceptions and returns 500
    assert response.status_code == 500
