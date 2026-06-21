#!/bin/bash
set -uo pipefail
# =============================================================================
# run_benchmark.sh — Dashboard-compatible entry point for tau-bench agentic.
#
# Usage:
#   ./run_benchmark.sh <agent> <model> <domain> <task_ids> <run_id> [parallel]
#
# Example:
#   ./run_benchmark.sh claude private-large retail "0 1 2" run_001 1
#   ./run_benchmark.sh opencode glm-latest airline "0-49" run_002 1
#
# This script wraps run_agentic.sh with dashboard-compatible arguments and
# generates summary files in the format expected by the evaluation dashboard.
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ---------- argument parsing ----------
if [ "$#" -lt 5 ]; then
    echo "Error: Missing required arguments"
    echo ""
    echo "Usage: $0 <agent> <model> <domain> <task_ids> <run_id> [parallel]"
    echo ""
    echo "Arguments:"
    echo "  agent     - Coding agent: claude | opencode"
    echo "  model     - Model under test (e.g., private-large, glm-latest)"
    echo "  domain    - Task domain: retail | airline"
    echo "  task_ids  - Space-separated task IDs (quoted) or range like \"0-49\""
    echo "  run_id    - Unique run identifier"
    echo "  parallel  - Number of parallel tasks (default: 1)"
    echo ""
    echo "Examples:"
    echo "  $0 claude private-large retail \"0 1 2\" test_run"
    echo "  $0 opencode glm-latest airline \"0-49\" run_001 1"
    exit 1
fi

AGENT="$1"
MODEL="$2"
DOMAIN="$3"
TASK_IDS_ARG="$4"
RUN_ID="$5"
PARALLEL="${6:-1}"

# Expand ranges like "0-49" to "0 1 2 ... 49"
expand_range() {
    local arg="$1"
    if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        seq -s ' ' "$start" "$end"
    else
        echo "$arg"
    fi
}

TASK_IDS=$(expand_range "$TASK_IDS_ARG")

# ---------- source environment ----------
if [ -f ".env" ]; then
    source .env
fi

# If API key is passed via env (from dashboard), use it
if [ -n "${GRID_AI_API_KEY:-}" ]; then
    : # already set
elif [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    export GRID_AI_API_KEY="$ANTHROPIC_API_KEY"
elif [ -n "${OPENAI_API_KEY:-}" ]; then
    export GRID_AI_API_KEY="$OPENAI_API_KEY"
else
    echo "Error: No API key found. Set GRID_AI_API_KEY, ANTHROPIC_API_KEY, or OPENAI_API_KEY."
    exit 1
fi

# ---------- run the benchmark ----------
echo "=========================================="
echo "  Tau-Bench Agentic Benchmark"
echo "=========================================="
echo "  Agent:    $AGENT"
echo "  Model:    $MODEL"
echo "  Domain:   $DOMAIN"
echo "  Tasks:    $TASK_IDS"
echo "  Run ID:   $RUN_ID"
echo "  Parallel: $PARALLEL"
echo "=========================================="

./run_agentic.sh \
    --agent "$AGENT" \
    --model "$MODEL" \
    --domain "$DOMAIN" \
    --task-ids "$TASK_IDS" \
    --run-id "$RUN_ID" \
    --tmux

# ---------- generate dashboard-compatible summary ----------
echo ""
echo "Generating dashboard summary..."

python3 - "$RUN_ID" "$AGENT" "$MODEL" "$DOMAIN" "$TASK_IDS" <<'PY'
import sys
import json
from pathlib import Path

run_id = sys.argv[1]
agent = sys.argv[2]
model = sys.argv[3]
domain = sys.argv[4]
task_ids = sys.argv[5].split()

out_dir = Path(f"output/{run_id}")
results_file = out_dir / f"results_{agent}+{model}.json"

if not results_file.exists():
    print(f"ERROR: Results file not found: {results_file}")
    sys.exit(1)

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
    "domain": domain,
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
    f"Domain:        {domain}",
    f"Total Tasks:   {len(rewards)}",
    "",
    "-" * 70,
    "                    Results Summary",
    "-" * 70,
    f"",
    f"  Resolved:     {len(passed)} ({len(passed)/len(rewards)*100:.1f}%)" if rewards else "  Resolved:     0",
    f"  Unresolved:   {len(failed)} ({len(failed)/len(rewards)*100:.1f}%)" if rewards else "  Unresolved:   0",
    f"  Partial:      {len(partial)}",
    f"  Pass@1:       {avg_reward:.4f}",
    "",
    "=" * 70,
]

with open(summary_dir / "report.txt", "w") as f:
    f.write("\n".join(report_lines))

print(f"Summary generated: {summary_dir}")
print(f"  - summary.json")
print(f"  - resolved.txt")
print(f"  - unresolved.txt")
print(f"  - report.txt")
print("")
print(f"Pass@1 Score: {avg_reward:.4f}")
PY

echo ""
echo "=========================================="
echo "  Benchmark Complete"
echo "=========================================="
echo "  Results: output/$RUN_ID/"
echo "  Summary: output/$RUN_ID/summary/"
echo "=========================================="