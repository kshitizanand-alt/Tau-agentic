# Tau-Agentic Dashboard Registration Guide

This guide explains how to register the `tau-agentic` benchmark in the `xyne-eval-ops-dashboard`.

---

## Overview

The `tau-agentic` benchmark evaluates **both the model AND the agent framework** (Claude Code or OpenCode) on customer service tasks (airline/retail). This is different from the existing `tau` benchmark which only evaluates the model directly.

---

## Prerequisites

1. Docker installed and running on the dashboard host
2. Access to the `xyne-eval-ops-dashboard` admin panel
3. The `tau-agentic` Docker image built and pushed to a registry (or built locally)

---

## Step 1: Build the Docker Image

From the `tau-agentic` repo root:

```bash
# Build the dashboard-compatible image
docker build -f Dockerfile.dashboard -t tau-agentic:latest .

# Tag for registry (optional)
docker tag tau-agentic:latest your-registry.com/tau-agentic:latest
docker push your-registry.com/tau-agentic:latest
```

---

## Step 2: Register in Dashboard

Navigate to the dashboard admin panel and fill in the following fields:

### Basic Information

| Field | Value |
|-------|-------|
| **Name** | `tau-agentic` |
| **Domain** | `customer-service` |
| **Version** | `1.0.0` |
| **Description** | Evaluates model + agent framework on tau-bench customer service tasks |
| **Machine Type** | `n2-standard-8` (8 vCPU, 32 GiB recommended) |

### Repository

| Field | Value |
|-------|-------|
| **Repo URL** | `https://github.com/your-org/tau-agentic` |
| **Branch** | `main` |

### Docker Configuration

| Field | Value |
|-------|-------|
| **Image Name** | `tau-agentic:latest` |
| **Entrypoint** | `/app/entrypoint.sh` |
| **Workdir** | `/app` |

### Input Config (JSON)

Paste the **exact contents** of [`input_config_schema.json`](./input_config_schema.json).
That file is the single source of truth — do not hand-edit the JSON below; if the
two ever disagree, the file wins.

> **IMPORTANT — the `model` field is required.** The dashboard only forwards the
> model you select in the UI to the benchmark when the schema declares a field
> named `model` (the dashboard auto-fills it from the chosen model version's Grid
> alias and passes it as `--model`). If the `model` field is missing, the selected
> model is silently dropped and `dashboard_entrypoint.sh` falls back to a hardcoded
> agent→model default (claude→private-large, opencode→glm-latest) — so the UI
> selection is ignored. Always register with the schema below (or the file).

```json
{
  "fields": [
    {
      "name": "model",
      "type": "text",
      "label": "Model Alias",
      "description": "Grid model alias to evaluate (auto-filled from the selected model version)",
      "required": true,
      "default": "private-large"
    },
    {
      "name": "environment",
      "type": "text",
      "label": "Environment / Domain",
      "description": "The task domain to evaluate on",
      "required": true,
      "default": "airline",
      "options": ["airline", "retail"]
    },
    {
      "name": "agent",
      "type": "text",
      "label": "Coding Agent",
      "description": "The agent framework to use for task execution",
      "required": true,
      "default": "claude",
      "options": ["claude", "opencode"]
    },
    {
      "name": "max_concurrency",
      "type": "number",
      "label": "Max Concurrency",
      "description": "Number of tasks to run in parallel",
      "required": false,
      "default": 1,
      "constraints": { "min": 1, "max": 10 }
    },
    {
      "name": "task_range",
      "type": "text",
      "label": "Task Range",
      "description": "Range of task IDs to evaluate (e.g., 0-99 for all tasks, 0-9 for quick test)",
      "required": false,
      "default": "0-99",
      "constraints": { "min_length": 1, "max_length": 20 }
    },
    {
      "name": "number_of_trials",
      "type": "number",
      "label": "Number of Trials",
      "description": "Number of independent evaluation runs to average over",
      "required": false,
      "default": 1,
      "constraints": { "min": 1, "max": 5 }
    }
  ]
}
```

---

## Step 3: Dashboard Backend Config (One-Time)

Ask the dashboard team to add `tau-agentic` to their `benchmark_images` config in `eval-dashboard-benchmark/api-service/config.py`:

```python
benchmark_images: dict = {
    # ... existing benchmarks ...
    "tau-agentic": {
        "image": "tau-agentic:latest",
        "entrypoint": "/app/entrypoint.sh",
        "workdir": "/app"
    },
}
```

And add a result parser in `result_parsers.py` (or reuse the existing `TauParser`):

```python
PARSERS: Dict[str, ResultParser] = {
    # ... existing parsers ...
    "tau-agentic": TauParser(),  # Reuses the same parser
}
```

---

## Step 4: Run an Evaluation

1. Go to the dashboard **Run Eval** page
2. Select **Benchmark**: `tau-agentic`
3. Fill in the fields:
   - **Model to Evaluate**: e.g., `private-large`, `glm-latest`
   - **Version to Evaluate**: e.g., `v1.0`
   - **Environment**: `airline` or `retail`
   - **Agent**: `claude` or `opencode`
   - **Max Concurrency**: `1` (recommended for stability)
   - **Task Range**: `0-99` (full benchmark) or `0-9` (quick test)
   - **Number of Trials**: `1` (or more for averaging)
4. Click **Run Eval**

---

## How It Works

1. Dashboard spawns a Docker container with the `tau-agentic` image
2. Passes CLI args: `--api-base`, `--api-key`, `--agent-llm`, `--domain`, `--max-concurrency`
3. `dashboard_entrypoint.sh` maps these to `run_benchmark.sh` arguments
4. The benchmark runs via `run_agentic.sh` (spawns tmux sessions with Claude Code or OpenCode)
5. Results are written to `/app/results/` (mounted volume)
6. Dashboard parses `Average: X.XXXX` from stdout for the score

---

## Output Files

After a run, the following files are available in `/app/results/`:

| File | Description |
|------|-------------|
| `summary.json` | Full JSON summary with all metrics |
| `resolved.txt` | List of resolved task indices |
| `unresolved.txt` | List of unresolved task indices |
| `report.txt` | Human-readable evaluation report |
| `results.json` | Raw tau-bench results |

---

## Troubleshooting

### Issue: Container fails with "No API key found"
**Fix**: Ensure the dashboard is configured to pass `--api-key` to the container. The entrypoint sets `GRID_AI_API_KEY`, `ANTHROPIC_API_KEY`, and `OPENAI_API_KEY` from the same value.

### Issue: Claude Code not found
**Fix**: The Docker image installs `@anthropic-ai/claude-code` globally. Ensure the image was built correctly.

### Issue: Results not showing in dashboard
**Fix**: Check that `Average: X.XXXX` appears in the container stdout. The dashboard's `TauParser` looks for this pattern.

---

## Support

For issues with the benchmark itself, check the [`DASHBOARD_SETUP.md`](./DASHBOARD_SETUP.md) and [`README.md`](./README.md).

For dashboard integration issues, contact the `xyne-eval-ops-dashboard` team.