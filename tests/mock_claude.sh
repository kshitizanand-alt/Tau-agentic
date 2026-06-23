#!/bin/bash
# mock_claude.sh - Simulates Claude Code's first-run prompt sequence.
# Used by test_prompt_dismissal.sh to verify the prompt dismissal loop.
#
# Prompt sequence:
#   1. Theme picker          - "2" + Enter selects Dark mode
#   2. API key confirmation  - "1" + Enter selects Yes, "2" + Enter selects No
#   3. (If No on API key) Login method - "2" + Enter triggers OAuth browser flow
#   4. (If Yes on API key) Ready prompt "> " - waiting for instruction
#
# If API key rejected: prints "Opening browser to sign in..." and hangs.

set -euo pipefail

# --- Helper: read a full line from stdin ---
read_line() {
  local timeout="${1:-60}"
  local line=""
  if IFS= read -t "$timeout" -r line 2>/dev/null; then
    :
  fi
  echo "$line"
}

# --- Print the welcome banner ---
print_banner() {
  echo "Welcome to Claude Code v2.1.186"
  echo ".........................................................."
  echo ""
  # Simplified ASCII art (just enough to fill some lines)
  echo "        ████████▓▓▓▒"
  echo "                      ██████▓▒     ▒▒"
  echo "             ▒▒▒▒▒▒                      █████▓▒"
  echo ""
}

# --- Stage 1: Theme picker ---
print_theme_picker() {
  echo "Let's get started."
  echo ""
  echo "Choose the text style that looks best with your terminal"
  echo "To change this later, run /theme"
  echo ""
  echo " 1. Auto (match terminal)"
  echo " 2. Dark mode"
  echo " 3. Light mode"
  echo " 4. Dark mode (colorblind-friendly)"
  echo " 5. Light mode (colorblind-friendly)"
  echo " 6. Dark mode (ANSI colors only)"
  echo " 7. Light mode (ANSI colors only)"
  echo ""
}

# --- Stage 2: After theme selected, show syntax theme briefly ---
print_syntax_theme() {
  echo "----------------------------------------------------------------"
  echo " 1 function greet() {"
  echo ' 2 -  console.log("Hello, World!");'
  echo ' 2 +  console.log("Hello, Claude!");'
  echo " 3 }"
  echo "----------------------------------------------------------------"
  echo " Syntax theme: Monokai Extended (ctrl+t to disable)"
  echo ""
}

# --- Stage 3: API key confirmation ---
print_apikey_prompt() {
  echo " Detected a custom API key in your environment"
  echo ""
  echo "ANTHROPIC_API_KEY: sk-ant-...EXAMPLE-REDACTED-KEY"
  echo ""
  echo " Do you want to use this API key?"
  echo ""
  echo " 1. Yes"
  echo " 2. No (recommended)"
  echo ""
  echo "Enter to confirm"
  echo ""
}

# --- Stage 4a: Login method (only shown if API key rejected) ---
print_login_method() {
  echo "Claude Code can be used with your Claude subscription or billed based on API"
  echo "  usage through your Console account."
  echo ""
  echo "Select login method:"
  echo ""
  echo " 1. Claude account with subscription - Pro, Max, Team, or Enterprise"
  echo " 2. Anthropic Console account - API usage billing"
  echo " 3. 3rd-party platform - Amazon Bedrock, Microsoft Foundry, or Vertex AI"
  echo ""
}

# --- Stage 4b: OAuth browser flow (hangs forever) ---
print_oauth_flow() {
  echo "Opening browser to sign in..."
  echo ""
  echo "Browser didn't open? Use the url below to sign in (c to copy)"
  echo ""
  echo "https://platform.claude.com/oauth/authorize?code=true&client_id=9d1c250a..."
  echo ""
  echo "Paste code here if prompted > "
  # Hang forever - simulates the headless failure
  while true; do
    sleep 1
  done
}

# --- Stage 5: Ready state (API key accepted) ---
print_ready() {
  echo ""
  echo "> "
}

# ===========================================================================
# Main simulation
# ===========================================================================

print_banner

# --- Stage 1: Theme picker ---
print_theme_picker
# Wait for user input (expects "2" then Enter)
input=$(read_line 60)
echo " (theme selected)"

# Brief transition
print_syntax_theme
sleep 0.5

# Clear screen effect (print blank lines to push content up)
for i in $(seq 1 5); do echo ""; done

# --- Stage 3: API key confirmation ---
print_apikey_prompt

# Wait for user input (expects "1" then Enter for Yes, or "2" then Enter for No)
input=$(read_line 60)

if [[ "$input" == "1" ]]; then
  # API key accepted - go to ready state
  echo " (API key accepted)"
  sleep 0.5
  for i in $(seq 1 5); do echo ""; done
  print_ready
  # Wait for the actual task instruction (hangs, simulating agent work)
  while true; do
    sleep 1
  done
else
  # API key rejected - show login method
  echo " (API key rejected)"
  sleep 0.5
  for i in $(seq 1 5); do echo ""; done

  print_login_method

  # Wait for user input (expects "2" then Enter for Anthropic Console)
  input=$(read_line 60)
  echo " (login method selected)"

  sleep 0.5
  for i in $(seq 1 3); do echo ""; done

  # OAuth browser flow - hangs forever
  print_oauth_flow
fi