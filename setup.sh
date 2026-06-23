#!/bin/bash
set -e

echo "[setup.sh] Verifying tau-agentic environment..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Prefer the tau-bench venv if it exists; otherwise fall back to system python.
if [ -x "${SCRIPT_DIR}/tau-bench-repo/.venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/tau-bench-repo/.venv/bin/python"
elif [ -x "${SCRIPT_DIR}/venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/venv/bin/python"
else
    PYTHON_CMD="python3"
fi
PIP_CMD="$PYTHON_CMD -m pip"

# Check key tools exist - if not, run full setup
need_setup=false

command -v python3 >/dev/null || { echo "[setup.sh] python3 missing"; need_setup=true; }
command -v node >/dev/null || { echo "[setup.sh] node missing"; need_setup=true; }
command -v npm >/dev/null || { echo "[setup.sh] npm missing"; need_setup=true; }
command -v git >/dev/null || { echo "[setup.sh] git missing"; need_setup=true; }
command -v tmux >/dev/null || { echo "[setup.sh] tmux missing"; need_setup=true; }

# Check if tau-bench is importable (using the preferred python)
if ! "$PYTHON_CMD" -c "from tau_bench.envs import get_env" 2>/dev/null; then
    echo "[setup.sh] tau-bench not importable with $PYTHON_CMD"
    need_setup=true
fi

# Check claude-code CLI (warning only — not a hard requirement for setup success)
if ! command -v claude >/dev/null 2>&1; then
    echo "[setup.sh] WARNING: claude CLI not found (will be installed by setup_agentic.sh)"
fi

if [ "$need_setup" = true ]; then
    echo "[setup.sh] Missing dependencies detected, running setup_agentic.sh..."
    if [ -f "./setup_agentic.sh" ]; then
        # Run setup_agentic.sh with error isolation so a non-fatal warning does
        # not make the whole setup fail on fresh VMs.
        if ! bash ./setup_agentic.sh; then
            echo "[setup.sh] WARNING: setup_agentic.sh returned non-zero, but continuing verification..."
        fi
    else
        echo "[ERROR] setup_agentic.sh not found. Cannot auto-install dependencies."
        exit 1
    fi
fi

# Recompute preferred python after setup may have created the venv
if [ -x "${SCRIPT_DIR}/tau-bench-repo/.venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/tau-bench-repo/.venv/bin/python"
elif [ -x "${SCRIPT_DIR}/venv/bin/python" ]; then
    PYTHON_CMD="${SCRIPT_DIR}/venv/bin/python"
fi
PIP_CMD="$PYTHON_CMD -m pip"

# Ensure Python deps are up to date (best-effort; do not fail setup if pip is offline)
$PIP_CMD install -q -r requirements.txt 2>/dev/null || true

# Final verification
if ! "$PYTHON_CMD" -c "from tau_bench.envs import get_env" 2>/dev/null; then
    echo "[setup.sh] ERROR: tau-bench still not importable after setup"
    exit 1
fi

echo "[setup.sh] Environment OK"
