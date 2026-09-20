"""CodeAct Sandbox - Safe execution of Python code with AST validation and multiprocessing isolation.

This module provides a secure sandbox for executing Python code with:
- AST-based validation to prevent dangerous operations
- Restricted imports (allowlist-based)
- Blocked builtins (eval, exec, __import__, etc.)
- Multiprocessing isolation with timeout enforcement
- Support for data processing libraries (pandas, numpy, etc.)
"""

from __future__ import annotations

import ast
import builtins
import multiprocessing as mp
import sys
from collections.abc import Callable
from typing import Any

# Use fork context on Linux for fast process creation, spawn on other platforms.
# Python 3.14 changed the default start method away from fork on all platforms,
# which increases child startup time and causes false timeouts under spawn.

# Use forkserver on Linux: preserves most of fork's startup performance while
# avoiding the multithreaded-fork deadlock hazard that Python 3.12+ warns about.
# On non-Linux platforms, fall back to spawn (the only safe option).

if sys.platform.startswith("linux"):
    CTX = mp.get_context("forkserver")
else:
    CTX = mp.get_context("spawn")


class CodeActSecurityError(Exception):
    """Raised when code violates security policy."""


class CodeActTimeoutError(Exception):
    """Raised when code execution exceeds timeout."""


class CodeActExecutionError(Exception):
    """Raised when code execution fails."""


# Whitelisted modules for safe execution
ALLOWED_MODULES: frozenset[str] = frozenset(
    {
        "pandas",
        "pd",
        "numpy",
        "np",
        "math",
        "statistics",
        "json",
        "datetime",
        "time",
        "re",
        "collections",
        "itertools",
        "functools",
        "operator",
        "string",
        "textwrap",
        "decimal",
        "fractions",
        "random",
    }
)

# Blocked builtins that could be dangerous
BLOCKED_BUILTINS: frozenset[str] = frozenset(
    {
        "eval",
        "exec",
        "compile",
        "open",
        "input",
        "globals",
        "locals",
        "vars",
        "dir",
        "getattr",
        "setattr",
        "delattr",
        "breakpoint",
        "exit",
        "quit",
    }
)

# Dunder attributes that are safe to access
SAFE_DUNDERS: frozenset[str] = frozenset(
    {
        "__len__",
        "__str__",
        "__repr__",
        "__iter__",
        "__next__",
        "__getitem__",
        "__setitem__",
        "__contains__",
        "__bool__",
        "__eq__",
        "__ne__",
        "__lt__",
        "__le__",
        "__gt__",
        "__ge__",
        "__add__",
        "__sub__",
        "__mul__",
        "__truediv__",
        "__floordiv__",
        "__mod__",
        "__pow__",
        "__neg__",
        "__pos__",
        "__abs__",
        "__int__",
        "__float__",
        "__complex__",
        "__round__",
        "__hash__",
    }
)

# Dangerous function/method names to block in call expressions
_DANGEROUS_CALL_NAMES: frozenset[str] = frozenset({"eval", "exec", "__import__"})


def _validate_ast(code: str) -> None:
    """Validate code AST for security violations."""
    try:
        tree = ast.parse(code)
    except SyntaxError as e:
        raise CodeActSecurityError(f"Syntax error: {e}") from e

    for node in ast.walk(tree):
        # Block import statements
        if isinstance(node, ast.Import):
            for alias in node.names:
                module = alias.name.split(".")[0]
                if module not in ALLOWED_MODULES:
                    raise CodeActSecurityError(f"Import not allowed: {alias.name}")

        if isinstance(node, ast.ImportFrom) and node.module:
            module = node.module.split(".")[0]
            if module not in ALLOWED_MODULES:
                raise CodeActSecurityError(f"Import not allowed: {node.module}")

        # Block dangerous function calls (SIM102: combined conditions)
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id in _DANGEROUS_CALL_NAMES:
                raise CodeActSecurityError(f"Dangerous function call: {node.func.id}")
            if isinstance(node.func, ast.Attribute) and node.func.attr in _DANGEROUS_CALL_NAMES:
                raise CodeActSecurityError(f"Dangerous method call: {node.func.attr}")

        # Block dunder access except safe ones (SIM102: combined condition)
        if (
            isinstance(node, ast.Attribute)
            and node.attr.startswith("__")
            and node.attr.endswith("__")
            and node.attr not in SAFE_DUNDERS
        ):
            raise CodeActSecurityError(f"Dangerous dunder access: {node.attr}")


def _create_restricted_import() -> Callable[..., Any]:
    """Create a restricted __import__ function."""

    def restricted_import(
        name: str,
        globals_dict: dict[str, Any] | None = None,
        locals_dict: dict[str, Any] | None = None,
        fromlist: tuple[str, ...] = (),
        level: int = 0,
    ) -> Any:
        module = name.split(".")[0]
        if module not in ALLOWED_MODULES:
            raise ImportError(f"Module not allowed: {name}")
        return builtins.__import__(name, globals_dict, locals_dict, fromlist, level)

    return restricted_import


def _create_restricted_builtins() -> dict[str, Any]:
    """Create restricted builtins dictionary."""
    restricted: dict[str, Any] = {}
    for name in dir(builtins):
        if name not in BLOCKED_BUILTINS:
            restricted[name] = getattr(builtins, name)
    restricted["__import__"] = _create_restricted_import()
    return restricted


def _worker(code: str, conn: Any) -> None:
    """Worker process that executes code and sends result back via pipe."""
    try:
        # Validate AST in worker process
        _validate_ast(code)

        # Create execution environment
        restricted_globals: dict[str, Any] = {
            "__builtins__": _create_restricted_builtins(),
            "__name__": "__main__",
            "__doc__": None,
        }
        restricted_locals: dict[str, Any] = {}

        # Execute code
        exec(code, restricted_globals, restricted_locals)  # noqa: S102

        # Extract result (SIM401: use dict.get)
        result = restricted_locals.get("result")

        # Send result back
        conn.send({"success": True, "result": result})
    except Exception as e:
        conn.send({"success": False, "error": str(e), "type": type(e).__name__})
    finally:
        conn.close()


class CodeActSandbox:
    """Safe execution sandbox for Python code with multiprocessing isolation."""

    def __init__(self, timeout: float = 5.0) -> None:
        """Initialize sandbox with timeout.

        Args:
            timeout: Maximum execution time in seconds
        """
        self.timeout = timeout

    def execute(self, code: str) -> Any:
        """Execute code in isolated process with timeout.

        Args:
            code: Python code to execute

        Returns:
            Result of execution (value assigned to 'result' variable)

        Raises:
            CodeActSecurityError: Code violates security policy
            CodeActTimeoutError: Execution exceeded timeout
            CodeActExecutionError: Execution failed
        """
        # Validate AST in parent process first (fast fail)
        _validate_ast(code)

        # Create pipe for IPC
        parent_conn, child_conn = CTX.Pipe()

        # Create worker process
        process = CTX.Process(target=_worker, args=(code, child_conn), daemon=True)
        process.start()

        # Close child end in parent
        child_conn.close()

        try:
            # Wait for result with timeout using poll()
            if parent_conn.poll(self.timeout):
                result = parent_conn.recv()
                process.join()

                if result["success"]:
                    return result["result"]

                # Re-raise the original exception type if possible
                error_type = result["type"]
                error_msg = result["error"]

                if error_type == "CodeActSecurityError":
                    raise CodeActSecurityError(error_msg)
                if error_type == "ImportError":
                    raise CodeActSecurityError(f"Import error: {error_msg}")
                raise CodeActExecutionError(f"{error_type}: {error_msg}")

            # Timeout - terminate process
            process.terminate()
            process.join(1)  # Give it 1 second to terminate gracefully
            if process.is_alive():
                process.kill()
                process.join()
            raise CodeActTimeoutError(f"Code execution exceeded {self.timeout:.1f}s timeout")
        finally:
            # Clean up
            parent_conn.close()
            if process.is_alive():
                process.terminate()
                process.join()

    async def aexecute(self, code: str) -> Any:
        """Async wrapper for execute().

        Args:
            code: Python code to execute

        Returns:
            Result of execution
        """
        import asyncio

        loop = asyncio.get_event_loop()
        return await loop.run_in_executor(None, self.execute, code)
