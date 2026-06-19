#!/bin/bash
set -e

# =============================================================================
# run.sh — Dashboard-compatible entrypoint for tau-agentic
#
# Called by the eval-runner with:
#   $1 = Grid AI API key
#   $2 = Evaluation run ID
#   $@ = Dashboard input params (--key value)
# =============================================================================

API_KEY="$1"
EVAL_RUN_ID="$2"
shift 2

echo "[run.sh] Starting tau-agentic benchmark"
echo "[run.sh] Eval Run ID: $EVAL_RUN_ID"

# -----------------------------------------------------------------------------
# Parse dashboard input params
# -----------------------------------------------------------------------------
MODEL=""
ENVIRONMENT="airline"
AGENT="claude"
MAX_CONCURRENCY=1
TASK_RANGE="0-99"
NUMBER_OF_TRIALS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --model)
            MODEL="$2"
            shift 2
            ;;
        --environment)
            ENVIRONMENT="$2"
            shift 2
            ;;
        --agent)
            AGENT="$2"
            shift 2
            ;;
        --max-concurrency)
            MAX_CONCURRENCY="$2"
            shift 2
            ;;
        --task-range)
            TASK_RANGE="$2"
            shift 2
            ;;
        --number-of-trials)
            NUMBER_OF_TRIALS="$2"
            shift 2
            ;;
        *)
            echo "[run.sh] WARN: Unknown argument '$1'"
            shift
            ;;
    esac
done

# Validate
if [ -z "$MODEL" ]; then
    echo "[run.sh] ERROR: --model is required"
    exit 1
fi

echo "[run.sh] Model: $MODEL"
echo "[run.sh] Environment: $ENVIRONMENT"
echo "[run.sh] Agent: $AGENT"
echo "[run.sh] Task Range: $TASK_RANGE"
echo "[run.sh] Max Concurrency: $MAX_CONCURRENCY"
echo "[run.sh] Number of Trials: $NUMBER_OF_TRIALS"

if [ "$MAX_CONCURRENCY" -gt 1 ]; then
    echo "[run.sh] WARN: Parallel execution not yet supported, running sequentially"
fi

# -----------------------------------------------------------------------------
# Convert task range to space-separated IDs
# -----------------------------------------------------------------------------
convert_range_to_ids() {
    local range="$1"
    if [[ "$range" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        local start="${BASH_REMATCH[1]}"
        local end="${BASH_REMATCH[2]}"
        local ids=()
        for ((i=start; i<=end; i++)); do
            ids+=("$i")
        done
        echo "${ids[*]}"
    else
        echo "$range"
    fi
}

TASK_IDS=$(convert_range_to_ids "$TASK_RANGE")
echo "[run.sh] Task IDs: $TASK_IDS"

# -----------------------------------------------------------------------------
# Configure API keys
# -----------------------------------------------------------------------------
export GRID_AI_API_KEY="$API_KEY"
export ANTHROPIC_API_KEY="$API_KEY"
export OPENAI_API_KEY="$API_KEY"

# -----------------------------------------------------------------------------
# Run trials
# -----------------------------------------------------------------------------
TOTAL_PASS_AT_1=0
TRIAL_COUNT=0

for ((trial=1; trial<=NUMBER_OF_TRIALS; trial++)); do
    echo ""
    echo "=========================================="
    echo "[run.sh] Trial $trial of $NUMBER_OF_TRIALS"
    echo "=========================================="
    
    TRIAL_RUN_ID="${EVAL_RUN_ID}_trial_${trial}"
    
    # Run benchmark (no --tmux for headless Docker)
    ./run_agentic.sh \
        --agent "$AGENT" \
        --model "$MODEL" \
        --domain "$ENVIRONMENT" \
        --task-ids "$TASK_IDS" \
        --run-id "$TRIAL_RUN_ID"
    
    # Generate summary for this trial
    mkdir -p "output/${TRIAL_RUN_ID}"
    python3 generate_summary.py \
        --run-id "$TRIAL_RUN_ID" \
        --agent "$AGENT" \
        --model "$MODEL" \
        --output "output/${TRIAL_RUN_ID}/summary.json" \
        2>/dev/null || {
            echo "[run.sh] WARN: generate_summary.py failed for trial $trial"
            continue
        }
    
    # Extract pass@1
    if [ -f "output/${TRIAL_RUN_ID}/summary.json" ]; then
        PASS_AT_1=$(python3 -c "import json; d=json.load(open('output/${TRIAL_RUN_ID}/summary.json')); print(d.get('pass_at_1', 0))")
        TOTAL_PASS_AT_1=$(python3 -c "print(${TOTAL_PASS_AT_1} + ${PASS_AT_1})")
        TRIAL_COUNT=$((TRIAL_COUNT + 1))
        echo "[run.sh] Trial $trial pass@1: $PASS_AT_1"
    else
        echo "[run.sh] WARN: No summary found for trial $trial"
    fi
done

# -----------------------------------------------------------------------------
# Compute average and write results
# -----------------------------------------------------------------------------
if [ "$TRIAL_COUNT" -eq 0 ]; then
    echo "[run.sh] ERROR: All trials failed"
    exit 1
fi

AVG_PASS_AT_1=$(python3 -c "print(${TOTAL_PASS_AT_1} / ${TRIAL_COUNT})")
echo ""
echo "[run.sh] =========================================="
echo "[run.sh] Average pass@1: ${AVG_PASS_AT_1}"
echo "[run.sh] Trials: ${TRIAL_COUNT}"
echo "[run.sh] =========================================="

# Write results in runner-expected format
mkdir -p output
cat > "output/${EVAL_RUN_ID}_results.json" <<EOF
{
  "metrics": {
    "main": {
      "name": "pass@1",
      "value": ${AVG_PASS_AT_1}
    },
    "secondary": {
      "trials": ${TRIAL_COUNT},
      "task_range": "${TASK_RANGE}",
      "domain": "${ENVIRONMENT}",
      "agent": "${AGENT}",
      "model": "${MODEL}"
    },
    "additional": {}
  }
}
EOF

echo "[run.sh] Results written to output/${EVAL_RUN_ID}_results.json"
echo "[run.sh] Done!"