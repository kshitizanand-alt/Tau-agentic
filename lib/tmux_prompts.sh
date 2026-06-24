#!/bin/bash
# lib/tmux_prompts.sh
# Shared helpers for dismissing Claude Code's interactive first-run prompts
# inside a tmux session. Sourced by run_agentic.sh and exercised by
# tests/test_prompt.sh.

# Capture tmux pane content safely.
# Uses -S 0 -E - to capture ONLY the visible screen (no scrollback history).
# This prevents dismissed prompts from being re-matched in subsequent rounds.
# The `lines` parameter is kept for backward compatibility but no longer
# controls scrollback depth — we always capture the full visible screen.
capture_pane() {
  local session_name="$1"
  local lines="${2:-50}"
  tmux capture-pane -t "$session_name" -p -S 0 -E - 2>/dev/null || echo ""
}

# Dismiss Claude Code first-run interactive prompts in the given tmux session.
# Prints progress lines and returns 0 when no recognized prompts remain.
# Returns 1 if the OAuth browser flow is detected (API key rejected).
dismiss_first_run_prompts() {
  local session_name="$1"

  # State tracking: each dismissed prompt type is tracked so we don't re-match
  # it if its text lingers in the visible pane after dismissal. Combined with
  # capture_pane using -S 0 (visible screen only), this prevents the infinite
  # loop where stale scrollback text causes the same prompt to be "dismissed"
  # repeatedly.
  local pane_before prompt_round=0
  local dismissed_theme=false
  local dismissed_apikey=false
  local dismissed_login=false
  local dismissed_confirm=false

  while true; do
    prompt_round=$((prompt_round + 1))
    if [[ $prompt_round -gt 15 ]]; then
      echo "   ⚠️  Prompt dismissal exceeded 15 rounds — proceeding anyway"
      break
    fi

    sleep 3
    # capture_pane uses -S 0 (visible screen only, no scrollback)
    # Further narrow to last 20 lines to avoid terminal rendering artifacts
    pane_before=$(capture_pane "$session_name" 40 | tail -20)
    echo "   [round $prompt_round] pane tail:"
    echo "$pane_before" | tail -8 | sed 's/^/      | /'

    # API key confirmation: "Do you want to use this API key?" — select Yes (1)
    # Checked BEFORE theme picker because the theme grep is broad and can match
    # "Syntax theme: Monokai" which appears during the API-key transition.
    if [[ "$dismissed_apikey" == false ]]; then
      if echo "$pane_before" | grep -qiE "(detected a custom api key|do you want to use this api key)"; then
        echo "   🔑  Confirming API key usage (selecting Yes)..."
        tmux send-keys -t "$session_name" "1" 2>/dev/null
        sleep 2
        tmux send-keys -t "$session_name" "C-m" 2>/dev/null
        sleep 3
        dismissed_apikey=true
        continue
      fi
    fi

    # Syntax-theme guard: if the "Syntax theme: Monokai" display is visible,
    # Claude Code already auto-advanced past the theme picker. Mark dismissed
    # WITHOUT sending "2" (that would hit the API key prompt and select No).
    # We 'continue' here so the next round captures the API key prompt, which
    # appears shortly after the syntax theme display and is not yet in the
    # 20-line window when this guard fires.
    if [[ "$dismissed_theme" == false ]]; then
      if echo "$pane_before" | grep -qiE "(syntax theme|monokai|ctrl\+t to disable)"; then
        echo "   🎨  Theme already auto-selected (syntax theme display visible) — skipping input..."
        dismissed_theme=true
        continue
      fi
    fi

    # Theme picker: "Choose the text style" — select Dark mode (2).
    # Only fires if the syntax-theme guard above did not already set dismissed_theme.
    if [[ "$dismissed_theme" == false ]]; then
      if echo "$pane_before" | grep -qiE "(choose the text style|text style that looks)"; then
        echo "   🎨  Dismissing theme picker (selecting Dark mode)..."
        tmux send-keys -t "$session_name" "2" 2>/dev/null
        sleep 2
        tmux send-keys -t "$session_name" "C-m" 2>/dev/null
        sleep 3
        dismissed_theme=true
        continue
      fi
    fi

    # Login method screen means API key auth failed — abort immediately.
    # All login-method options lead to OAuth which cannot complete headlessly.
    if echo "$pane_before" | grep -qiE "(select login method|claude account with subscription|anthropic console account)"; then
      echo "   🚨  Login method prompt appeared — API key was not accepted. Aborting..."
      return 1
    fi

    # Generic startup confirmation prompt
    if [[ "$dismissed_confirm" == false ]]; then
      if echo "$pane_before" | grep -qiE "(press enter|continue|confirm|acknowledge)"; then
        echo "   ↵  Dismissing startup confirmation prompt..."
        tmux send-keys -t "$session_name" "C-m" 2>/dev/null
        sleep 3
        dismissed_confirm=true
        continue
      fi
    fi

    # OAuth browser flow detected — API key was rejected or "No" was selected.
    if echo "$pane_before" | grep -qiE "(opening browser|paste code here|sign in|oauth)"; then
      echo "   🚨  OAuth browser flow detected — API key was not accepted. Aborting early..."
      echo "   🚨  Pane content:"
      echo "$pane_before" | head -20 | sed 's/^/      | /'
      return 1
    fi

    # OAuth error / retry prompt
    if echo "$pane_before" | grep -qiE "(oauth error|invalid code|press enter to retry)"; then
      echo "   🚨  OAuth error detected — this means API key was rejected. Aborting..."
      return 1
    fi

    # No recognized prompts — done
    break
  done

  return 0
}