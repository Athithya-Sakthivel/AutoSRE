#!/usr/bin/env python3
"""Validate Argo Rollout manifests for the canary shape used by this project.

Expected canary steps:
    setWeight: 0
    pause: {}                  # indefinite validation pause
    setWeight: 10
    pause: {}                  # indefinite observation pause
    setWeight: 100

Also requires:
    strategy.canary.canaryService and stableService
    trafficRouting.plugins with `argoproj-labs/gatewayAPI`
    that plugin references an httpRoute and namespace

Usage:
    validate-canary-manifests.py <manifest.yaml>

The script runs `kubectl apply --dry-run=client -f <manifest> -o json`
to obtain a schema-validated JSON representation, then performs shape checks.
"""

import json
import subprocess
import sys
from pathlib import Path
from typing import Any


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def get_rollout_json(manifest_file: str) -> dict[str, Any]:
    """Return JSON for the Rollout after server dry-run validation."""
    cmd = [
        "kubectl",
        "apply",
        "--dry-run=client",
        "-f",
        manifest_file,
        "-o",
        "json",
    ]
    result = subprocess.run(cmd, capture_output=True, text=True)
    if result.returncode != 0:
        fail(
            f"kubectl dry-run failed:\n"
            f"{result.stderr or result.stdout or 'unknown error'}"
        )

    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        fail(f"kubectl output was not valid JSON: {exc}")

    if data.get("kind") != "Rollout":
        fail(f"Expected kind Rollout, got {data.get('kind')}")

    return data


def validate_canary(rollout: dict[str, Any]) -> None:
    strategy = rollout.get("spec", {}).get("strategy", {})
    canary = strategy.get("canary")
    if not isinstance(canary, dict):
        fail("Rollout does not define a canary strategy")

    # Services
    canary_service = canary.get("canaryService")
    stable_service = canary.get("stableService")
    if not canary_service:
        fail("canaryService is missing")
    if not stable_service:
        fail("stableService is missing")

    # Traffic routing plugin
    plugins = canary.get("trafficRouting", {}).get("plugins", {})
    gateway_plugin = plugins.get("argoproj-labs/gatewayAPI")
    if not isinstance(gateway_plugin, dict):
        fail(
            "trafficRouting.plugins must contain "
            "'argoproj-labs/gatewayAPI'"
        )
    if not gateway_plugin.get("httpRoute"):
        fail("gatewayAPI plugin must specify httpRoute")
    if not gateway_plugin.get("namespace"):
        fail("gatewayAPI plugin must specify namespace")

    # Canary steps shape
    steps = canary.get("steps")
    if not isinstance(steps, list) or len(steps) < 5:
        fail("canary steps must contain at least 5 entries")

    first_weight = steps[0].get("setWeight")
    if first_weight != 0:
        fail("first step must be setWeight: 0")

    if not isinstance(steps[1].get("pause"), dict):
        fail("second step must be an indefinite pause")

    # Check 10% step and following indefinite pause
    ten_percent_found = False
    for i in range(2, len(steps) - 2):
        if steps[i].get("setWeight") == 10:
            ten_percent_found = True
            if not isinstance(steps[i + 1].get("pause"), dict):
                fail("step after setWeight: 10 must be an indefinite pause")
            break

    if not ten_percent_found:
        fail("must contain setWeight: 10 followed by pause")

    last_weight = steps[-1].get("setWeight")
    if last_weight != 100:
        fail("final step must be setWeight: 100")


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <manifest.yaml>", file=sys.stderr)
        return 2

    manifest_file = sys.argv[1]
    path = Path(manifest_file)
    if not path.is_file():
        print(f"Manifest not found: {manifest_file}", file=sys.stderr)
        return 2

    rollout = get_rollout_json(manifest_file)
    try:
        validate_canary(rollout)
    except Exception as exc:
        fail(f"Validation failed: {exc}")

    print("Canary manifest is valid.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
