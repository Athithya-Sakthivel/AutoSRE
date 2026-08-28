#!/usr/bin/env python3

"""Fail closed when pod-mode canary percentages would create zero replicas."""

from __future__ import annotations

import argparse
import json
import math
import subprocess
import sys
from pathlib import Path
from typing import Any


def get_manifest_replicas(deployment_manifest: str) -> int:
    manifest_path = Path(deployment_manifest)

    if not manifest_path.is_file():
        raise SystemExit(
            f"Deployment manifest does not exist: {deployment_manifest}"
        )

    result = subprocess.run(
        [
            "kubectl",
            "create",
            "--dry-run=client",
            "-f",
            str(manifest_path),
            "-o",
            "json",
        ],
        check=True,
        text=True,
        capture_output=True,
    )

    try:
        obj: dict[str, Any] = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(
            "Deployment manifest did not produce valid JSON via kubectl"
        ) from exc

    if obj.get("kind") != "Deployment":
        raise SystemExit(
            f"Expected a Deployment manifest, got {obj.get('kind')!r}"
        )

    spec = obj.get("spec")

    if not isinstance(spec, dict):
        raise SystemExit("Deployment manifest must contain spec")

    if "replicas" not in spec:
        raise SystemExit(
            "Deployment manifest must declare spec.replicas explicitly "
            "for pod-mode canary validation"
        )

    replicas = spec["replicas"]

    if isinstance(replicas, bool):
        raise SystemExit(f"Invalid deployment replica count: {replicas!r}")

    try:
        value = int(replicas)
    except (TypeError, ValueError) as exc:
        raise SystemExit(
            f"Invalid deployment replica count: {replicas!r}"
        ) from exc

    if value < 1:
        raise SystemExit(
            "Deployment must have at least one replica"
        )

    return value


def parse_percentages(raw_value: str) -> list[int]:
    values = [item.strip() for item in raw_value.split(",") if item.strip()]

    if not values:
        raise SystemExit("No canary percentages were provided")

    percentages: list[int] = []

    for raw in values:
        try:
            pct = int(raw)
        except ValueError as exc:
            raise SystemExit(
                f"Invalid canary percentage: {raw!r}"
            ) from exc

        if not 1 <= pct <= 99:
            raise SystemExit(
                f"Canary percentage must be between 1 and 99: {pct}"
            )

        percentages.append(pct)

    if percentages != sorted(set(percentages)):
        raise SystemExit(
            "Canary percentages must be unique and strictly increasing"
        )

    return percentages


def main() -> int:
    parser = argparse.ArgumentParser()

    parser.add_argument("--percentages", required=True)
    parser.add_argument("--deployment-manifest", required=True)
    parser.add_argument(
        "--mode",
        choices=["pod", "smi"],
        required=True,
    )
    parser.add_argument(
        "--baseline-and-canary-replicas",
        type=int,
        default=1,
    )

    args = parser.parse_args()

    percentages = parse_percentages(args.percentages)

    if args.mode == "smi":
        if args.baseline_and_canary_replicas < 1:
            raise SystemExit(
                "baseline-and-canary-replicas must be at least 1 for SMI canary"
            )
        return 0

    replicas = get_manifest_replicas(args.deployment_manifest)

    for pct in percentages:
        canary_replicas = math.floor(replicas * pct / 100)

        if canary_replicas < 1:
            print(
                f"ERROR: {pct}% of {replicas} replicas floors to 0 "
                "canary replicas. Increase replicas or use SMI.",
                file=sys.stderr,
            )
            return 1

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
