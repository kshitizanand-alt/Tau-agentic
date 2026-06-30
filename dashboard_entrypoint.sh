#!/bin/bash
set -e

# =============================================================================
# dashboard_entrypoint.sh — Entrypoint for xyne-eval-ops-dashboard
#
# The dashboard passes CLI arguments in this format:
#   <api_key> <run_id> --agent <agent> --environment <domain> \
#       --max-concurrency <n> --number-of-trials <n> --task-range <range>
#
# Example:
#   sk-xxx 69fb6708-00a9-4e55-b368-ec96f21c81d7 --agent claude \
#       --environment airline --max-concurrency 1 --number-of-trials 1 --task-range 0-1
#
# This script maps those to tau-agentic arguments and runs the benchmark.
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

# Default values
API_BASE=""
API_KEY=""
AGENT_LLM=""
DOMAIN="airline"
MAX_CONCURRENCY=1
AGENT="claude"
TASK_RANGE="0-99"
NUM_TRIALS=1
RUN_ID=""

# Debug: show raw args
echo -e "${BLUE}[DEBUG]${NC} Raw args: $*"
echo -e "${BLUE}[DEBUG]${NC} Env vars: GRID_AI_API_KEY='${GRID_AI_API_KEY:0:4}***' ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:0:4}***'"

# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------
# Supports BOTH the actual dashboard format (positional key + --agent etc.)
# AND the legacy format (--api-base, --api-key, --agent-llm, --domain)
# ---------------------------------------------------------------------------

positional_count=0

while [[ $# -gt 0 ]]; do
    arg="$1"

    # ----- positional args (actual dashboard format) -----
    if [[ "$arg" != --* ]]; then
        positional_count=$((positional_count + 1))
        if [ "$positional_count" -eq 1 ]; then
            API_KEY="$arg"
            echo -e "${BLUE}[DEBUG]${NC} Positional arg 1 → API_KEY"
        elif [ "$positional_count" -eq 2 ]; then
            RUN_ID="$arg"
            echo -e "${BLUE}[DEBUG]${NC} Positional arg 2 → RUN_ID"
        else
            echo -e "${YELLOW}[WARN]${NC} Extra positional arg ignored: $arg"
        fi
        shift
        continue
    fi

    # ----- named args (both actual dashboard and legacy formats) -----
    case "$arg" in
        # Legacy --api-base
        --api-base=*)
            API_BASE="${arg#*=}"
            shift
            ;;
        --api-base)
            API_BASE="${2:-}"
            shift 2
            ;;

        # Dashboard API key (legacy --api-key or positional)
        --api-key=*)
            API_KEY="${arg#*=}"
            shift
            ;;
        --api-key)
            API_KEY="${2:-}"
            shift 2
            ;;

        # Actual dashboard --agent  (maps to AGENT + derives AGENT_LLM)
        --agent=*)
            AGENT="${arg#*=}"
            shift
            ;;
        --agent)
            AGENT="${2:-}"
            shift 2
            ;;

        # Legacy --agent-llm
        --agent-llm=*)
            AGENT_LLM="${arg#*=}"
            shift
            ;;
        --agent-llm)
            AGENT_LLM="${2:-}"
            shift 2
            ;;

        # Dashboard --model (explicit model override)
        --model=*)
            AGENT_LLM="${arg#*=}"
            shift
            ;;
        --model)
            AGENT_LLM="${2:-}"
            shift 2
            ;;

        # Actual dashboard --environment  (maps to DOMAIN)
        --environment=*)
            DOMAIN="${arg#*=}"
            shift
            ;;
        --environment)
            DOMAIN="${2:-}"
            shift 2
            ;;

        # Legacy --domain
        --domain=*)
            DOMAIN="${arg#*=}"
            shift
            ;;
        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;

        # Actual dashboard --max-concurrency
        --max-concurrency=*)
            MAX_CONCURRENCY="${arg#*=}"
            shift
            ;;
        --max-concurrency)
            MAX_CONCURRENCY="${2:-}"
            shift 2
            ;;

        # Actual dashboard --number-of-trials
        --number-of-trials=*)
            NUM_TRIALS="${arg#*=}"
            shift
            ;;
        --number-of-trials)
            NUM_TRIALS="${2:-}"
            shift 2
            ;;

        # Actual dashboard --task-range
        --task-range=*)
            TASK_RANGE="${arg#*=}"
            shift
            ;;
        --task-range)
            TASK_RANGE="${2:-}"
            shift 2
            ;;

        # Unknown
        *)
            echo -e "${YELLOW}[WARN]${NC} Unknown argument: $arg (skipping)"
            shift
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Derive model from agent if not explicitly provided
# ---------------------------------------------------------------------------
# NOTE: This fallback should only fire for direct CLI runs. For dashboard runs
# the model the user picked in the UI must arrive as --model (the eval's
# input_config_schema.json declares a "model" field so the dashboard forwards
# it). If we reach this branch on a dashboard run, the model selection was
# DROPPED upstream (usually the eval was registered with a schema missing the
# "model" field) and the run is silently NOT using the selected model — hence
# the loud warning. See DASHBOARD_REGISTRATION.md.
if [ -z "$AGENT_LLM" ]; then
    case "$AGENT" in
        claude)
            AGENT_LLM="private-large"
            ;;
        opencode|open-code)
            AGENT_LLM="glm-latest"
            ;;
        *)
            AGENT_LLM="private-large"
            ;;
    esac
    echo -e "${YELLOW}[WARN]${NC} No --model received — falling back to hardcoded default '$AGENT_LLM' for agent '$AGENT'."
    echo -e "${YELLOW}[WARN]${NC} The UI model selection was NOT applied. Re-register the eval with a schema that includes the 'model' field (see DASHBOARD_REGISTRATION.md)."
fi

# ---------------------------------------------------------------------------
# API key resolution
# ---------------------------------------------------------------------------
# Priority:
#   1. Positional / --api-key argument from dashboard
#   2. GRID_AI_API_KEY environment variable (primary)
#   3. DASHBOARD_API_KEY environment variable (fallback)
# The same key is exported as GRID_AI_API_KEY and ANTHROPIC_API_KEY because
# Claude Code expects the Anthropic-format env var.
# ---------------------------------------------------------------------------
if [ -z "$API_KEY" ]; then
    API_KEY="${GRID_AI_API_KEY:-${DASHBOARD_API_KEY:-}}"
    if [ -n "$API_KEY" ]; then
        echo -e "${BLUE}[INFO]${NC} Using API key from environment variable"
    fi
fi

# ---------------------------------------------------------------------------
# Generate run ID if not provided
# ---------------------------------------------------------------------------
if [ -z "$RUN_ID" ]; then
    RUN_ID="dashboard_$(date +%s)"
fi

# ---------------------------------------------------------------------------
# Debug dump
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESULTS_DIR="${SCRIPT_DIR}/results"
mkdir -p "$RESULTS_DIR"
DEBUG_FILE="${RESULTS_DIR}/debug_env.txt"

cat > "$DEBUG_FILE" <<EOF
Debug info generated at $(date)
Raw args: $*
Parsed API_BASE: '$API_BASE'
Parsed API_KEY set: $([ -n "$API_KEY" ] && echo yes || echo no)
Parsed AGENT: '$AGENT'
Parsed AGENT_LLM: '$AGENT_LLM'
Parsed DOMAIN: '$DOMAIN'
Parsed MAX_CONCURRENCY: '$MAX_CONCURRENCY'
Parsed NUM_TRIALS: '$NUM_TRIALS'
Parsed TASK_RANGE: '$TASK_RANGE'
Parsed RUN_ID: '$RUN_ID'

Environment variables checked:
GRID_AI_API_KEY='${GRID_AI_API_KEY:0:4}***'
ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:0:4}***'
EOF

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
if [ -z "$AGENT_LLM" ]; then
    echo -e "${RED}[ERROR]${NC} Could not determine model. Pass --agent-llm or --agent."
    exit 1
fi

if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}[WARN]${NC} No API key found; relying on pre-configured environment"
fi

echo -e "${BLUE}[INFO]${NC} Starting tau-agentic benchmark"
echo -e "${BLUE}[INFO]${NC} Agent: $AGENT"
echo -e "${BLUE}[INFO]${NC} Model: $AGENT_LLM"
echo -e "${BLUE}[INFO]${NC} Domain: $DOMAIN"
echo -e "${BLUE}[INFO]${NC} Task Range: $TASK_RANGE"
echo -e "${BLUE}[INFO]${NC} Max Concurrency: $MAX_CONCURRENCY"
echo -e "${BLUE}[INFO]${NC} Num Trials: $NUM_TRIALS"
echo -e "${BLUE}[INFO]${NC} Run ID: $RUN_ID"
echo ""

# ---------------------------------------------------------------------------
# Configure API keys
# ---------------------------------------------------------------------------
if [ -n "$API_KEY" ]; then
    export GRID_AI_API_KEY="$API_KEY"
    export ANTHROPIC_API_KEY="$API_KEY"
    export OPENAI_API_KEY="$API_KEY"
fi
if [ -n "$API_BASE" ]; then
    export OPENAI_API_BASE="$API_BASE"
fi

echo -e "${BLUE}[INFO]${NC} API keys configured"

# Determine agent executable from agent name
case "$AGENT" in
    opencode|open-code)
        AGENT_TYPE="opencode"
        ;;
    *)
        AGENT_TYPE="claude"
        ;;
esac

echo -e "${BLUE}[INFO]${NC} Selected agent type: $AGENT_TYPE"

# ---------------------------------------------------------------------------
# Run benchmark
# ---------------------------------------------------------------------------
cd "$SCRIPT_DIR"
echo -e "${BLUE}[INFO]${NC} Using script directory: $SCRIPT_DIR"

# Run benchmark; capture exit code without letting set -e abort the entrypoint.
# A non-zero exit (agent timeout, score=0, etc.) is a model performance outcome,
# not a pipeline failure — swe-auto-eval treats these the same way (run_status=
# "no_patch" vs "error"). Results are collected regardless of exit code.
"$SCRIPT_DIR/run_benchmark.sh" \
    "$AGENT_TYPE" \
    "$AGENT_LLM" \
    "$DOMAIN" \
    "$TASK_RANGE" \
    "$RUN_ID" \
    "$MAX_CONCURRENCY" || {
    echo -e "${YELLOW}[WARN]${NC} run_benchmark.sh exited non-zero — collecting whatever results exist"
}

# ---------------------------------------------------------------------------
# Copy results for dashboard pickup
# ---------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[INFO]${NC} Copying results to ${RESULTS_DIR}..."

mkdir -p "$RESULTS_DIR"

if [ -d "output/$RUN_ID/summary" ] && [ -n "$(ls -A "output/$RUN_ID/summary" 2>/dev/null)" ]; then
    cp -r "output/$RUN_ID/summary/"* "$RESULTS_DIR/"
    echo -e "${GREEN}[SUCCESS]${NC} Summary copied to ${RESULTS_DIR}/"
else
    echo -e "${YELLOW}[WARN]${NC} No summary files to copy"
fi

RESULTS_FILE="output/$RUN_ID/results_${AGENT_TYPE}+${AGENT_LLM}.json"
if [ -f "$RESULTS_FILE" ]; then
    cp "$RESULTS_FILE" "$RESULTS_DIR/results.json"
    echo -e "${GREEN}[SUCCESS]${NC} Raw results copied to ${RESULTS_DIR}/results.json"
else
    echo -e "${YELLOW}[WARN]${NC} Results file not found: $RESULTS_FILE"
fi

# Generate dashboard-compatible output with Average score
SUMMARY_JSON="${RESULTS_DIR}/summary.json"
if [ -f "$SUMMARY_JSON" ]; then
    PASS_AT_1=$(python3 -c "import json; print(json.load(open('$SUMMARY_JSON'))['pass_at_1'])" 2>/dev/null || echo "N/A")
    if [ "$PASS_AT_1" != "N/A" ]; then
        echo ""
        echo "=========================================="
        echo "Average: $PASS_AT_1"
        echo "=========================================="
        echo ""
    else
        echo -e "${YELLOW}[WARN]${NC} Could not extract pass_at_1 from summary"
    fi
fi

# Write the results file in the format expected by the eval-runner Rust service.
# The runner looks for $EVAL_RUNNER_OUTPUT_DIR/{eval_run_id}_results.json after
# run.sh completes. Without it the runner returns Ok(None) and marks the run
# FAILED ("No results file produced by run.sh") even when the benchmark scored > 0.
EVAL_OUTPUT_DIR="${EVAL_RUNNER_OUTPUT_DIR:-${SCRIPT_DIR}/output}"
mkdir -p "$EVAL_OUTPUT_DIR"
EVAL_RESULTS_FILE="${EVAL_OUTPUT_DIR}/${RUN_ID}_results.json"

# Only write the results file when the benchmark actually ran (run_status=completed).
# For infra_error runs (missing CLI, setup failures, etc.) we intentionally skip it:
# the eval-runner returns Ok(None) → marks the run FAILED on the dashboard, which
# correctly distinguishes "agent scored 0" (COMPLETED) from "pipeline never started".
RUN_STATUS_VAL="unknown"
if [ -f "$SUMMARY_JSON" ]; then
    RUN_STATUS_VAL=$(python3 -c "import json; print(json.load(open('$SUMMARY_JSON')).get('run_status','unknown'))" 2>/dev/null || echo "unknown")
fi

if [ -f "$SUMMARY_JSON" ] && [ "$RUN_STATUS_VAL" != "infra_error" ]; then
    SUMMARY_PATH="$SUMMARY_JSON" EVAL_RESULTS_PATH="$EVAL_RESULTS_FILE" python3 -c "
import json, os
summary = json.load(open(os.environ['SUMMARY_PATH']))
resolved   = summary.get('resolved', 0)
unresolved = summary.get('unresolved', 0)
total      = summary.get('total_tasks', 0)
result = {
    'metrics': {
        'main': {'name': 'total_resolved', 'value': float(resolved)},
        'secondary': {
            'pass@1': float(resolved)
        },
        'additional': {
            'pass@1': {
                'resolved':    resolved,
                'unresolved':  unresolved,
                'total_tasks': total
            },
            'run_status': summary.get('run_status', 'completed'),
            'agent':      summary.get('agent', ''),
            'model':      summary.get('model', ''),
            'domain':     summary.get('domain', '')
        }
    }
}
json.dump(result, open(os.environ['EVAL_RESULTS_PATH'], 'w'), indent=2)
" 2>/dev/null || printf '{"metrics":{"main":{"name":"total_resolved","value":0.0},"secondary":{},"additional":{"run_status":"error"}}}\n' > "$EVAL_RESULTS_FILE"
    echo -e "${BLUE}[INFO]${NC} Eval-runner results file written: ${EVAL_RESULTS_FILE}"
else
    echo -e "${YELLOW}[WARN]${NC} Skipping results file (run_status=${RUN_STATUS_VAL}) — dashboard will mark run FAILED"
fi

echo -e "${GREEN}[SUCCESS]${NC} tau-agentic benchmark complete!"
echo -e "${BLUE}[INFO]${NC} Results available in ${RESULTS_DIR}/"
