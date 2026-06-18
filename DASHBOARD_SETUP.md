# Tau-Agentic Dashboard Setup Guide

This guide explains how to set up and run the tau-bench agentic benchmark on a fresh VM (dashboard or local).

## Quick Start

```bash
# 1. Clone the repository
git clone <your-repo-url> tau-agentic
cd tau-agentic

# 2. Run setup (installs all dependencies)
./setup_agentic.sh

# 3. Configure environment
cp .env.example .env
# Edit .env and add your GRID_AI_API_KEY
source .env

# 4. Run benchmark
./run_benchmark.sh claude private-large retail "0 1 2" run_001
```

## Files Overview

| File | Purpose |
|------|---------|
| `setup_agentic.sh` | One-command setup for all dependencies |
| `run_agentic.sh` | Core runner (loop tasks, launch agent, collect rewards) |
| `run_benchmark.sh` | Dashboard-compatible wrapper with summary generation |
| `generate_summary.py` | Standalone summary generator |
| `tau_mcp_server.py` | MCP bridge between agent and tau-bench |
| `requirements.txt` | Python dependencies |
| `.env.example` | Environment variable template |

## Dashboard Entry Point

The dashboard should call:

```bash
./run_benchmark.sh <agent> <model> <domain> <task_ids> <run_id> [parallel]
```

Examples:
```bash
# Run tasks 0-49 with claude agent
./run_benchmark.sh claude private-large retail "0-49" run_001 1

# Run specific tasks with opencode
./run_benchmark.sh opencode glm-latest airline "0 1 2 3 4" test_run 1
```

## Output Structure

```
output/<run_id>/
├── results_<agent>+<model>.json    # Aggregated results
├── <agent>+<model>__task_<id>.json # Per-task reward
├── <agent>+<model>__task_<id>.agent.log  # Agent logs
└── summary/                        # Dashboard-compatible summary
    ├── summary.json                # Machine-readable summary
    ├── resolved.txt                # List of passed task indices
    ├── unresolved.txt              # List of failed task indices
    └── report.txt                  # Human-readable report
```

## Environment Variables

Required in `.env`:
```bash
export GRID_AI_API_KEY="your-key-here"
```

Optional:
```bash
export GRID_URL="https://grid.ai.juspay.net"  # Override Grid endpoint
```

## Troubleshooting

### Issue: `python-dotenv` not found
**Fix:** Already fixed in setup. Re-run `./setup_agentic.sh`.

### Issue: `tmux` not found
**Fix:** Already fixed in setup. Re-run `./setup_agentic.sh`.

### Issue: Hardcoded paths in configs
**Fix:** The `configs/.mcp.json` and `configs/opencode.json` files are now in `.gitignore`. They are regenerated at runtime by `run_agentic.sh`.

### Issue: API key leaks
**Fix:** `.env.example` now uses placeholder. Never commit `.env` or generated configs.

## What Was Fixed

1. ✅ Created `.gitignore` (excludes secrets, outputs, venv)
2. ✅ Removed hardcoded API keys from `.env.example`
3. ✅ Added `python-dotenv` to setup
4. ✅ Added `tmux` to setup
5. ✅ Created `requirements.txt`
6. ✅ Created `run_benchmark.sh` (dashboard entry point)
7. ✅ Created `generate_summary.py` (summary generator)
8. ✅ Fixed hardcoded Grid URL in `tau_mcp_server.py`
9. ✅ Added verification step to `setup_agentic.sh`
10. ✅ Generated configs excluded from git

## Next Steps

1. Initialize git repo: `git init && git add -A && git commit -m "Initial commit"`
2. Push to GitHub
3. Dashboard team clones and runs `./setup_agentic.sh`
4. Dashboard calls `./run_benchmark.sh` with their parameters