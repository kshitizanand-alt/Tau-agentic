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
echo -e "${BLUE}[DEBUG]${NC} Env vars: DASHBOARD_API_KEY='${DASHBOARD_API_KEY:0:4}***' GRID_AI_API_KEY='${GRID_AI_API_KEY:0:4}***' ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:0:4}***' OPENAI_API_KEY='${OPENAI_API_KEY:0:4}***'"

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

        # Legacy --api-key
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
    echo -e "${BLUE}[INFO]${NC} Derived model '$AGENT_LLM' from agent '$AGENT'"
fi

# ---------------------------------------------------------------------------
# API key resolution
# ---------------------------------------------------------------------------
if [ -z "$API_KEY" ]; then
    API_KEY="${DASHBOARD_API_KEY:-${GRID_AI_API_KEY:-${ANTHROPIC_API_KEY:-${OPENAI_API_KEY:-${API_KEY:-${APIKEY:-${API_TOKEN:-${AUTH_TOKEN:-${BEARER_TOKEN:-${GRID_API_KEY:-${GRIDAI_API_KEY:-${EVAL_API_KEY:-${MODEL_API_KEY:-}}}}}}}}}}}}}"
    if [ -n "$API_KEY" ]; then
        echo -e "${BLUE}[INFO]${NC} Using API key from environment variable"
    fi
fi

if [ -z "$API_KEY" ]; then
    for secret_file in /run/secrets/api_key /secrets/api_key /etc/secrets/api_key /var/secrets/api_key /app/.api_key /app/secrets/api_key /tmp/api_key; do
        if [ -f "$secret_file" ]; then
            API_KEY="$(cat "$secret_file" | tr -d '\n')"
            echo -e "${BLUE}[INFO]${NC} Using API key from $secret_file"
            break
        fi
    done
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
mkdir -p /app/results 2>/dev/null || mkdir -p results
DEBUG_FILE="/app/results/debug_env.txt"
if [ ! -d "/app/results" ]; then
    DEBUG_FILE="results/debug_env.txt"
fi

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
DASHBOARD_API_KEY='${DASHBOARD_API_KEY:0:4}***'
GRID_AI_API_KEY='${GRID_AI_API_KEY:0:4}***'
ANTHROPIC_API_KEY='${ANTHROPIC_API_KEY:0:4}***'
OPENAI_API_KEY='${OPENAI_API_KEY:0:4}***'
API_KEY='${API_KEY:0:4}***'
APIKEY='${APIKEY:0:4}***'
API_TOKEN='${API_TOKEN:0:4}***'
AUTH_TOKEN='${AUTH_TOKEN:0:4}***'
BEARER_TOKEN='${BEARER_TOKEN:0:4}***'
GRID_API_KEY='${GRID_API_KEY:0:4}***'
GRIDAI_API_KEY='${GRIDAI_API_KEY:0:4}***'
EVAL_API_KEY='${EVAL_API_KEY:0:4}***'
MODEL_API_KEY='${MODEL_API_KEY:0:4}***'

All env vars containing 'KEY' or 'TOKEN':
$(env | grep -iE 'KEY|TOKEN' | sed 's/=.*/=***/' || echo 'None found')
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
APP_DIR="/app"
if [ ! -d "$APP_DIR" ]; then
    APP_DIR="$(pwd)"
    echo -e "${YELLOW}[WARN]${NC} /app not found, using $APP_DIR"
fi
cd "$APP_DIR"

./run_benchmark.sh \
    "$AGENT_TYPE" \
    "$AGENT_LLM" \
    "$DOMAIN" \
    "$TASK_RANGE" \
    "$RUN_ID" \
    "$MAX_CONCURRENCY"

# ---------------------------------------------------------------------------
# Copy results for dashboard pickup
# ---------------------------------------------------------------------------
echo ""
echo -e "${BLUE}[INFO]${NC} Copying results to /app/results..."

mkdir -p /app/results

if [ -d "output/$RUN_ID/summary" ] && [ -n "$(ls -A "output/$RUN_ID/summary" 2>/dev/null)" ]; then
    cp -r "output/$RUN_ID/summary/"* /app/results/
    echo -e "${GREEN}[SUCCESS]${NC} Summary copied to /app/results/"
else
    echo -e "${YELLOW}[WARN]${NC} No summary files to copy"
fi

RESULTS_FILE="output/$RUN_ID/results_${AGENT_TYPE}+${AGENT_LLM}.json"
if [ -f "$RESULTS_FILE" ]; then
    cp "$RESULTS_FILE" /app/results/results.json
    echo -e "${GREEN}[SUCCESS]${NC} Raw results copied to /app/results/results.json"
else
    echo -e "${YELLOW}[WARN]${NC} Results file not found: $RESULTS_FILE"
fi

# Generate dashboard-compatible output with Average score
SUMMARY_JSON="/app/results/summary.json"
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

echo -e "${GREEN}[SUCCESS]${NC} tau-agentic benchmark complete!"
echo -e "${BLUE}[INFO]${NC} Results available in /app/results/"