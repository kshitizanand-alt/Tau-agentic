"""
tau_mcp_server.py

Wraps ONE tau-bench task as an MCP server, so an external coding agent
(Claude Code, OpenCode, ...) can drive it. This is the "plug" from the diagram:
the coding agent calls these tools, and each call goes through tau-bench's
env.step() against the real database. tau-bench stays the source of truth.

It is launched by the coding agent (see .mcp.json). It reads which task to load
from a small config file written by run_agentic.sh, and writes the latest reward
to a result file after every step so the orchestrator can read it once the agent
finishes.

NOTE: tau-bench's internal API names can drift between versions. The three spots
to verify against your cloned tau-bench-repo are marked  >>> VERIFY <<<.
"""

import json
import os
from typing import Any, Dict

from dotenv import load_dotenv
from mcp.server.fastmcp import FastMCP

# Load .env from project root so the server works without manual 'source .env'
load_dotenv()

# Map GRID_AI_API_KEY → LiteLLM proxy vars if not already set by the caller
if not os.environ.get("LITELLM_PROXY_API_KEY"):
    os.environ["LITELLM_PROXY_API_KEY"] = os.environ.get("GRID_AI_API_KEY", "")
if not os.environ.get("LITELLM_PROXY_API_BASE"):
    grid_url = os.environ.get("GRID_URL", "https://grid.ai.juspay.net")
    os.environ["LITELLM_PROXY_API_BASE"] = grid_url

# Defensive imports — tau-bench API names drift between versions
try:
    from tau_bench.envs import get_env          # same function run.py uses
    from tau_bench.types import Action          # >>> VERIFY <<< Action(name=, kwargs=)
    from tau_bench.types import RESPOND_ACTION_NAME
except ImportError as e:
    import sys
    print(f"[FATAL] tau-bench import failed: {e}", file=sys.stderr)
    print("[FATAL] Verify tau-bench is installed and API names match.", file=sys.stderr)
    raise

# ---- which task am I serving? (written by run_agentic.sh) -------------------
CONFIG_PATH = os.environ.get("TAU_TASK_CONFIG", "mcp_task.json")
with open(CONFIG_PATH) as f:
    CFG = json.load(f)
RESULT_FILE = CFG["result_file"]

# Lazy-initialized state — env.reset() makes a blocking LLM call (~30-90s).
# Deferring it to get_task() lets the MCP server register its tools immediately
# so Claude Code doesn't time out waiting for the server to start.
_env = None
_first_message = None


def _ensure_env():
    global _env, _first_message
    if _env is not None:
        return
    try:
        _env = get_env(
            CFG["domain"],                    # "retail" or "airline"
            user_strategy="llm",
            user_model=CFG["user_model"],     # the fake-customer model (via your gateway)
            user_provider="litellm_proxy",
            task_split=CFG.get("task_split", "test"),
            task_index=CFG["task_index"],
        )
        _reset = _env.reset(task_index=CFG["task_index"])
        # Defensive attribute access — tau-bench return types vary by version
        if hasattr(_reset, "observation"):
            _first_message = _reset.observation
        elif hasattr(_reset, "message"):
            _first_message = _reset.message
        elif isinstance(_reset, str):
            _first_message = _reset
        else:
            _first_message = str(_reset)
        _record(0.0, False)
    except Exception as e:
        import traceback, sys
        print(f"[FATAL] _ensure_env() failed: {e}", file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        raise


def _record(reward: float, done: bool) -> None:
    # Write after every step. The LAST write reflects the final database state,
    # which is what grading cares about.
    with open(RESULT_FILE, "w") as f:
        json.dump(
            {"task_index": CFG["task_index"], "reward": reward, "done": done}, f
        )


mcp = FastMCP("taubench")


@mcp.tool()
def get_task() -> Dict[str, Any]:
    """Call this FIRST. Returns the store policy you must follow, the list of
    store tools available to you, and the customer's opening message."""
    _ensure_env()
    return {
        "policy": _env.wiki,
        "available_store_tools": _env.tools_info,   # names + JSON schemas
        "customer_message": _first_message,
    }


@mcp.tool()
def use_store_tool(tool_name: str, arguments: Dict[str, Any]) -> str:
    """Run one of the store's tools (e.g. get_order_details, cancel_pending_order).
    Pass the tool name and a dict of its arguments. Returns the tool's result
    (which may be an error message — if so, fix your arguments and try again)."""
    _ensure_env()
    try:
        resp = _env.step(Action(name=tool_name, kwargs=arguments))
        # Defensive attribute access — tau-bench return types vary by version
        reward = getattr(resp, "reward", 0.0)
        done = getattr(resp, "done", False)
        observation = getattr(resp, "observation", str(resp))
        _record(reward, done)
        return str(observation)
    except Exception as e:
        return f"[store tool error: {e}. Try again or rephrase your arguments.]"


@mcp.tool()
def reply_to_customer(message: str) -> str:
    """Send a message to the customer and receive their reply. Use this to ask
    for information, confirm an action, or close out the conversation."""
    _ensure_env()
    try:
        resp = _env.step(Action(name=RESPOND_ACTION_NAME, kwargs={"content": message}))
        # Defensive attribute access — tau-bench return types vary by version
        reward = getattr(resp, "reward", 0.0)
        done = getattr(resp, "done", False)
        observation = getattr(resp, "observation", str(resp))
        _record(reward, done)
        if done:
            return str(observation) + "\n\n[the conversation has ended]"
        return str(observation)
    except Exception as e:
        return f"[user simulator error: {e}. Retry the reply_to_customer call.]"


if __name__ == "__main__":
    mcp.run()   # stdio transport by default — the coding agent talks to it over stdio
