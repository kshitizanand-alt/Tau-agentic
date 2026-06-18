# tau-bench agentic

Run tau-bench with an **external coding agent** (Claude Code, OpenCode, …) instead of a
bare model. The agent reaches tau-bench's tools through an **MCP bridge**; you read the
reward tau-bench computes. tau-bench itself is unchanged — only the "test-taker" changes.

`tau-bench-repo/` (the cloned benchmark) lives **inside** this folder — the scripts
expect it at `tau-agentic/tau-bench-repo/`.

```
tau-agentic/
├── tau-bench-repo/        # the benchmark (cloned by setup_agentic.sh) — UNTOUCHED
├── tau_mcp_server.py      # THE BRIDGE (the only genuinely new code)
├── run_agentic.sh         # the runner: loops tasks, launches the agent, reads reward
├── setup_agentic.sh       # ONE setup: clones tau-bench, builds venv, installs mcp + agents
├── .env.example           # Grid credentials (copy to .env, fill key, `source` it)
├── configs/
│   ├── .mcp.json          # Claude Code MCP config  -> points at tau_mcp_server.py
│   ├── opencode.json      # OpenCode MCP config     -> same server
│   └── task_<id>.json     # generated per task at runtime
└── output/<run_id>/       # generated: per-task rewards, agent logs, final score
```

## What each piece does

- **`tau_mcp_server.py`** — wraps ONE task's tau-bench env and exposes 3 MCP tools:
  `get_task` (policy + tool list + customer's first message), `use_store_tool`
  (runs a store action via `env.step`), `reply_to_customer` (talks to the simulated
  customer via `env.step`). Every call routes through `env.step`; it writes the
  per-task reward to a file.
- **`run_agentic.sh`** — sets the Grid model-routing env, then for each task: writes
  `configs/task_<id>.json`, launches the chosen agent headless against the MCP config
  with a tau prompt, reads the reward the bridge wrote, and aggregates.
- **`configs/*.json`** — tell each agent where the (shared) MCP server is.

## Setup

1. `./setup_agentic.sh` — one self-contained step: installs system deps + Node,
   clones `tau-bench-repo/` into this folder, builds its venv, installs tau-bench +
   the `mcp` library, and installs the coding agents.
2. `cp .env.example .env`, fill in `GRID_AI_API_KEY`, then `source .env`.
3. Confirm the `>>> VERIFY <<<` spots in `tau_mcp_server.py` against the freshly
   cloned `tau-bench-repo/` (the `env` field names).

## Run

```bash
./run_agentic.sh --agent claude   --model glm-latest --task-ids "0 1 2"
./run_agentic.sh --agent opencode --model glm-latest --task-ids "0 1 2"
```

Results: `output/<run_id>/results_<agent>+<model>.json` (average reward = pass@1).
To compare fairly: same model + different agents tests the agents; same agent +
different models tests the models. Keep `--user-model` (the customer) fixed.

## Make sure calls hit Grid (not Anthropic/OpenAI)

- Keep **only** `GRID_AI_API_KEY` set — no real vendor keys — so mis-routes fail loudly.
- Check `output/<run_id>/*.agent.log` for the model the agent used.
- Check Grid AI's usage dashboard — the agent's calls and the customer-sim calls
  should both appear there.

## Before you scale — verify these

- The `>>> VERIFY <<<` spots in `tau_mcp_server.py` (tau-bench's `env.reset` /
  `env.step` / reward field names and the `Action` signature) against your cloned repo.
- The OpenCode config schema + install command against current OpenCode docs.
- Start with **one task + Claude Code** and watch the `.agent.log` to confirm the
  bridge works end-to-end before running the full split.

## New vs reused

- **New:** `tau_mcp_server.py` (the bridge — SWE-bench never needed one because its
  agent edits files; tau-bench's agent must call tools).
- **Glue:** `run_agentic.sh` + `configs/`.
- **Reused from swe-auto-eval:** the Grid model-routing recipe (base URL + overriding
  every `ANTHROPIC_*_MODEL` slot; OpenCode's `Grid/` provider).
- **Untouched:** `tau-bench-repo/`.
