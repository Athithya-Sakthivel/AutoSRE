"""Unit tests for CodeAct sandbox security and functionality."""

from __future__ import annotations

import pytest

from autosre.core.codeact import (
    ALLOWED_MODULES,
    BLOCKED_BUILTINS,
    CodeActExecutionError,
    CodeActSandbox,
    CodeActSecurityError,
    CodeActTimeoutError,
)


@pytest.fixture
def sandbox() -> CodeActSandbox:
    """Create a sandbox with default timeout."""
    return CodeActSandbox(timeout=5.0)


@pytest.fixture
def fast_sandbox() -> CodeActSandbox:
    """Create a sandbox with short timeout for timeout tests."""
    return CodeActSandbox(timeout=1.0)


# ---------------------------------------------------------------------------
# Security: AST validation rejects dangerous patterns
# ---------------------------------------------------------------------------


class TestASTValidation:
    """Tests that dangerous code is rejected before execution."""

    def test_blocks_import_os(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Import not allowed"):
            sandbox.execute("import os")

    def test_blocks_import_sys(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Import not allowed"):
            sandbox.execute("import sys")

    def test_blocks_import_subprocess(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Import not allowed"):
            sandbox.execute("import subprocess")

    def test_blocks_from_os_import(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Import not allowed"):
            sandbox.execute("from os import path")

    def test_blocks_eval_call(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Dangerous function call"):
            sandbox.execute("x = eval('1+1')")

    def test_blocks_exec_call(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Dangerous function call"):
            sandbox.execute("exec('x = 1')")

    def test_blocks_dunder_import_call(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError):
            sandbox.execute("os = __import__('os')")

    def test_blocks_dangerous_dunder_access(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Dangerous dunder access"):
            sandbox.execute("class Foo:\n    pass\nresult = Foo().__class__")

    def test_allows_safe_dunder_access(self, sandbox: CodeActSandbox) -> None:
        result = sandbox.execute("result = len([1,2,3])")
        assert result == 3

    def test_syntax_error_raises_security_error(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Syntax error"):
            sandbox.execute("import numpy as\n")

    def test_multiple_violations_report_first(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActSecurityError, match="Import not allowed"):
            sandbox.execute("import os\nimport sys\nimport subprocess")


# ---------------------------------------------------------------------------
# Safe execution: allowed modules work correctly
# ---------------------------------------------------------------------------


class TestSafeExecution:
    """Tests that safe code executes correctly."""

    def test_numpy_percentile(self, sandbox: CodeActSandbox) -> None:
        code = """
import numpy as np
data = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
result = float(np.percentile(data, 95))
"""
        result = sandbox.execute(code)
        assert isinstance(result, float)
        assert 9.0 <= result <= 10.0

    def test_pandas_dataframe(self, sandbox: CodeActSandbox) -> None:
        code = """
import pandas as pd
df = pd.DataFrame({'a': [1, 2, 3], 'b': [4, 5, 6]})
result = int(df['a'].sum())
"""
        result = sandbox.execute(code)
        assert result == 6

    def test_math_operations(self, sandbox: CodeActSandbox) -> None:
        code = """
import math
result = math.sqrt(16)
"""
        result = sandbox.execute(code)
        assert result == 4.0

    def test_json_parsing(self, sandbox: CodeActSandbox) -> None:
        code = """
import json
data = '{"key": "value"}'
result = json.loads(data)['key']
"""
        result = sandbox.execute(code)
        assert result == "value"

    def test_statistics_mean(self, sandbox: CodeActSandbox) -> None:
        code = """
import statistics
data = [1, 2, 3, 4, 5]
result = statistics.mean(data)
"""
        result = sandbox.execute(code)
        assert result == 3.0

    def test_re_module(self, sandbox: CodeActSandbox) -> None:
        code = """
import re
text = "error: connection failed"
match = re.search(r'error: (.+)', text)
result = match.group(1) if match else None
"""
        result = sandbox.execute(code)
        assert result == "connection failed"

    def test_no_result_returns_none(self, sandbox: CodeActSandbox) -> None:
        result = sandbox.execute("x = 1 + 1")
        assert result is None

    def test_basic_arithmetic(self, sandbox: CodeActSandbox) -> None:
        result = sandbox.execute("result = 2 + 3 * 4")
        assert result == 14

    def test_string_operations(self, sandbox: CodeActSandbox) -> None:
        code = """
result = "hello world".upper().split()
"""
        result = sandbox.execute(code)
        assert result == ["HELLO", "WORLD"]

    def test_list_comprehension(self, sandbox: CodeActSandbox) -> None:
        code = """
result = [x ** 2 for x in range(5)]
"""
        result = sandbox.execute(code)
        assert result == [0, 1, 4, 9, 16]


# ---------------------------------------------------------------------------
# Blocked builtins at runtime
# ---------------------------------------------------------------------------


class TestBlockedBuiltins:
    """Tests that blocked builtins raise errors at runtime."""

    def test_open_is_blocked(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises((CodeActSecurityError, CodeActExecutionError)):
            sandbox.execute("f = open('/etc/passwd')")

    def test_input_is_blocked(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises((CodeActSecurityError, CodeActExecutionError)):
            sandbox.execute("x = input('prompt')")

    def test_globals_is_blocked(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises((CodeActSecurityError, CodeActExecutionError)):
            sandbox.execute("x = globals()")


# ---------------------------------------------------------------------------
# Timeout enforcement
# ---------------------------------------------------------------------------


class TestTimeout:
    """Tests that long-running code is terminated."""

    def test_infinite_loop_times_out(self, fast_sandbox: CodeActSandbox) -> None:
        code = """
import time
while True:
    time.sleep(0.01)
"""
        with pytest.raises(CodeActTimeoutError, match="timeout"):
            fast_sandbox.execute(code)

    def test_fast_code_completes_before_timeout(self, sandbox: CodeActSandbox) -> None:
        result = sandbox.execute("result = 1 + 1")
        assert result == 2


# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------


class TestErrorHandling:
    """Tests that runtime errors are properly reported."""

    def test_zero_division_raises_execution_error(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActExecutionError, match="ZeroDivisionError"):
            sandbox.execute("result = 1 / 0")

    def test_name_error_raises_execution_error(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActExecutionError, match="NameError"):
            sandbox.execute("result = undefined_variable")

    def test_type_error_raises_execution_error(self, sandbox: CodeActSandbox) -> None:
        with pytest.raises(CodeActExecutionError, match="TypeError"):
            sandbox.execute("result = 'hello' + 42")


# ---------------------------------------------------------------------------
# Integration: realistic agent use cases
# ---------------------------------------------------------------------------


class TestIntegration:
    """Integration tests for realistic agent data processing tasks."""

    def test_log_parsing(self, sandbox: CodeActSandbox) -> None:
        code = """
import re
from collections import Counter

logs = [
    "ERROR: connection timeout",
    "INFO: request processed",
    "ERROR: database connection failed",
    "ERROR: connection timeout",
    "INFO: request processed",
]

error_pattern = re.compile(r'ERROR: (.+)')
errors = [m.group(1) for line in logs if (m := error_pattern.match(line))]
counts = Counter(errors)
result = dict(counts.most_common(1))
"""
        result = sandbox.execute(code)
        assert result == {"connection timeout": 2}

    def test_metric_aggregation(self, sandbox: CodeActSandbox) -> None:
        code = """
import numpy as np

latencies = [45, 52, 48, 51, 49, 53, 47, 50, 46, 54]
p50 = float(np.percentile(latencies, 50))
p95 = float(np.percentile(latencies, 95))
p99 = float(np.percentile(latencies, 99))

result = {
    'p50': p50,
    'p95': p95,
    'p99': p99,
    'mean': float(np.mean(latencies)),
}
"""
        result = sandbox.execute(code)
        assert isinstance(result, dict)
        assert "p50" in result
        assert "p95" in result
        assert "p99" in result
        assert result["p50"] <= result["p95"] <= result["p99"]

    def test_json_transformation(self, sandbox: CodeActSandbox) -> None:
        code = """
import json

raw_data = [
    {'service': 'api-gateway', 'latency_ms': 120},
    {'service': 'api-gateway', 'latency_ms': 150},
    {'service': 'worker', 'latency_ms': 80},
]

summary = {}
for item in raw_data:
    svc = item['service']
    if svc not in summary:
        summary[svc] = []
    summary[svc].append(item['latency_ms'])

result = {svc: sum(vals) / len(vals) for svc, vals in summary.items()}
"""
        result = sandbox.execute(code)
        assert result == {"api-gateway": 135.0, "worker": 80.0}


# ---------------------------------------------------------------------------
# Module-level constants are correct
# ---------------------------------------------------------------------------


class TestConstants:
    """Verify module-level security constants."""

    def test_allowed_modules_contains_pandas(self) -> None:
        assert "pandas" in ALLOWED_MODULES

    def test_allowed_modules_contains_numpy(self) -> None:
        assert "numpy" in ALLOWED_MODULES

    def test_blocked_builtins_contains_eval(self) -> None:
        assert "eval" in BLOCKED_BUILTINS

    def test_blocked_builtins_contains_exec(self) -> None:
        assert "exec" in BLOCKED_BUILTINS

    def test_blocked_builtins_does_not_contain_len(self) -> None:
        assert "len" not in BLOCKED_BUILTINS
