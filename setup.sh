#!/bin/bash
set -e

echo "[setup.sh] Verifying tau-agentic environment..."

# Determine Python pip command
PIP_CMD="python3 -m pip"

# Check key tools exist - if not, run full setup
need_setup=false

command -v python3 >/dev/null || { echo "[setup.sh] python3 missing"; need_setup=true; }
command -v node >/dev/null || { echo "[setup.sh] node missing"; need_setup=true; }
command -v npm >/dev/null || { echo "[setup.sh] npm missing"; need_setup=true; }
command -v git >/dev/null || { echo "[setup.sh] git missing"; need_setup=true; }
command -v tmux >/dev/null || { echo "[setup.sh] tmux missing"; need_setup=true; }

# Check if tau-bench is importable
if command -v python3 >/dev/null; then
    if ! python3 -c "from tau_bench.envs import get_env" 2>/dev/null; then
        echo "[setup.sh] tau-bench not importable"
        need_setup=true
    fi
else
    need_setup=true
fi

# Check claude-code CLI (warning only — not a hard requirement for benchmark)
if ! command -v claude >/dev/null 2>&1; then
    echo "[setup.sh] WARNING: claude CLI not found (agent may not work)"
fi

if [ "$need_setup" = true ]; then
    echo "[setup.sh] Missing dependencies detected, running setup_agentic.sh..."
    if [ -f "./setup_agentic.sh" ]; then
        bash ./setup_agentic.sh
    else
        echo "[ERROR] setup_agentic.sh not found. Cannot auto-install dependencies."
        exit 1
    fi
fi

# Ensure Python deps are up to date
$PIP_CMD install -q -r requirements.txt 2>/dev/null || true

echo "[setup.sh] Environment OK"
