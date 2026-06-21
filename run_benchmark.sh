#!/bin/bash
set -uo pipefail
# =============================================================================
# run_benchmark.sh — Dashboard-compatible entry point for tau-bench agentic.
#
# Usage:
#   ./run_benchmark.sh <agent> <model> <domain> <task_ids> <run_id> [parallel]
#   ./run_benchmark.sh --api-key <key> --api-base <url> <agent> <model> ...
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

# ---------- parse optional dashboard-style args ----------
API_KEY=""
API_BASE=""

# Extract --api-key and --api-base from args, then shift them out
parsed_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --api-key)
            API_KEY="$2"
            shift 2
            ;;
        --api-key=*)
            API_KEY="${1#*=}"
            shift
            ;;
        --api-base)
            API_BASE="$2"
            shift 2
            ;;
        --api-base=*)
            API_BASE="${1#*=}"
            shift
            ;;
        *)
            parsed_args+=("$1")
            shift
            ;;
    esac
done

# Restore positional args
set -- "${parsed_args[@]}"

# ---------- argument parsing ----------
if [ "$#" -lt 5 ]; then
    echo "Error: Missing required arguments"
    echo ""
    echo "Usage: $0 [<dashboard_opts>] <agent> <model> <domain> <task_ids> <run_id> [parallel]"
    echo ""
    echo "Dashboard options:"
    echo "  --api-key <key>   - API key (also checks env vars)"
    echo "  --api-base <url>  - API base URL"
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
    echo "  $0 --api-key sk-xxx claude private-large retail \"0 1 2\" test_run"
    exit 1
fi

AGENT="$1"
MODEL="$2"
DOMAIN="$3"
TASK_IDS_ARG="$4"
RUN_ID="$5"
PARALLEL="${6:-1}"

# Expand ranges like "0-49" to "0 1 2 ... 49"
# Falls back to Python if seq is not available (minimal Linux distros)
expand_range() {
    local arg="$1"
    if [[ "$arg" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        if command -v seq >/dev/null 2>&1; then
            seq -s ' ' "$start" "$end"
        else
            # Fallback: Python is guaranteed since we built the venv
            python3 -c "print(' '.join(str(i) for i in range($start, $end + 1)))"
        fi
    else
        echo "$arg"
    fi
}

TASK_IDS=$(expand_range "$TASK_IDS_ARG")

# ---------- source environment ----------
if [ -f ".env" ]; then
    source .env
fi

# ---------- API key resolution (matches swe-auto-eval pattern) ----------
# Priority: CLI --api-key > env vars > secret files
if [ -n "$API_KEY" ]; then
    export GRID_AI_API_KEY="$API_KEY"
    export ANTHROPIC_API_KEY="$API_KEY"
    export OPENAI_API_KEY="$API_KEY"
    echo "[INFO] Using API key from --api-key argument"
else
    # Check many env var names dashboards might use
    found_key=""
    for var_name in GRID_AI_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY DASHBOARD_API_KEY API_KEY APIKEY API_TOKEN AUTH_TOKEN BEARER_TOKEN GRID_API_KEY GRIDAI_API_KEY EVAL_API_KEY MODEL_API_KEY; do
        val="${!var_name:-}"
        if [ -n "$val" ]; then
            found_key="$val"
            echo "[INFO] Using API key from $var_name environment variable"
            break
        fi
    done

    if [ -n "$found_key" ]; then
        export GRID_AI_API_KEY="$found_key"
        export ANTHROPIC_API_KEY="$found_key"
        export OPENAI_API_KEY="$found_key"
    else
        # Try secret files
        for secret_file in /run/secrets/api_key /secrets/api_key /etc/secrets/api_key /var/secrets/api_key /app/.api_key /app/secrets/api_key /tmp/api_key; do
            if [ -f "$secret_file" ]; then
                found_key="$(cat "$secret_file" | tr -d '\n')"
                echo "[INFO] Using API key from $secret_file"
                export GRID_AI_API_KEY="$found_key"
                export ANTHROPIC_API_KEY="$found_key"
                export OPENAI_API_KEY="$found_key"
                break
            fi
        done
    fi

    if [ -z "$found_key" ]; then
        echo "[WARN] No API key found. Checked env vars: GRID_AI_API_KEY, ANTHROPIC_API_KEY, OPENAI_API_KEY, DASHBOARD_API_KEY, API_KEY, etc."
        echo "[WARN] Attempting to run anyway — benchmark will likely fail if key is required."
    fi
fi

if [ -n "$API_BASE" ]; then
    export OPENAI_API_BASE="$API_BASE"
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