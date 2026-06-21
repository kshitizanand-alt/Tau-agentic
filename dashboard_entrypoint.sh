#!/bin/bash
set -e

# =============================================================================
# dashboard_entrypoint.sh — Entrypoint for xyne-eval-ops-dashboard
#
# The dashboard spawns a Docker container and passes CLI arguments:
#   --api-base <url> --api-key <key> --agent-llm <model> [--domain <domain>] [--max-concurrency <n>]
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

# Parse CLI arguments (supports both --key value and --key=value)
while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-base=*)
            API_BASE="${1#*=}"
            shift
            ;;
        --api-base)
            API_BASE="${2:-}"
            shift 2
            ;;
        --api-key=*)
            API_KEY="${1#*=}"
            shift
            ;;
        --api-key)
            API_KEY="${2:-}"
            shift 2
            ;;
        --agent-llm=*)
            AGENT_LLM="${1#*=}"
            shift
            ;;
        --agent-llm)
            AGENT_LLM="${2:-}"
            shift 2
            ;;
        --domain=*)
            DOMAIN="${1#*=}"
            shift
            ;;
        --domain)
            DOMAIN="${2:-}"
            shift 2
            ;;
        --max-concurrency=*)
            MAX_CONCURRENCY="${1#*=}"
            shift
            ;;
        --max-concurrency)
            MAX_CONCURRENCY="${2:-}"
            shift 2
            ;;
        *)
            echo -e "${YELLOW}[WARN]${NC} Unknown argument: $1 (skipping)"
            shift
            ;;
    esac
done

# Debug: show what we received
echo -e "${BLUE}[DEBUG]${NC} Parsed args: API_BASE='$API_BASE' API_KEY='${API_KEY:0:4}***' AGENT_LLM='$AGENT_LLM' DOMAIN='$DOMAIN' MAX_CONCURRENCY='$MAX_CONCURRENCY'"

# Fall back to environment variables if dashboard injects key that way
if [ -z "$API_KEY" ]; then
    API_KEY="${DASHBOARD_API_KEY:-${GRID_AI_API_KEY:-${ANTHROPIC_API_KEY:-${OPENAI_API_KEY:-}}}}"
    if [ -n "$API_KEY" ]; then
        echo -e "${BLUE}[INFO]${NC} Using API key from environment variable"
    fi
fi

# Validate required arguments
if [ -z "$API_BASE" ] || [ -z "$AGENT_LLM" ]; then
    echo -e "${RED}[ERROR]${NC} Missing required arguments"
    echo -e "${RED}[ERROR]${NC} Usage: $0 --api-base <url> --api-key <key> --agent-llm <model> [--domain <domain>] [--max-concurrency <n>]"
    exit 1
fi

# Warn if no API key provided (will fall back to env vars)
if [ -z "$API_KEY" ]; then
    echo -e "${YELLOW}[WARN]${NC} No --api-key provided; relying on environment variables"
fi

echo -e "${BLUE}[INFO]${NC} Starting tau-agentic benchmark"
echo -e "${BLUE}[INFO]${NC} API Base: $API_BASE"
echo -e "${BLUE}[INFO]${NC} Agent LLM: $AGENT_LLM"
echo -e "${BLUE}[INFO]${NC} Domain: $DOMAIN"
echo -e "${BLUE}[INFO]${NC} Max Concurrency: $MAX_CONCURRENCY"
echo ""

# Set API key env vars (same key, different names for different tools)
# Only export if provided — preserve existing env vars when dashboard uses "default key"
if [ -n "$API_KEY" ]; then
    export GRID_AI_API_KEY="$API_KEY"
    export ANTHROPIC_API_KEY="$API_KEY"
    export OPENAI_API_KEY="$API_KEY"
fi
export OPENAI_API_BASE="$API_BASE"

echo -e "${BLUE}[INFO]${NC} API keys configured"

# Determine agent type from model name heuristic
# If model contains "opencode", use opencode agent; otherwise claude
if [[ "$AGENT_LLM" == *"opencode"* ]] || [[ "$AGENT_LLM" == *"open-code"* ]]; then
    AGENT="opencode"
else
    AGENT="claude"
fi

echo -e "${BLUE}[INFO]${NC} Selected agent: $AGENT"

# Generate a unique run ID
RUN_ID="dashboard_$(date +%s)"

echo -e "${BLUE}[INFO]${NC} Run ID: $RUN_ID"
echo ""

# Run the benchmark
APP_DIR="/app"
if [ ! -d "$APP_DIR" ]; then
    APP_DIR="$(pwd)"
    echo -e "${YELLOW}[WARN]${NC} /app not found, using $APP_DIR"
fi
cd "$APP_DIR"

./run_benchmark.sh \
    "$AGENT" \
    "$AGENT_LLM" \
    "$DOMAIN" \
    "$TASK_RANGE" \
    "$RUN_ID" \
    "$MAX_CONCURRENCY"

# Copy results to /app/results for dashboard pickup
echo ""
echo -e "${BLUE}[INFO]${NC} Copying results to /app/results..."

mkdir -p /app/results

# Copy summary files
if [ -d "output/$RUN_ID/summary" ] && [ -n "$(ls -A "output/$RUN_ID/summary" 2>/dev/null)" ]; then
    cp -r "output/$RUN_ID/summary/"* /app/results/
    echo -e "${GREEN}[SUCCESS]${NC} Summary copied to /app/results/"
else
    echo -e "${YELLOW}[WARN]${NC} No summary files to copy"
fi

# Copy raw results
RESULTS_FILE="output/$RUN_ID/results_${AGENT}+${AGENT_LLM}.json"
if [ -f "$RESULTS_FILE" ]; then
    cp "$RESULTS_FILE" /app/results/results.json
    echo -e "${GREEN}[SUCCESS]${NC} Raw results copied to /app/results/results.json"
else
    echo -e "${YELLOW}[WARN]${NC} Results file not found: $RESULTS_FILE"
fi

# Generate dashboard-compatible output with Average score
# The dashboard's TauParser looks for "Average: X.XXXX"
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