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

# Parse CLI arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --api-base)
            API_BASE="$2"
            shift 2
            ;;
        --api-key)
            API_KEY="$2"
            shift 2
            ;;
        --agent-llm)
            AGENT_LLM="$2"
            shift 2
            ;;
        --domain)
            DOMAIN="$2"
            shift 2
            ;;
        --max-concurrency)
            MAX_CONCURRENCY="$2"
            shift 2
            ;;
        *)
            echo -e "${RED}[ERROR]${NC} Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Validate required arguments
if [ -z "$API_BASE" ] || [ -z "$API_KEY" ] || [ -z "$AGENT_LLM" ]; then
    echo -e "${RED}[ERROR]${NC} Missing required arguments"
    echo -e "${RED}[ERROR]${NC} Usage: $0 --api-base <url> --api-key <key> --agent-llm <model> [--domain <domain>] [--max-concurrency <n>]"
    exit 1
fi

echo -e "${BLUE}[INFO]${NC} Starting tau-agentic benchmark"
echo -e "${BLUE}[INFO]${NC} API Base: $API_BASE"
echo -e "${BLUE}[INFO]${NC} Agent LLM: $AGENT_LLM"
echo -e "${BLUE}[INFO]${NC} Domain: $DOMAIN"
echo -e "${BLUE}[INFO]${NC} Max Concurrency: $MAX_CONCURRENCY"
echo ""

# Set API key env vars (same key, different names for different tools)
export GRID_AI_API_KEY="$API_KEY"
export ANTHROPIC_API_KEY="$API_KEY"
export OPENAI_API_KEY="$API_KEY"
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
cd /app

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
if [ -d "output/$RUN_ID/summary" ]; then
    cp -r "output/$RUN_ID/summary/"* /app/results/
    echo -e "${GREEN}[SUCCESS]${NC} Summary copied to /app/results/"
fi

# Copy raw results
if [ -f "output/$RUN_ID/results_${AGENT}+${AGENT_LLM}.json" ]; then
    cp "output/$RUN_ID/results_${AGENT}+${AGENT_LLM}.json" /app/results/results.json
    echo -e "${GREEN}[SUCCESS]${NC} Raw results copied to /app/results/results.json"
fi

# Generate dashboard-compatible output with Average score
# The dashboard's TauParser looks for "Average: X.XXXX"
SUMMARY_JSON="/app/results/summary.json"
if [ -f "$SUMMARY_JSON" ]; then
    PASS_AT_1=$(python3 -c "import json; print(json.load(open('$SUMMARY_JSON'))['pass_at_1'])")
    echo ""
    echo "=========================================="
    echo "Average: $PASS_AT_1"
    echo "=========================================="
    echo ""
fi

echo -e "${GREEN}[SUCCESS]${NC} tau-agentic benchmark complete!"
echo -e "${BLUE}[INFO]${NC} Results available in /app/results/"