#!/bin/bash
set -euo pipefail
# =============================================================================
# run.sh — Universal entrypoint for tau-agentic.
#
# Handles two modes:
#   1. Dashboard mode: receives --api-base, --api-key, --agent-llm, etc.
#      Routes to dashboard_entrypoint.sh
#   2. Direct mode: receives positional args for run_benchmark.sh
#      Routes to run_benchmark.sh
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Detect dashboard-style invocation by checking for dashboard args
# Supports both --key and --key=value formats
is_dashboard=false
for arg in "$@"; do
    if [[ "$arg" == "--api-base"* ]] || [[ "$arg" == "--agent-llm"* ]] || [[ "$arg" == "--api-key"* ]] || [[ "$arg" == "--domain"* ]] || [[ "$arg" == "--max-concurrency"* ]]; then
        is_dashboard=true
        break
    fi
done

if $is_dashboard; then
    # Dashboard mode: route to dashboard_entrypoint.sh
    if [ -f "./dashboard_entrypoint.sh" ]; then
        exec bash "./dashboard_entrypoint.sh" "$@"
    else
        echo "[ERROR] dashboard_entrypoint.sh not found" >&2
        exit 1
    fi
else
    # Direct mode: route to run_benchmark.sh with positional args
    if [ -f "./run_benchmark.sh" ]; then
        exec bash "./run_benchmark.sh" "$@"
    else
        echo "[ERROR] run_benchmark.sh not found" >&2
        exit 1
    fi
fi