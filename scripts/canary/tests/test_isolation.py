"""RED-phase tests for canary structural isolation (offline, no live DB).

Contract (to be implemented in run.py):
    HISTORY_READS_PRODUCTION: bool = True
        Documents that history list/show reads the production SessionStore
        read-only; only agent/memory commands use scratch NULLCLAW_HOME.

    plan_invocations(...) planned paths must resolve under scratch_root only.

Note: live before/after-hash isolation against ~/.nullclaw/memory.db is a
separate gated integration test — NOT covered here per corroboration fix #6.
"""

from __future__ import annotations

import os
import tempfile
import unittest

from scripts.canary import run


def _sample_inputs() -> list[dict]:
    return [{"message": "smoke prompt", "session": "iso-sess-1"}]


def _make_scratch_context(scratch_root: str) -> object:
    scratch_home = os.path.join(scratch_root, "home")
    os.makedirs(scratch_home, exist_ok=True)
    return run.ScratchContext(
        scratch_root=scratch_root,
        scratch_home=scratch_home,
        base_config_path=None,
        nullclaw_binary="zig-out/bin/nullclaw",
    )


class TestIsolation(unittest.TestCase):
    """Structural path isolation; production history reads documented."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="nullclaw-canary-iso-")
        self.scratch_root = self.tmp.name
        self.scratch = _make_scratch_context(self.scratch_root)
        self.real_nullclaw_home = os.path.expanduser("~/.nullclaw")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_structural_isolation_paths_under_scratch(self) -> None:
        """NULLCLAW_HOME, NULLCLAW_WORKSPACE, and --workspace stay under scratch."""
        planned = run.plan_invocations(_sample_inputs(), self.scratch)
        self.assertGreater(len(planned), 0)

        scratch_root_real = os.path.realpath(self.scratch_root)
        real_home_real = os.path.realpath(self.real_nullclaw_home)

        for inv in planned:
            for env_key in ("NULLCLAW_HOME", "NULLCLAW_WORKSPACE"):
                path = inv.env.get(env_key)
                self.assertIsNotNone(path, f"{env_key} must be set")
                path_real = os.path.realpath(path)
                self.assertTrue(
                    path_real.startswith(scratch_root_real + os.sep)
                    or path_real == scratch_root_real,
                    f"{env_key}={path!r} must resolve under scratch_root {self.scratch_root!r}",
                )
                self.assertFalse(
                    path_real.startswith(real_home_real),
                    f"{env_key} must not resolve under real home {self.real_nullclaw_home!r}",
                )

            if "--workspace" in inv.argv:
                idx = inv.argv.index("--workspace")
                ws = inv.argv[idx + 1]
                ws_real = os.path.realpath(ws)
                self.assertTrue(
                    ws_real.startswith(scratch_root_real + os.sep)
                    or ws_real == scratch_root_real,
                    f"--workspace {ws!r} must resolve under scratch_root",
                )
                self.assertFalse(
                    ws_real.startswith(real_home_real),
                    f"--workspace must not resolve under real home",
                )

    def test_history_sampling_is_readonly_documented(self) -> None:
        """Module documents that history commands read production store read-only."""
        self.assertTrue(
            run.HISTORY_READS_PRODUCTION,
            "run.HISTORY_READS_PRODUCTION must be True to document read-only history sampling",
        )
        doc = getattr(run, "__doc__", None) or ""
        module_doc = doc.lower()
        self.assertTrue(
            "history" in module_doc and ("read-only" in module_doc or "readonly" in module_doc),
            "run module docstring must document read-only production history sampling",
        )


if __name__ == "__main__":
    unittest.main()