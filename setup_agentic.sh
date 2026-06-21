#!/bin/bash
set -euo pipefail
# =============================================================================
# setup_agentic.sh  — cross-platform setup (macOS + Linux/Debian).
# Clones tau-bench, builds its venv, installs tau-bench + mcp + coding agents.
# Idempotent: safe to re-run.
# =============================================================================
error_exit() { echo "[ERROR] $1" >&2; exit 1; }
trap 'error_exit "Command failed at line $LINENO"' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

REPO_URL="https://github.com/sierra-research/tau-bench.git"
REPO_DIR="${SCRIPT_DIR}/tau-bench-repo"
OS="$(uname -s)"

# =============================================================================
# 1. SYSTEM DEPENDENCIES
# =============================================================================
echo "[1/6] Installing system dependencies..."

if [ "$OS" = "Darwin" ]; then
    # macOS — use Homebrew
    command -v brew >/dev/null \
        || error_exit "Homebrew not found. Install it first: https://brew.sh, then re-run."
    # Xcode Command Line Tools (needed for compiling Python packages)
    xcode-select -p >/dev/null 2>&1 || {
        echo "Installing Xcode Command Line Tools..."
        xcode-select --install 2>/dev/null || true
        echo "Once the Xcode install finishes, re-run this script."
        exit 0
    }
    brew install python@3.11 node git tmux 2>/dev/null || true
    PYTHON="$(brew --prefix python@3.11)/bin/python3.11"
    SUDO=""   # brew does not use sudo

elif [ "$OS" = "Linux" ]; then
    # Linux (Debian/Ubuntu — GCP VM)
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
    $SUDO apt-get update -qq
    $SUDO apt-get install -y -qq python3 python3-pip python3-venv python3-dev \
        git curl build-essential libffi-dev libssl-dev tmux \
        || error_exit "apt-get install failed"
    # Node 20 via NodeSource
    if ! command -v node >/dev/null 2>&1 \
        || [ "$(node -v | sed 's/v\([0-9]*\).*/\1/')" -lt 18 ]; then
        if [ -n "$SUDO" ]; then
            curl -fsSL https://deb.nodesource.com/setup_20.x | $SUDO -E bash -
        else
            curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        fi
        $SUDO apt-get install -y nodejs
    fi
    PYTHON="python3"

else
    error_exit "Unsupported OS: $OS (macOS or Linux only)"
fi

echo "    OS: $OS | Python: $($PYTHON --version) | Node: $(node -v) | npm: $(npm -v)"

# =============================================================================
# 2. PYTHON VERSION CHECK (>= 3.10)
# =============================================================================
PYV=$($PYTHON --version 2>&1 | awk '{print $2}')
[ "$(printf '%s\n' "3.10" "$PYV" | sort -V | head -n1)" = "3.10" ] \
    || error_exit "Python 3.10+ required, found $PYV"
echo "[2/6] Python $PYV OK"

# =============================================================================
# 3. CLONE TAU-BENCH (idempotent)
# =============================================================================
echo "[3/6] Fetching tau-bench..."
if [ ! -d "$REPO_DIR" ]; then
    git clone "$REPO_URL" "$REPO_DIR" || error_exit "git clone failed"
else
    echo "      tau-bench-repo already present; pulling latest"
    git -C "$REPO_DIR" pull --ff-only || echo "[WARN] pull failed; using existing checkout"
fi

# =============================================================================
# 4. VENV + TAU-BENCH + MCP
# =============================================================================
echo "[4/6] Building venv and installing tau-bench + mcp..."
if [ ! -d "${REPO_DIR}/.venv" ]; then
    $PYTHON -m venv "${REPO_DIR}/.venv" || error_exit "venv creation failed"
fi
"${REPO_DIR}/.venv/bin/pip" install --upgrade pip -q
"${REPO_DIR}/.venv/bin/pip" install -e "${REPO_DIR}" -q || error_exit "tau-bench install failed"
"${REPO_DIR}/.venv/bin/pip" install mcp -q              || error_exit "mcp install failed"
"${REPO_DIR}/.venv/bin/pip" install python-dotenv -q    || error_exit "python-dotenv install failed"
"${REPO_DIR}/.venv/bin/python" -c "from tau_bench.envs import get_env" \
    || error_exit "tau_bench import check failed"
echo "      tau-bench + mcp installed OK"

# =============================================================================
# 5. CODING AGENTS
# =============================================================================
echo "[5/6] Installing coding agents..."

# Install Claude Code CLI (best-effort; may fail on fresh VMs without proper npm setup)
if command -v npm >/dev/null 2>&1; then
    # Ensure global npm bin is in PATH (varies by OS/install method)
    NPM_GLOBAL_BIN="$(npm bin -g 2>/dev/null || npm root -g 2>/dev/null)/../bin"
    if [ -d "$NPM_GLOBAL_BIN" ]; then
        export PATH="$NPM_GLOBAL_BIN:$PATH"
    fi
    # Also add common npm global locations
    export PATH="$HOME/.npm-global/bin:$HOME/.local/bin:/usr/local/bin:$PATH"

    # Install with unsafe-perm to allow post-install scripts on root-owned systems
    npm install -g --unsafe-perm @anthropic-ai/claude-code 2>/dev/null || echo "    ⚠️  Claude Code install failed (will retry later)"
    npm install -g --unsafe-perm opencode 2>/dev/null || echo "    ⚠️  OpenCode install failed (will retry later)"

    # Verify they're in PATH now
    if command -v claude >/dev/null 2>&1; then
        echo "    ✓ claude CLI available: $(which claude)"
    else
        echo "    ⚠️  claude CLI not in PATH after install"
    fi
    if command -v opencode >/dev/null 2>&1; then
        echo "    ✓ opencode CLI available: $(which opencode)"
    else
        echo "    ⚠️  opencode CLI not in PATH after install"
    fi
else
    echo "    ⚠️  npm not available — skipping coding agent install"
fi

# =============================================================================
# 6. OUTPUT DIR
# =============================================================================
echo "[6/6] Creating output directory..."
mkdir -p "${SCRIPT_DIR}/output"

# =============================================================================
# 7. VERIFICATION
# =============================================================================
echo ""
echo "[VERIFY] Checking installation..."
all_good=true

# Check Python packages
if "${REPO_DIR}/.venv/bin/python" -c "from tau_bench.envs import get_env" 2>/dev/null; then
    echo "  ✓ tau-bench import OK"
else
    echo "  ✗ tau-bench import FAILED"
    all_good=false
fi

if "${REPO_DIR}/.venv/bin/python" -c "import mcp" 2>/dev/null; then
    echo "  ✓ mcp import OK"
else
    echo "  ✗ mcp import FAILED"
    all_good=false
fi

if "${REPO_DIR}/.venv/bin/python" -c "import dotenv" 2>/dev/null; then
    echo "  ✓ python-dotenv import OK"
else
    echo "  ✗ python-dotenv import FAILED"
    all_good=false
fi

# Check system tools
if command -v claude >/dev/null 2>&1; then
    echo "  ✓ claude CLI installed"
else
    echo "  ⚠ claude CLI not found (install with: npm install -g @anthropic-ai/claude-code)"
fi

if command -v tmux >/dev/null 2>&1; then
    echo "  ✓ tmux installed"
else
    echo "  ⚠ tmux not found"
fi

if [ "$all_good" = true ]; then
    echo ""
    echo "=========================================="
    echo "[SUCCESS] Setup complete."
    echo "Next:  cp .env.example .env"
    echo "       Fill in GRID_AI_API_KEY"
    echo "       source .env"
    echo "Then:  ./run_agentic.sh --agent claude --model <model> --task-ids \"0 1 2\""
    echo "=========================================="
else
    echo ""
    echo "=========================================="
    echo "[WARNING] Setup completed with errors."
    echo "Please review the failed checks above."
    echo "=========================================="
    exit 1
fi
