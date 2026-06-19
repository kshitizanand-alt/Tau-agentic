#!/bin/bash
set -e

echo "[setup.sh] Verifying tau-agentic environment..."

# Check key tools exist
command -v python3 >/dev/null || { echo "[ERROR] python3 missing"; exit 1; }
command -v node >/dev/null || { echo "[ERROR] node missing"; exit 1; }
command -v npm >/dev/null || { echo "[ERROR] npm missing"; exit 1; }
command -v git >/dev/null || { echo "[ERROR] git missing"; exit 1; }
command -v tmux >/dev/null || { echo "[ERROR] tmux missing"; exit 1; }

# Ensure tau-bench is importable
python3 -c "from tau_bench.envs import get_env" 2>/dev/null || {
    echo "[setup.sh] tau-bench not installed, installing..."
    pip install -e ./tau-bench-repo/ >/dev/null 2>&1
}

# Ensure Python deps
pip install -q -r requirements.txt 2>/dev/null || true

# Check claude-code CLI
command -v claude >/dev/null || { echo "[ERROR] claude CLI missing"; exit 1; }

echo "[setup.sh] Environment OK"