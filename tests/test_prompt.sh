#!/bin/bash
# test_prompt.sh - Regression test for Claude Code first-run prompt dismissal.
#
# Sources the real lib/tmux_prompts.sh helpers used by run_agentic.sh so the
# test exercises production code, not a stale inline copy.
#
# Usage:
#   ./tests/test_prompt.sh           # Test fixed production logic
#   ./tests/test_prompt.sh --buggy   # Test old buggy logic for comparison
#
# Exit codes:
#   0 = PASS (API key accepted, reached ready state)
#   1 = FAIL (OAuth flow triggered or timeout)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOCK_CLAUDE="$SCRIPT_DIR/mock_claude.sh"
SESSION_NAME="test-claude-$$"
MODE="${1:-fixed}"

chmod +x "$MOCK_CLAUDE"

TMUX_BIN="$(which tmux 2>/dev/null || echo '/opt/homebrew/bin/tmux')"

cleanup() {
  "$TMUX_BIN" kill-session -t "$SESSION_NAME" 2>/dev/null || true
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Buggy historical implementation (for regression comparison)
# ---------------------------------------------------------------------------

capture_pane_buggy() {
  local session="$1"
  local lines="${2:-50}"
  "$TMUX_BIN" capture-pane -t "$session" -p -S "-${lines}" 2>/dev/null || echo ""
}

# Original prompt order: theme BEFORE api-key, no state tracking. This is what
# caused the live dashboard failure: stale theme text in scrollback matched
# before the API-key prompt, sending "2" (= No) and triggering OAuth.
run_buggy_dismissal() {
  local session="$1"
  local pane_before prompt_round=0

  while true; do
    prompt_round=$((prompt_round + 1))
    if [[ $prompt_round -gt 15 ]]; then
      echo "   [BUGGY] Exceeded 15 rounds"
      break
    fi

    sleep 3
    pane_before=$(capture_pane_buggy "$session" 40)

    # Theme picker (checked first in the old code)
    if echo "$pane_before" | grep -qiE "(choose the text style|text style that looks)"; then
      echo "   [BUGGY] Dismissing theme picker (selecting Dark mode)..."
      "$TMUX_BIN" send-keys -t "$session" "2" 2>/dev/null
      sleep 2
      "$TMUX_BIN" send-keys -t "$session" "C-m" 2>/dev/null
      sleep 3
      continue
    fi

    # API key confirmation
    if echo "$pane_before" | grep -qiE "(detected a custom api key|do you want to use this api key)"; then
      echo "   [BUGGY] Confirming API key usage (selecting Yes)..."
      "$TMUX_BIN" send-keys -t "$session" "1" 2>/dev/null
      sleep 2
      "$TMUX_BIN" send-keys -t "$session" "C-m" 2>/dev/null
      sleep 3
      continue
    fi

    # Login method
    if echo "$pane_before" | grep -qiE "(select login method|claude account with subscription|anthropic console account)"; then
      echo "   [BUGGY] Dismissing login method selection..."
      "$TMUX_BIN" send-keys -t "$session" "2" 2>/dev/null
      sleep 2
      "$TMUX_BIN" send-keys -t "$session" "C-m" 2>/dev/null
      sleep 3
      continue
    fi

    # OAuth browser flow detected
    if echo "$pane_before" | grep -qiE "(opening browser|paste code here|sign in|oauth)"; then
      return 2
    fi

    break
  done

  return 0
}

# ---------------------------------------------------------------------------
# Production implementation used by run_agentic.sh
# ---------------------------------------------------------------------------

if [[ "$MODE" != "--buggy" ]]; then
  TMUX_PROMPTS_LIB="$SCRIPT_DIR/../lib/tmux_prompts.sh"
  if [[ ! -f "$TMUX_PROMPTS_LIB" ]]; then
    echo "ERROR: cannot find shared prompt library at $TMUX_PROMPTS_LIB"
    exit 1
  fi
  source "$TMUX_PROMPTS_LIB"
fi

run_fixed_dismissal() {
  dismiss_first_run_prompts "$1"
}

# ---------------------------------------------------------------------------
# Main test
# ---------------------------------------------------------------------------

echo "=========================================="
echo "  Prompt Dismissal Test"
if [[ "$MODE" == "--buggy" ]]; then
  echo "  Mode: BUGGY (scrollback + theme-before-api-key, expect FAIL)"
else
  echo "  Mode: FIXED (production lib/tmux_prompts.sh, expect PASS)"
fi
echo "=========================================="
echo ""

"$TMUX_BIN" new-session -d -s "$SESSION_NAME" "bash $MOCK_CLAUDE" 2>/dev/null
sleep 2

if [[ "$MODE" == "--buggy" ]]; then
  run_buggy_dismissal "$SESSION_NAME"
  result=$?
else
  run_fixed_dismissal "$SESSION_NAME"
  result=$?
fi

sleep 2
final_pane=$("$TMUX_BIN" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null || echo "")

echo ""
echo "=========================================="
echo "  Results"
echo "=========================================="

if [[ $result -ne 0 ]]; then
  echo "  FAIL: Prompt dismissal failed (OAuth flow triggered or error)"
  echo "  The API key prompt may not have been handled correctly"
  echo ""
  echo "  Final pane content (last 30 lines):"
  echo "$final_pane" | tail -30 | sed 's/^/    | /'
  exit 1
fi

if echo "$final_pane" | grep -qE '>\s*$'; then
  echo "  PASS: Reached ready state (API key was accepted)"
  echo ""
  echo "  Final pane content (last 20 lines):"
  echo "$final_pane" | tail -20 | sed 's/^/    | /'
  exit 0
else
  echo "  FAIL: Did not reach ready state"
  echo ""
  echo "  Final pane content (last 30 lines):"
  echo "$final_pane" | tail -30 | sed 's/^/    | /'
  exit 1
fi