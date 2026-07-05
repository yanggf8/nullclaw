"""NullClaw self-improvement canary harness (offline replay, isolated).

Agent and memory commands run against scratch NULLCLAW_HOME and NULLCLAW_WORKSPACE
under a throwaway scratch root. History list/show commands read the production
SessionStore read-only and are never isolated to scratch.
"""

from __future__ import annotations

import argparse
import copy
import json
import os
import tempfile
from dataclasses import dataclass
from typing import Any

# Documents that history sampling reads production store read-only (see module docstring).
HISTORY_READS_PRODUCTION = True

KNOWN_NON_STREAMING_BUILTINS = frozenset({"glm", "zai"})


@dataclass
class ScratchContext:
    scratch_root: str
    scratch_home: str
    base_config_path: str | None
    nullclaw_binary: str


@dataclass
class PlannedInvocation:
    arm: str
    argv: list[str]
    env: dict[str, str]


def _deep_copy_config(base: dict[str, Any]) -> dict[str, Any]:
    return copy.deepcopy(base)


def _select_non_streaming_provider(config: dict[str, Any]) -> str:
    """Pick a non-streaming provider route; mutate config in place when needed."""
    models = config.setdefault("models", {})
    providers: dict[str, Any] = models.setdefault("providers", {})

    for name, cfg in providers.items():
        if cfg.get("api_mode") == "responses":
            return name

    for name in providers:
        if name in KNOWN_NON_STREAMING_BUILTINS:
            return name

    default_name = models.get("default_provider")
    if default_name and default_name in providers:
        chosen = default_name
    elif providers:
        chosen = next(iter(providers))
    else:
        chosen = "openai"
        providers[chosen] = {"api_mode": "chat", "models": []}

    providers[chosen]["api_mode"] = "responses"
    return chosen


def generate_scratch_config(
    base_config_dict: dict[str, Any],
    scratch_home: str,
    scratch_ws: str,
) -> tuple[dict[str, Any], str]:
    """Derive scratch config: sqlite backend, cache off, non-streaming route."""
    del scratch_ws  # reserved for future workspace-specific overrides

    os.makedirs(scratch_home, exist_ok=True)

    config = _deep_copy_config(base_config_dict)

    memory = config.setdefault("memory", {})
    memory["backend"] = "sqlite"

    response_cache = memory.setdefault("response_cache", {})
    response_cache["enabled"] = False

    selected = _select_non_streaming_provider(config)
    config["canary_selected_provider"] = selected

    config_path = os.path.join(scratch_home, "config.json")
    with open(config_path, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2)
        fh.write("\n")

    return config, config_path


def _workspace_for_arm(scratch_root: str, session: str, arm: str) -> str:
    safe_session = session.replace(os.sep, "_")
    return os.path.join(scratch_root, f"{arm}-ws-{safe_session}")


def plan_invocations(
    inputs: list[dict[str, str]],
    scratch: ScratchContext,
) -> list[PlannedInvocation]:
    """Plan baseline then treatment child-form agent invocations per input."""
    planned: list[PlannedInvocation] = []

    for inp in inputs:
        message = inp["message"]
        session = inp["session"]

        for arm, judge_flag, reflect_flag in (
            ("baseline", "0", "0"),
            ("treatment", "1", "1"),
        ):
            workspace = _workspace_for_arm(scratch.scratch_root, session, arm)
            env = {
                "NULLCLAW_HOME": scratch.scratch_home,
                "NULLCLAW_WORKSPACE": workspace,
                "NULLCLAW_AGENT_JUDGE_AFTER_TURN": judge_flag,
                "NULLCLAW_AGENT_REFLECT_AFTER_TURN": reflect_flag,
            }
            argv = [
                scratch.nullclaw_binary,
                "agent",
                "-m",
                message,
                "-s",
                session,
                "--workspace",
                workspace,
            ]
            planned.append(PlannedInvocation(arm=arm, argv=argv, env=env))

    return planned


def _default_synthetic_inputs() -> list[dict[str, str]]:
    return [
        {"message": "retry the failed tool call", "session": "canary-sess-1"},
        {"message": "what lesson did we learn?", "session": "canary-sess-2"},
    ]


def _build_scratch_context(binary: str) -> ScratchContext:
    scratch_root = tempfile.mkdtemp(prefix="nullclaw-canary-dry-")
    scratch_home = os.path.join(scratch_root, "home")
    os.makedirs(scratch_home, exist_ok=True)
    return ScratchContext(
        scratch_root=scratch_root,
        scratch_home=scratch_home,
        base_config_path=None,
        nullclaw_binary=binary,
    )


def _format_plan(planned: list[PlannedInvocation]) -> str:
    lines: list[str] = []
    for inv in planned:
        lines.append(f"[{inv.arm}]")
        lines.append("  argv: " + " ".join(inv.argv))
        for key in sorted(inv.env):
            lines.append(f"  env {key}={inv.env[key]}")
        lines.append("")
    return "\n".join(lines)


def dry_run(args: list[str]) -> str:
    """Build and return the invocation plan without spawning subprocesses."""
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--binary", default="zig-out/bin/nullclaw")
    parser.add_argument("--input", default="synthetic")
    parsed, _unknown = parser.parse_known_args(args)

    if not parsed.dry_run:
        return ""

    scratch = _build_scratch_context(parsed.binary)
    inputs = _default_synthetic_inputs() if parsed.input == "synthetic" else []
    planned = plan_invocations(inputs, scratch)
    return _format_plan(planned)


def main(argv: list[str] | None = None) -> int:
    """CLI entry point; --dry-run plans invocations without subprocess."""
    if argv is None:
        argv = []

    if "--dry-run" in argv:
        dry_run(argv)
        return 0

    return 0