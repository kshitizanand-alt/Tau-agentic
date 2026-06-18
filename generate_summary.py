#!/usr/bin/env python3
"""
generate_summary.py — Generate dashboard-compatible summary from tau-bench results.

Usage:
    python3 generate_summary.py --run-id <run_id> --agent <agent> --model <model>

Example:
    python3 generate_summary.py --run-id run_001 --agent claude --model private-large
"""

import argparse
import json
from pathlib import Path


def generate_summary(run_id: str, agent: str, model: str, domain: str = None):
    """Generate summary files from tau-bench results."""
    out_dir = Path(f"output/{run_id}")
    results_file = out_dir / f"results_{agent}+{model}.json"

    if not results_file.exists():
        print(f"ERROR: Results file not found: {results_file}")
        return False

    with open(results_file) as f:
        data = json.load(f)

    rewards = data.get("rewards", [])
    avg_reward = data.get("average_reward", 0.0)

    # Calculate statistics
    passed = [i for i, r in enumerate(rewards) if r == 1.0]
    failed = [i for i, r in enumerate(rewards) if r == 0.0]
    partial = [i for i, r in enumerate(rewards) if 0 < r < 1.0]

    summary = {
        "run_id": run_id,
        "agent": agent,
        "model": model,
        "domain": domain or "unknown",
        "total_tasks": len(rewards),
        "resolved": len(passed),
        "unresolved": len(failed),
        "partial": len(partial),
        "pass_at_1": avg_reward,
        "rewards": rewards,
        "passed_task_indices": passed,
        "failed_task_indices": failed,
        "partial_task_indices": partial,
    }

    summary_dir = out_dir / "summary"
    summary_dir.mkdir(exist_ok=True)

    # Write JSON summary
    with open(summary_dir / "summary.json", "w") as f:
        json.dump(summary, f, indent=2)

    # Write resolved list
    with open(summary_dir / "resolved.txt", "w") as f:
        for tid in passed:
            f.write(f"{tid}\n")

    # Write unresolved list
    with open(summary_dir / "unresolved.txt", "w") as f:
        for tid in failed:
            f.write(f"{tid}\n")

    # Write human-readable report
    report_lines = [
        "=" * 70,
        "        Tau-Bench Agentic Evaluation Report",
        "=" * 70,
        "",
        f"Run ID:        {run_id}",
        f"Agent:         {agent}",
        f"Model:         {model}",
        f"Domain:        {domain or 'unknown'}",
        f"Total Tasks:   {len(rewards)}",
        "",
        "-" * 70,
        "                    Results Summary",
        "-" * 70,
        "",
    ]

    if rewards:
        report_lines.extend([
            f"  Resolved:     {len(passed)} ({len(passed)/len(rewards)*100:.1f}%)",
            f"  Unresolved:   {len(failed)} ({len(failed)/len(rewards)*100:.1f}%)",
            f"  Partial:      {len(partial)}",
        ])
    else:
        report_lines.extend([
            "  Resolved:     0",
            "  Unresolved:   0",
            "  Partial:      0",
        ])

    report_lines.extend([
        f"  Pass@1:       {avg_reward:.4f}",
        "",
        "=" * 70,
    ])

    with open(summary_dir / "report.txt", "w") as f:
        f.write("\n".join(report_lines))

    print(f"Summary generated: {summary_dir}")
    print(f"  - summary.json")
    print(f"  - resolved.txt")
    print(f"  - unresolved.txt")
    print(f"  - report.txt")
    print("")
    print(f"Pass@1 Score: {avg_reward:.4f}")
    print("")
    print("=" * 50)
    print(f"Average: {avg_reward:.4f}")
    print("=" * 50)

    return True


def main():
    parser = argparse.ArgumentParser(description="Generate tau-bench summary")
    parser.add_argument("--run-id", required=True, help="Run identifier")
    parser.add_argument("--agent", required=True, help="Agent name")
    parser.add_argument("--model", required=True, help="Model name")
    parser.add_argument("--domain", default=None, help="Domain (retail/airline)")
    args = parser.parse_args()

    success = generate_summary(args.run_id, args.agent, args.model, args.domain)
    if not success:
        exit(1)


if __name__ == "__main__":
    main()