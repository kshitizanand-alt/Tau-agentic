#!/bin/bash
set -uo pipefail
# =============================================================================
# run_agentic.sh — drives tau-bench with an EXTERNAL coding agent.
# Loops tasks, launches the chosen agent headless against the MCP bridge,
# reads the reward tau-bench computes, aggregates. Results labeled agent+model.
#
# Tmux mode follows swe-auto-eval's production pattern:
#   - load-buffer + paste-buffer for reliable prompt injection
#   - Adaptive delays based on prompt size
#   - Content-hash idle detection
#   - Graceful timeout handling
# =============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Ensure configs directory exists (needed on fresh VMs where it wasn't created)
mkdir -p "${SCRIPT_DIR}/configs"

# ---------- defaults ----------
AGENT="claude"               # coding agent under test: claude | opencode
MODEL=""                     # the agent's brain (the model under test) — required
USER_MODEL="private-large"   # customer simulator — held FIXED across runs
DOMAIN="retail"
TASK_IDS="0 1 2"
RUN_ID="run_$(date +%s)"
TIMEOUT=1800                 # seconds per task (agents can hang)
GRID_URL="${GRID_URL:-https://grid.ai.juspay.net}"
TMUX=false                   # run in tmux for live visibility

# ---------- parse flags ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)      AGENT="$2"; shift 2;;
    --model)      MODEL="$2"; shift 2;;
    --user-model) USER_MODEL="$2"; shift 2;;
    --domain)     DOMAIN="$2"; shift 2;;
    --task-ids)   TASK_IDS="$2"; shift 2;;
    --run-id)     RUN_ID="$2"; shift 2;;
    --timeout)    TIMEOUT="$2"; shift 2;;
    --tmux)       TMUX=true; shift;;
    --resume)     RESUME=true; shift;;
    *) echo "unknown flag: $1"; exit 1;;
  esac
done
[ -z "$MODEL" ] && { echo "--model is required (the agent's brain)"; exit 1; }

echo "[INFO] Agent model (brain): $MODEL"
echo "[INFO] User model (customer simulator): $USER_MODEL"

# ---------- prerequisite checks ----------
VENV_PY="${SCRIPT_DIR}/tau-bench-repo/.venv/bin/python"

if [ ! -x "$VENV_PY" ]; then
    echo "[ERROR] tau-bench venv not found at $VENV_PY"
    echo "        Run ./setup_agentic.sh first"
    exit 1
fi

if [ "$AGENT" = "claude" ] && ! command -v claude >/dev/null 2>&1; then
    echo "[ERROR] claude CLI not found in PATH"
    echo "        Run: npm install -g @anthropic-ai/claude-code"
    exit 1
fi

if [ "$AGENT" = "opencode" ] && ! command -v opencode >/dev/null 2>&1; then
    echo "[ERROR] opencode CLI not found in PATH"
    echo "        Run: npm install -g opencode"
    exit 1
fi

if $TMUX && ! command -v tmux >/dev/null 2>&1; then
    echo "[ERROR] tmux not found but --tmux was requested"
    echo "        Install tmux or run without --tmux"
    exit 1
fi

# ---------- credentials & model routing (the recipe from swe-auto-eval) ------
: "${GRID_AI_API_KEY:?Set GRID_AI_API_KEY (export it or 'source .env')}"

# Customer simulator: tau-bench -> LiteLLM -> Grid (OpenAI-compatible endpoint).
export OPENAI_API_BASE="${GRID_URL}/v1"
export OPENAI_API_KEY="$GRID_AI_API_KEY"

# Agent brain (Claude Code): redirect to Grid (Anthropic-format endpoint) AND
# override EVERY model slot, so no internal call falls back to a Claude model.
export ANTHROPIC_BASE_URL="$GRID_URL"
export ANTHROPIC_API_KEY="$GRID_AI_API_KEY"
export ANTHROPIC_MODEL="$MODEL"
export ANTHROPIC_SMALL_FAST_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_SONNET_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_OPUS_MODEL="$MODEL"
export ANTHROPIC_DEFAULT_HAIKU_MODEL="$MODEL"
export CLAUDE_CODE_SUBAGENT_MODEL="$MODEL"

OUT="${SCRIPT_DIR}/output/${RUN_ID}"; mkdir -p "$OUT"
LABEL="${AGENT}+${MODEL}"

# Generate .mcp.json with absolute paths so Claude Code can find the server
# regardless of which directory it resolves relative paths from.
write_mcp_config() {
  local task_config="$1"
  mkdir -p "${SCRIPT_DIR}/configs"
  cat > "${SCRIPT_DIR}/configs/.mcp.json" <<JSON
{
  "mcpServers": {
    "taubench": {
      "command": "${VENV_PY}",
      "args": ["${SCRIPT_DIR}/tau_mcp_server.py"],
      "env": {
        "TAU_TASK_CONFIG": "${task_config}",
        "GRID_AI_API_KEY": "${GRID_AI_API_KEY}",
        "OPENAI_API_KEY": "${GRID_AI_API_KEY}",
        "OPENAI_API_BASE": "${OPENAI_API_BASE}",
        "LITELLM_PROXY_API_KEY": "${GRID_AI_API_KEY}",
        "LITELLM_PROXY_API_BASE": "https://grid.ai.juspay.net"
      }
    }
  }
}
JSON
}

# Generate opencode.json for the opencode agent (task-specific MCP env vars)
write_opencode_config() {
  local task_config="$1"
  mkdir -p "${SCRIPT_DIR}/configs"
  cat > "${SCRIPT_DIR}/configs/opencode.json" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "mcp": {
    "taubench": {
      "type": "local",
      "command": ["${VENV_PY}", "${SCRIPT_DIR}/tau_mcp_server.py"],
      "environment": {
        "TAU_TASK_CONFIG": "${task_config}",
        "GRID_AI_API_KEY": "${GRID_AI_API_KEY}",
        "OPENAI_API_KEY": "${GRID_AI_API_KEY}",
        "OPENAI_API_BASE": "${OPENAI_API_BASE}",
        "LITELLM_PROXY_API_KEY": "${GRID_AI_API_KEY}",
        "LITELLM_PROXY_API_BASE": "https://grid.ai.juspay.net"
      },
      "enabled": true
    }
  },
  "permission": "allow"
}
JSON
}

# Pre-configure Claude Code to avoid ALL interactive first-run prompts.
# Without this, tmux sessions hang waiting for human input.
ensure_claude_settings() {
  local target_home="$1"
  mkdir -p "${target_home}/.claude"

  # Prevent Claude Code from triggering gcloud auth for the Google Drive remote MCP
  # server during headless runs. The cache is repopulated by the VS Code extension
  # when connected to claude.ai, but is irrelevant (and interactive) for CI runs.
  echo '{}' > "${target_home}/.claude/mcp-needs-auth-cache.json"

  # Minimal settings: suppress telemetry/update prompts only.
  # Do NOT pre-set "theme" — when "theme" is set, Claude Code auto-advances past
  # the theme picker without waiting for input. Our dismiss code then sends "2"
  # (thinking it's the theme picker) but that input goes to the API key prompt,
  # selecting "No" and triggering the OAuth flow. Leaving "theme" unset forces
  # Claude Code to wait for user input on the theme picker; our "2" then goes
  # to the correct active prompt.
  # Similarly, do NOT set skipOnboarding/onboardingCompleted/showedApiKeyNotice.
  cat > "${target_home}/.claude/settings.json" <<'JSON'
{
  "telemetry": false,
  "autoUpdate": false,
  "acceptedTelemetry": false,
  "mcpAutoApprove": true,
  "dangerouslySkipPermissions": true
}
JSON
}

# Configure for current user
ensure_claude_settings "${HOME}"

# Configure for claude user if we'll be running as them
if [ "$(id -u)" -eq 0 ] && id -u claude >/dev/null 2>&1; then
  ensure_claude_settings "/home/claude"
  chown -R claude:claude /home/claude/.claude 2>/dev/null || true
fi

# Disable gcloud browser prompts so that missing cloud-platform scope fails
# silently instead of hanging the benchmark run.
export CLOUDSDK_CORE_DISABLE_PROMPTS=1
export GOOGLE_APPLICATION_CREDENTIALS=""

INSTRUCTION="You are an automated customer-service evaluation agent in a LIVE CHAT with a customer. You must use ONLY the taubench MCP tools. The conversation continues until the customer says it is done.

CRITICAL RULE — NO TEXT OUTPUT:
You must NEVER write free-text responses. Any text you output is discarded and invisible. The ONLY way to communicate is by calling MCP tools. If you write text, the task fails immediately.

AVAILABLE TOOLS (use these exclusively):
1. get_task() — Call FIRST. Returns store policy, available tools, and the customer's opening message.
2. use_store_tool(tool_name, arguments) — Execute store actions (lookups, cancellations, returns, etc.).
3. reply_to_customer(message) — Send messages to the customer. Returns their next reply.

MANDATORY LOOP — YOU ARE NOT DONE UNTIL YOU SEE '[the conversation has ended]':
- Step 1: Call get_task() once.
- Step 2: Call reply_to_customer() with your response to the customer. It returns their next message.
- Step 3: If you need store data, call use_store_tool(), then IMMEDIATELY call reply_to_customer() with the result.
- Step 4: Check the return value of reply_to_customer(). If it DOES NOT end with '[the conversation has ended]', go back to Step 2 immediately. Keep looping.
- ONLY when reply_to_customer() returns text ending with '[the conversation has ended]' may you stop. Until then, you are IN THE CHAT and must keep responding.

WHAT NOT TO DO (these cause instant failure):
- Writing 'Here is what I found:' or any explanatory text — instead, call reply_to_customer() with the information.
- Asking the customer a question in plain text — instead, call reply_to_customer(message='Your question here').
- Summarizing at the end in plain text — instead, call reply_to_customer() with the summary.
- Calling use_store_tool() without immediately following up with reply_to_customer().
- STOPPING EARLY because you think you have helped enough. The customer decides when the chat ends, not you.
- Deciding the task is complete before you see '[the conversation has ended]'.

Remember: EVERY customer interaction MUST go through reply_to_customer(). No exceptions. The chat is LIVE. Keep going until '[the conversation has ended]' appears."

# ---------- signal handling --------------------------------------------------
# Clean up tmux sessions on SIGTERM/SIGINT so dashboard kills don't leave orphans
cleanup_on_exit() {
  echo ""
  echo "[SIGNAL] Caught termination signal — cleaning up tmux sessions..."
  # Kill all tmux sessions matching our run prefix
  tmux list-sessions -F '#{session_name}' 2>/dev/null | grep '^tau-' | while read -r s; do
    tmux kill-session -t "$s" 2>/dev/null || true
    echo "  Killed tmux session: $s"
  done
  echo "[SIGNAL] Cleanup complete"
  exit 130
}
trap cleanup_on_exit INT TERM

# ---------- helper functions -------------------------------------------------

# Check if a task already has a valid result (for resume mode)
task_already_done() {
  local res_file="$1"
  if [[ -f "$res_file" ]]; then
    local reward
    reward=$(${VENV_PY} -c "import json; d=json.load(open('$res_file')); print(d.get('reward','MISSING'))" 2>/dev/null || echo "ERROR")
    if [[ "$reward" != "ERROR" && "$reward" != "MISSING" ]]; then
      return 0  # true: already done
    fi
  fi
  return 1  # false: not done
}

# Cross-platform md5 hash (macOS md5 vs Linux md5sum)
hash_md5() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum | cut -d' ' -f1
  elif command -v md5 >/dev/null 2>&1; then
    md5 -q
  else
    # Fallback to Python (guaranteed since we built the venv)
    python3 -c "import sys, hashlib; print(hashlib.md5(sys.stdin.read().encode()).hexdigest())"
  fi
}

# Verify tmux session is alive
session_alive() {
  local session_name="$1"
  tmux has-session -t "$session_name" 2>/dev/null
}

# Source shared prompt dismissal helpers for headless Claude Code runs.
TMUX_PROMPTS_LIB="${SCRIPT_DIR}/lib/tmux_prompts.sh"
if [[ -f "$TMUX_PROMPTS_LIB" ]]; then
  source "$TMUX_PROMPTS_LIB"
else
  echo "[ERROR] Shared prompt library not found: $TMUX_PROMPTS_LIB"
  exit 1
fi

# Send prompt via tmux load-buffer + paste-buffer (production pattern from swe-auto-eval)
# This avoids "command too long" errors and race conditions in parallel runs.
# Retries with exponential backoff (matching claude_agent_v3.py pattern).
send_prompt_via_buffer() {
  local session_name="$1"
  local prompt="$2"
  local max_retries=3
  local attempt=0
  local backoff=1

  while [[ $attempt -lt $max_retries ]]; do
    attempt=$((attempt + 1))

    # Step 1: Load prompt into named buffer (unique per session)
    if printf '%s' "$prompt" | tmux load-buffer -b "$session_name" - 2>/dev/null; then
      :
    else
      echo "   ⚠️  load-buffer failed (attempt $attempt/$max_retries)"
      if [[ $attempt -lt $max_retries ]]; then
        sleep "$backoff"
        backoff=$(awk "BEGIN {print $backoff * 1.5}")
        continue
      fi
      echo "   ❌ load-buffer failed after $max_retries attempts"
      return 1
    fi
    sleep 0.5

    # Step 2: Paste from named buffer into session
    if tmux paste-buffer -b "$session_name" -t "$session_name" 2>/dev/null; then
      break  # Success
    else
      echo "   ⚠️  paste-buffer failed (attempt $attempt/$max_retries)"
      if [[ $attempt -lt $max_retries ]]; then
        sleep "$backoff"
        backoff=$(awk "BEGIN {print $backoff * 1.5}")
        continue
      fi
      echo "   ❌ paste-buffer failed after $max_retries attempts"
      return 1
    fi
  done

  # Step 3: Adaptive delay based on prompt size (critical fix from swe-auto-eval)
  # Claude Code needs time to process large pastes before accepting Enter.
  local prompt_lines prompt_chars
  prompt_lines=$(printf '%s' "$prompt" | grep -c '^' || echo 0)
  prompt_chars=${#prompt}
  local paste_delay
  if [[ $prompt_lines -lt 10 && $prompt_chars -lt 1000 ]]; then
    paste_delay=3
  elif [[ $prompt_lines -lt 50 && $prompt_chars -lt 5000 ]]; then
    paste_delay=5
  else
    paste_delay=7
  fi
  echo "   ⏳ Waiting ${paste_delay}s for Claude to process paste (${prompt_lines} lines)..."
  sleep "$paste_delay"

  # Step 4: Send Enter using C-m (more reliable than "Enter")
  tmux send-keys -t "$session_name" "C-m" 2>/dev/null
  echo "   ✓ Enter sent"

  # Step 5: Handle Claude Code's paste confirmation.
  # Pasting multi-line text sometimes shows "N lines pasted — press Enter to
  # submit" before the text reaches Claude's input.  Always send a second Enter
  # after a short wait so the instruction is actually submitted whether or not
  # the intermediate confirmation appeared.  An extra Enter when Claude is
  # already processing is harmless (empty prompt is silently dropped).
  sleep 3
  local pane_after
  pane_after=$(capture_pane "$session_name" 30)
  if echo "$pane_after" | grep -qiE "(pasted|paste|lines pasted|confirm)"; then
    echo "   ⚠️  Paste confirmation detected — sending Enter to submit..."
  else
    echo "   ↵  Sending follow-up Enter to ensure instruction was submitted..."
  fi
  tmux send-keys -t "$session_name" "C-m" 2>/dev/null
  sleep 2

  return 0
}

# Launch agent with optional tmux and enforced timeout
launch_agent() {   # $1 = task-config path, $2 = agent log file, $3 = task id
  export TAU_TASK_CONFIG="$1"
  local log_file="$2"
  local tid="$3"
  local session_name="tau-${tid}"

  case "$AGENT" in
    claude)
      # Claude Code refuses --dangerously-skip-permissions when running as root.
      # Run as the 'claude' user (created by setup_agentic.sh) when root.
      local claude_user=""
      if [ "$(id -u)" -eq 0 ] && id -u claude >/dev/null 2>&1; then
        claude_user="claude"
        # Ensure claude user owns the repo so it can write results
        chown -R claude:claude "$SCRIPT_DIR" 2>/dev/null || true
      fi

      local claude_cmd=(
        claude
        --mcp-config="${SCRIPT_DIR}/configs/.mcp.json"
        --model="$MODEL"
        --dangerously-skip-permissions
      )

      if $TMUX; then
        # Kill any existing session
        tmux kill-session -t "$session_name" 2>/dev/null || true
        sleep 0.5

        # Build the command: if root, run as claude user with correct HOME
        # sudo -E preserves root's HOME=/root which breaks Claude Code config lookup.
        # We explicitly set HOME and pass only the env vars Claude needs.
        local tmux_cmd
        if [ -n "$claude_user" ]; then
          # Export all needed env vars explicitly for the claude user
          local env_export=""
          env_export+="export HOME=/home/claude;"
          # Prepend common npm global bin locations so claude user can find the binary.
          # npm global installs as root put symlinks in /usr/local/bin or /usr/bin.
          env_export+="export PATH=\"/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin:$HOME/.npm-global/bin:$PATH\";"
          env_export+="export GRID_AI_API_KEY=\"$GRID_AI_API_KEY\";"
          env_export+="export OPENAI_API_BASE=\"$OPENAI_API_BASE\";"
          env_export+="export OPENAI_API_KEY=\"$OPENAI_API_KEY\";"
          env_export+="export ANTHROPIC_BASE_URL=\"$ANTHROPIC_BASE_URL\";"
          env_export+="export ANTHROPIC_API_KEY=\"$ANTHROPIC_API_KEY\";"
          env_export+="export ANTHROPIC_MODEL=\"$ANTHROPIC_MODEL\";"
          env_export+="export ANTHROPIC_SMALL_FAST_MODEL=\"$ANTHROPIC_SMALL_FAST_MODEL\";"
          env_export+="export ANTHROPIC_DEFAULT_SONNET_MODEL=\"$ANTHROPIC_DEFAULT_SONNET_MODEL\";"
          env_export+="export ANTHROPIC_DEFAULT_OPUS_MODEL=\"$ANTHROPIC_DEFAULT_OPUS_MODEL\";"
          env_export+="export ANTHROPIC_DEFAULT_HAIKU_MODEL=\"$ANTHROPIC_DEFAULT_HAIKU_MODEL\";"
          env_export+="export CLAUDE_CODE_SUBAGENT_MODEL=\"$CLAUDE_CODE_SUBAGENT_MODEL\";"
          env_export+="export CLOUDSDK_CORE_DISABLE_PROMPTS=1;"
          env_export+="export GOOGLE_APPLICATION_CREDENTIALS=\"\";"
          env_export+="export TAU_TASK_CONFIG=\"$TAU_TASK_CONFIG\";"
          env_export+="cd \"$SCRIPT_DIR\";"
          tmux_cmd="sudo -u $claude_user bash -lc '$env_export $(printf '%q ' "${claude_cmd[@]}")'"
        else
          tmux_cmd="cd \"$SCRIPT_DIR\" && $(printf '%q ' "${claude_cmd[@]}")"
        fi

        # Create tmux session with Claude TUI (user can attach and watch live)
        tmux new-session -d -s "$session_name" \
          bash -c "$tmux_cmd" \
          > /dev/null 2>&1

        # Set large history limit for scrollback (50,000 lines)
        tmux set-option -t "$session_name" history-limit 50000 > /dev/null 2>&1

        # Pipe all pane output to log file, stripping ANSI color codes for readability
        # perl is more portable than sed for this (works on both macOS BSD and GNU)
        tmux pipe-pane -t "$session_name" "perl -pe 's/\e\[[0-9;]*m//g' >> '${log_file}'"

        sleep 4  # Let Claude initialize

        # Verify session is alive
        if ! session_alive "$session_name"; then
          echo "❌ [task $tid] tmux session died immediately"
          return 1
        fi

        # Wait for Claude Code to finish initializing before interacting.
        # Use scrollback capture here (not the visible-screen-only capture_pane)
        # so the "Welcome" banner is detected even when the terminal is too tall
        # for the text to be in the visible window.
        echo "   ⏳ Waiting for Claude Code to initialize..."
        local init_wait=0
        while [[ $init_wait -lt 10 ]]; do
          sleep 1
          init_wait=$((init_wait + 1))
          local pane_init
          pane_init=$(tmux capture-pane -t "$session_name" -p -S -30 2>/dev/null || echo "")
          if echo "$pane_init" | grep -qE '(>\s*$|\$\s*|λ\s*|claude\s*\>|Ready|Welcome)'; then
            echo "   ✓ Claude Code appears ready (${init_wait}s)"
            break
          fi
        done

        # Dismiss first-run interactive prompts using shared helpers.
        if ! dismiss_first_run_prompts "$session_name"; then
          echo "❌ [task $tid] Failed to dismiss first-run prompts / API key rejected"
          return 1
        fi

        # Send instruction using production buffer pattern
        echo "📤 [task $tid] Sending instruction to tmux session..."
        if ! send_prompt_via_buffer "$session_name" "$INSTRUCTION"; then
          echo "❌ [task $tid] Failed to send prompt"
          tmux kill-session -t "$session_name" 2>/dev/null || true
          return 1
        fi

        echo "🖥️  Task $tid running in tmux: tmux attach -t $session_name"
        echo "    (Ctrl+B then D to detach without stopping)"

        # Monitor with timeout and idle detection
        local start_time elapsed last_output_hash current_hash idle_start
        start_time=$(date +%s)
        last_output_hash=""
        idle_start=""

        while true; do
          elapsed=$(($(date +%s) - start_time))

          # Hard timeout
          if [[ $elapsed -ge $TIMEOUT ]]; then
            echo "🔥 [task $tid] TIMEOUT (${TIMEOUT}s) — killing tmux session"
            tmux kill-session -t "$session_name" 2>/dev/null || true
            break
          fi

          # Check if session still alive
          if ! session_alive "$session_name"; then
            echo "✅ [task $tid] Session ended naturally at ${elapsed}s"
            break
          fi

          # Idle detection only — pipe-pane owns log writing
          local pane_content
          pane_content=$(capture_pane "$session_name" 50)
          if [[ -n "$pane_content" ]]; then
            current_hash=$(echo "$pane_content" | hash_md5)
            if [[ "$current_hash" == "$last_output_hash" ]]; then
              if [[ -z "$idle_start" ]]; then
                idle_start=$elapsed
              else
                local idle_duration=$((elapsed - idle_start))
                if [[ $idle_duration -ge 300 ]]; then
                  echo "⏰ [task $tid] IDLE TIMEOUT (5min no activity) — ending session"
                  tmux kill-session -t "$session_name" 2>/dev/null || true
                  break
                elif [[ $((idle_duration % 30)) -eq 0 && $idle_duration -gt 0 ]]; then
                  echo "⏳ [task $tid] Still idle: ${idle_duration}s"
                fi
              fi
            else
              if [[ -n "$idle_start" ]]; then
                echo "🔄 [task $tid] Activity detected, idle timer reset"
                idle_start=""
              fi
              last_output_hash="$current_hash"
            fi
          fi

          # Progress heartbeat every 30s
          if [[ $((elapsed % 30)) -eq 0 && $elapsed -gt 0 ]]; then
            echo "⏱️  [task $tid] ${elapsed}s elapsed..."
          fi

          sleep 5
        done

        # Only kill session if it's still alive (allows post-mortem inspection)
        if session_alive "$session_name"; then
          tmux kill-session -t "$session_name" 2>/dev/null || true
        fi

      else
        timeout "$TIMEOUT" "${claude_cmd[@]}" --print "$INSTRUCTION" > "$log_file" 2>&1
        local exit_code=$?
        if [[ $exit_code -eq 124 ]]; then
          echo "🔥 [task $tid] TIMEOUT (${TIMEOUT}s) — agent killed"
        fi
      fi
      ;;

    opencode)
      if $TMUX; then
        echo "⚠️  tmux mode not yet supported for opencode, running headless"
      fi
      # Pass dir, instruction, and model as positional args to avoid quoting
      # issues with multi-line instructions containing single quotes / parens.
      timeout "$TIMEOUT" bash -c \
        'cd "$1" && opencode run "$2" --model "$3"' \
        -- "${SCRIPT_DIR}/configs" "$INSTRUCTION" "grid/$MODEL" \
        > "$log_file" 2>&1
      local exit_code=$?
      if [[ $exit_code -eq 124 ]]; then
        echo "🔥 [task $tid] TIMEOUT (${TIMEOUT}s) — agent killed"
      fi
      ;;

    *) echo "unknown agent: $AGENT"; exit 1;;
  esac
}

# ---------- task loop (with resume support) ----------------------------------
TOTAL_TASKS=$(echo "$TASK_IDS" | wc -w)
COMPLETED=0
SKIPPED=0
REWARDS=()

echo "=========================================="
echo "  Tau-Bench Agentic Runner"
echo "  Agent: $AGENT"
echo "  Model: $MODEL"
echo "  User Model: $USER_MODEL"
echo "  Domain: $DOMAIN"
echo "  Tasks: $TASK_IDS"
echo "  Timeout: ${TIMEOUT}s"
echo "  Tmux: $TMUX"
echo "  Resume: ${RESUME:-false}"
echo "  Output: $OUT"
echo "=========================================="

for TID in $TASK_IDS; do
  COMPLETED=$((COMPLETED + 1))
  CFG="${SCRIPT_DIR}/configs/task_${TID}.json"
  RES="${OUT}/${LABEL}__task_${TID}.json"
  LOG="${OUT}/${LABEL}__task_${TID}.agent.log"

  echo ""
  echo "=== [$COMPLETED/$TOTAL_TASKS] Task $TID ($LABEL) ==="

  # Resume: skip if already done
  if [[ "${RESUME:-}" == "true" ]] && task_already_done "$RES"; then
    echo "⏭️  Task $TID already completed — skipping (resume mode)"
    SKIPPED=$((SKIPPED + 1))
    R=$(${VENV_PY} -c "import json;print(json.load(open('$RES'))['reward'])" 2>/dev/null || echo 0)
    echo "task $TID reward: $R (cached)"
    REWARDS+=("$R")
    continue
  fi

  # Write task config
  cat > "$CFG" <<JSON
{ "task_index": $TID, "domain": "$DOMAIN", "user_model": "$USER_MODEL",
  "task_split": "test", "result_file": "$RES" }
JSON

  # Write MCP configs with absolute paths for this task
  write_mcp_config "$CFG"
  write_opencode_config "$CFG"

  # Run agent (with error isolation)
  launch_agent "$CFG" "$LOG" "$TID" || {
    echo "[warn] agent exited non-zero on task $TID"
  }

  # Read reward (with error isolation)
  R=0
  if [[ -f "$RES" ]]; then
    R=$(${VENV_PY} -c "import json;print(json.load(open('$RES'))['reward'])" 2>/dev/null || echo 0)
  else
    echo "[warn] no result file for task $TID — reward=0"
  fi

  echo "task $TID reward: $R"
  REWARDS+=("$R")
done

# ---------- aggregate --------------------------------------------------------
echo ""
echo "=========================================="
echo "  Results Summary"
echo "=========================================="

${VENV_PY} - "$OUT" "$LABEL" "${REWARDS[@]}" <<'PY'
import sys, json
out, label = sys.argv[1], sys.argv[2]
rewards = [float(x) for x in sys.argv[3:]]
avg = sum(rewards)/len(rewards) if rewards else 0.0
print(f"\n{label}: average reward (pass@1) = {avg:.4f} over {len(rewards)} tasks")
json.dump({"label": label, "average_reward": avg, "rewards": rewards},
          open(f"{out}/results_{label}.json", "w"), indent=2)
PY

echo ""
echo "Completed: $COMPLETED | Skipped: $SKIPPED"
echo "Results: $OUT/results_${LABEL}.json"