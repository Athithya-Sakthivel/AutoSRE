"""Tests for all /chaos/* management endpoints."""


def test_oom_toggle(client):
    # Initially off
    state = client.get("/chaos/state").json()
    assert state["chaos"]["oom"] is False

    # Enable
    resp = client.post("/chaos/oom")
    assert resp.status_code == 200
    state = resp.json()
    assert state["chaos"]["oom"] is True
    assert state["chaos"]["active"] is True

    # Disable via reset
    client.post("/chaos/reset")
    state = client.get("/chaos/state").json()
    assert state["chaos"]["oom"] is False


def test_db_deadlock_toggle(client):
    client.post("/chaos/db-deadlock")
    state = client.get("/chaos/state").json()
    assert state["chaos"]["db_deadlock"] is True

    client.post("/chaos/reset")
    state = client.get("/chaos/state").json()
    assert state["chaos"]["db_deadlock"] is False


def test_latency_set_and_reset(client):
    client.post("/chaos/latency", params={"ms": 2000})
    state = client.get("/chaos/state").json()
    assert state["chaos"]["latency_ms"] == 2000

    client.post("/chaos/reset")
    state = client.get("/chaos/state").json()
    assert state["chaos"]["latency_ms"] == 0


def test_error_rate_set_and_bounds(client):
    # Valid rate
    client.post("/chaos/error-rate", params={"rate": 0.5})
    state = client.get("/chaos/state").json()
    assert state["chaos"]["error_rate"] == 0.5

    # Invalid rate – FastAPI will return validation error
    resp = client.post("/chaos/error-rate", params={"rate": 1.5})
    assert resp.status_code == 422  # Unprocessable Entity

    resp = client.post("/chaos/error-rate", params={"rate": -0.1})
    assert resp.status_code == 422


def test_cpu_spike_snapshot(client):
    # CPU spike is asynchronous; we just check that the snapshot shows activity
    resp = client.post("/chaos/cpu-spike", params={"seconds": 1})
    assert resp.status_code == 200
    state = resp.json()
    assert state["chaos"]["cpu_spike_active"] is True
    assert state["chaos"]["cpu_spike_until_monotonic"] is not None

    # The spike should end quickly; we can wait a bit then check reset cleared it
    import time

    time.sleep(1.5)
    # Reset clears it
    client.post("/chaos/reset")
    state = client.get("/chaos/state").json()
    assert state["chaos"]["cpu_spike_active"] is False


def test_reset_clears_all(client):
    # Enable everything
    client.post("/chaos/oom")
    client.post("/chaos/db-deadlock")
    client.post("/chaos/latency", params={"ms": 500})
    client.post("/chaos/error-rate", params={"rate": 0.9})
    client.post("/chaos/cpu-spike", params={"seconds": 60})

    # Verify chaos is active
    state = client.get("/chaos/state").json()
    assert state["chaos"]["active"] is True

    # Reset
    resp = client.post("/chaos/reset")
    assert resp.status_code == 200

    state = client.get("/chaos/state").json()
    assert state["chaos"]["active"] is False
    assert state["chaos"]["oom"] is False
    assert state["chaos"]["db_deadlock"] is False
    assert state["chaos"]["latency_ms"] == 0
    assert state["chaos"]["error_rate"] == 0.0


def test_chaos_state_endpoint(client):
    response = client.get("/chaos/state")
    assert response.status_code == 200
    data = response.json()
    assert "chaos" in data
    # All fields should be present
    required_fields = {
        "oom",
        "db_deadlock",
        "latency_ms",
        "error_rate",
        "cpu_spike_active",
        "cpu_spike_until_monotonic",
    }
    assert required_fields.issubset(data["chaos"].keys())
