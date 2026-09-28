"""Print aggregate evaluation metrics. Invoked by test_e2e.sh Phase 8."""

from __future__ import annotations

import sys
from pathlib import Path

# Resolve to the agents/ directory regardless of the caller's CWD.
_AGENTS_DIR = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(_AGENTS_DIR))

from eval.conftest import compute_aggregate_metrics  # noqa: E402


def main() -> None:
    m = compute_aggregate_metrics()

    print()
    print("=========================================")
    print("  EVALUATION RESULTS")
    print("=========================================")
    print(f"  Total incidents:      {m['total_incidents']}")
    print(f"  Resolved:             {m['resolved_count']}")
    print(f"  No action:            {m['no_action_count']}")
    print(f"  Failed:               {m['failed_count']}")
    print()
    print(f"  Avg active MTTR:      {m['avg_mttr_seconds']}s")
    print(f"  Avg wall clock:       {m['avg_wall_clock_seconds']}s")
    print(f"  Avg backoff:          {m['avg_backoff_seconds']}s")
    print(f"  Baseline MTTR:        {m['baseline_mttr_seconds']}s")
    print(f"  MTTR reduction:       {m['mttr_reduction_pct']}%")
    print()
    print(f"  Total cost:           ${m['total_cost_usd']:.4f}")
    print(f"  Avg cost/incident:    ${m['avg_cost_usd']:.4f}")
    print(f"  Total tokens:         {m['total_tokens']:,}")
    print(f"  Avg tokens:           {m['avg_tokens']:,}")
    print(f"  Safety violations:    {m['safety_violations']}")
    print()

    if m["per_incident"]:
        header = (
            f"  {'ID':<10} {'Status':<12} {'Active':>8} {'Wall':>8} {'Backoff':>8} {'Cost':>10}"
        )
        rule = f"  {'-' * 10} {'-' * 12} {'-' * 8} {'-' * 8} {'-' * 8} {'-' * 10}"
        print(header)
        print(rule)
        for inc in m["per_incident"]:
            st = inc["status"]
            if st == "resolved":
                badge = f"[ok] {st}"
            elif st == "no_action":
                badge = f"[--] {st}"
            elif st == "failed":
                badge = f"[!!] {st}"
            else:
                badge = f"[?] {st}"
            print(
                f"  {inc['incident_id']:<10} {badge:<12} "
                f"{inc['mttr_seconds']:>7.1f}s "
                f"{inc['wall_clock_seconds']:>7.1f}s "
                f"{inc['backoff_seconds']:>7.1f}s "
                f"${inc['cost_usd']:>9.4f}"
            )
        print()

    print("=========================================")


if __name__ == "__main__":
    main()
