#!/usr/bin/env python3
"""Parse a Trivy JSON report and fail on HIGH/CRITICAL findings."""

import json
import sys
from collections import Counter


def main() -> int:
    if len(sys.argv) < 2:
        print("Usage: trivy_report.py <trivy.json>", file=sys.stderr)
        return 2

    with open(sys.argv[1]) as f:
        report = json.load(f)

    findings = []
    for result in report.get("Results") or []:
        target = result.get("Target") or "unknown"
        for vuln in result.get("Vulnerabilities") or []:
            severity = (vuln.get("Severity") or "").upper()
            if severity in {"HIGH", "CRITICAL"}:
                findings.append((target, vuln))

    if not findings:
        print("0")
        return 0

    print(len(findings))
    print(f"Trivy policy findings: {len(findings)} HIGH/CRITICAL vulnerability(s).")
    print()

    by_target: dict[str, list] = {}
    for target, vuln in findings:
        by_target.setdefault(target, []).append(vuln)

    for target, vulns in by_target.items():
        counts = Counter((v.get("Severity") or "UNKNOWN").upper() for v in vulns)
        parts = [f"{s}: {counts[s]}" for s in ("CRITICAL", "HIGH") if counts[s]]
        print(f"- {target} ({', '.join(parts)})")
        for vuln in vulns[:5]:
            vid = vuln.get("VulnerabilityID", "unknown")
            pkg = vuln.get("PkgName", "unknown")
            installed = vuln.get("InstalledVersion", "?")
            fixed = vuln.get("FixedVersion", "unfixed")
            title = vuln.get("Title", "")
            print(f"  - {vid} | {pkg} | installed: {installed} | fixed: {fixed}")
            if title:
                print(f"    {title}")
        remaining = len(vulns) - 5
        if remaining > 0:
            print(f"  - ... {remaining} more")

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
