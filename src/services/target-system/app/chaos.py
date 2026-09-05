"""Thread-safe chaos state for the target-system service."""

from __future__ import annotations

import logging
import threading
import time
from dataclasses import asdict, dataclass
from typing import Any

logger = logging.getLogger(__name__)


@dataclass(slots=True)
class ChaosSnapshot:
    oom: bool = False
    db_deadlock: bool = False
    latency_ms: int = 0
    error_rate: float = 0.0
    cpu_spike_active: bool = False
    cpu_spike_until_monotonic: float | None = None


class ChaosState:
    """Process-local chaos controls.

    The state is safe for concurrent requests. Mutations are idempotent and
    repeated calls simply leave the system in the requested state.
    """

    def __init__(self) -> None:
        self._lock = threading.RLock()
        self._snapshot = ChaosSnapshot()
        self._cpu_stop_event = threading.Event()
        self._cpu_thread: threading.Thread | None = None

    def snapshot(self) -> dict[str, Any]:
        """Return a frozen copy of the current chaos state with an 'active' flag."""
        with self._lock:
            data = asdict(self._snapshot)
        # Compute convenience 'active' flag – true if any chaos is enabled
        data["active"] = any(
            [
                data["oom"],
                data["db_deadlock"],
                data["latency_ms"] > 0,
                data["error_rate"] > 0.0,
                data["cpu_spike_active"],
            ]
        )
        return data

    def enable_oom(self, active: bool = True) -> None:
        with self._lock:
            self._snapshot.oom = bool(active)

    def enable_db_deadlock(self, active: bool = True) -> None:
        with self._lock:
            self._snapshot.db_deadlock = bool(active)

    def set_latency_ms(self, latency_ms: int) -> None:
        if latency_ms < 0:
            raise ValueError("latency_ms must be >= 0")
        with self._lock:
            self._snapshot.latency_ms = int(latency_ms)

    def set_error_rate(self, rate: float) -> None:
        if rate < 0.0 or rate > 1.0:
            raise ValueError("error_rate must be between 0.0 and 1.0")
        with self._lock:
            self._snapshot.error_rate = float(rate)

    def start_cpu_spike(self, duration_seconds: int) -> dict[str, Any]:
        if duration_seconds <= 0:
            raise ValueError("duration_seconds must be > 0")

        deadline = time.monotonic() + duration_seconds
        with self._lock:
            current_deadline = self._snapshot.cpu_spike_until_monotonic
            if current_deadline is not None:
                deadline = max(deadline, current_deadline)
            self._snapshot.cpu_spike_active = True
            self._snapshot.cpu_spike_until_monotonic = deadline
            if self._cpu_thread is None or not self._cpu_thread.is_alive():
                self._cpu_stop_event.clear()
                self._cpu_thread = threading.Thread(
                    target=self._cpu_spike_worker, name="chaos-cpu-spike", daemon=True
                )
                self._cpu_thread.start()
        return self.snapshot()

    def reset(self) -> None:
        with self._lock:
            self._snapshot = ChaosSnapshot()
            self._cpu_stop_event.set()
            thread = self._cpu_thread
            self._cpu_thread = None
        if thread and thread.is_alive():
            thread.join(timeout=1.0)
        self._cpu_stop_event.clear()

    def maybe_latency_ms(self) -> int:
        with self._lock:
            return self._snapshot.latency_ms

    def maybe_error_rate(self) -> float:
        with self._lock:
            return self._snapshot.error_rate

    def is_oom(self) -> bool:
        with self._lock:
            return self._snapshot.oom

    def is_db_deadlock(self) -> bool:
        with self._lock:
            return self._snapshot.db_deadlock

    def is_cpu_spike_active(self) -> bool:
        with self._lock:
            if not self._snapshot.cpu_spike_active:
                return False
            deadline = self._snapshot.cpu_spike_until_monotonic
            if deadline is None:
                return False
            active = time.monotonic() < deadline
            if not active:
                self._snapshot.cpu_spike_active = False
                self._snapshot.cpu_spike_until_monotonic = None
            return active

    def _cpu_spike_worker(self) -> None:
        while not self._cpu_stop_event.is_set():
            with self._lock:
                deadline = self._snapshot.cpu_spike_until_monotonic
            if deadline is None:
                break
            if time.monotonic() >= deadline:
                break

            # Burn CPU in short bursts
            total = 0
            for i in range(200_000):
                total += i * i
            _ = total

        with self._lock:
            self._snapshot.cpu_spike_active = False
            self._snapshot.cpu_spike_until_monotonic = None
        logger.info("CPU spike worker stopped")


chaos_state = ChaosState()
