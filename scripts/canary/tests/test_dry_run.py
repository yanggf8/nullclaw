"""RED-phase tests for scripts.canary.run dry-run and invocation planning.

Contracts (to be implemented in run.py):
    plan_invocations(
        inputs: list[CanaryInput],
        scratch: ScratchContext,
    ) -> list[PlannedInvocation]
        Each input yields exactly two planned commands: baseline then treatment.

    PlannedInvocation fields:
        arm: str              # "baseline" | "treatment"
        argv: list[str]       # e.g. ["nullclaw", "agent", "-m", MSG, "-s", SESSION, "--workspace", WS]
        env: dict[str, str]   # includes NULLCLAW_HOME, NULLCLAW_WORKSPACE, flag overrides

    dry_run(args: list[str]) -> str
        Print/return invocation plan without subprocess.

    main(argv: list[str]) -> int
        CLI entry; --dry-run delegates to dry_run without spawning children.
"""

from __future__ import annotations

import os
import subprocess
import tempfile
import unittest
from unittest import mock

from scripts.canary import run


def _sample_inputs() -> list[dict]:
    return [
        {"message": "retry the failed tool call", "session": "canary-sess-1"},
        {"message": "what lesson did we learn?", "session": "canary-sess-2"},
    ]


def _make_scratch_context(scratch_root: str) -> object:
    """Build ScratchContext per run.ScratchContext contract."""
    scratch_home = os.path.join(scratch_root, "home")
    os.makedirs(scratch_home, exist_ok=True)
    return run.ScratchContext(
        scratch_root=scratch_root,
        scratch_home=scratch_home,
        base_config_path=None,
        nullclaw_binary="zig-out/bin/nullclaw",
    )


def _planned_by_arm(planned: list, arm: str) -> list:
    return [p for p in planned if p.arm == arm]


def _workspace_from_argv(argv: list[str]) -> str | None:
    if "--workspace" not in argv:
        return None
    idx = argv.index("--workspace")
    return argv[idx + 1]


class TestDryRun(unittest.TestCase):
    """Dry-run planning: two arms per input, correct env, no subprocess."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory(prefix="nullclaw-canary-dry-")
        self.scratch = _make_scratch_context(self.tmp.name)
        self.inputs = _sample_inputs()

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_dry_run_prints_both_arms(self) -> None:
        """Each input must produce exactly two planned invocations."""
        planned = run.plan_invocations(self.inputs, self.scratch)

        self.assertEqual(len(planned), len(self.inputs) * 2)

        for inp in self.inputs:
            session = inp["session"]
            matching = [
                p
                for p in planned
                if "-s" in p.argv and p.argv[p.argv.index("-s") + 1] == session
            ]
            self.assertEqual(
                len(matching),
                2,
                f"input session {session!r} must yield baseline + treatment",
            )
            arms = {p.arm for p in matching}
            self.assertEqual(arms, {"baseline", "treatment"})

    def test_baseline_arm_flags_off(self) -> None:
        """Baseline arm disables judge and reflect via env vars."""
        planned = run.plan_invocations(self.inputs, self.scratch)
        baseline = _planned_by_arm(planned, "baseline")
        self.assertGreater(len(baseline), 0)

        for inv in baseline:
            self.assertEqual(inv.env.get("NULLCLAW_AGENT_JUDGE_AFTER_TURN"), "0")
            self.assertEqual(inv.env.get("NULLCLAW_AGENT_REFLECT_AFTER_TURN"), "0")

    def test_treatment_arm_flags_on(self) -> None:
        """Treatment arm enables judge and reflect via env vars."""
        planned = run.plan_invocations(self.inputs, self.scratch)
        treatment = _planned_by_arm(planned, "treatment")
        self.assertGreater(len(treatment), 0)

        for inv in treatment:
            self.assertEqual(inv.env.get("NULLCLAW_AGENT_JUDGE_AFTER_TURN"), "1")
            self.assertEqual(inv.env.get("NULLCLAW_AGENT_REFLECT_AFTER_TURN"), "1")

    def test_arms_use_separate_workspaces(self) -> None:
        """Baseline and treatment must use distinct --workspace paths."""
        planned = run.plan_invocations(self.inputs, self.scratch)

        for inp in self.inputs:
            session = inp["session"]
            matching = [
                p
                for p in planned
                if "-s" in p.argv and p.argv[p.argv.index("-s") + 1] == session
            ]
            baseline_ws = _workspace_from_argv(
                next(p.argv for p in matching if p.arm == "baseline")
            )
            treatment_ws = _workspace_from_argv(
                next(p.argv for p in matching if p.arm == "treatment")
            )

            self.assertIsNotNone(baseline_ws)
            self.assertIsNotNone(treatment_ws)
            self.assertNotEqual(baseline_ws, treatment_ws)
            self.assertIn("baseline", baseline_ws)
            self.assertIn("treatment", treatment_ws)

    def test_all_agent_commands_use_child_form(self) -> None:
        """Every planned command is child-form agent -m/-s/--workspace, not invoke."""
        planned = run.plan_invocations(self.inputs, self.scratch)
        self.assertGreater(len(planned), 0)

        for inv in planned:
            argv = inv.argv
            self.assertIn("agent", argv)
            self.assertNotIn("invoke", argv)
            self.assertIn("-m", argv)
            self.assertIn("-s", argv)
            self.assertIn("--workspace", argv)

            self.assertIn("NULLCLAW_HOME", inv.env)
            self.assertIn("NULLCLAW_WORKSPACE", inv.env)
            self.assertTrue(inv.env["NULLCLAW_HOME"])
            self.assertTrue(inv.env["NULLCLAW_WORKSPACE"])

    @mock.patch("subprocess.Popen")
    @mock.patch("subprocess.run")
    def test_dry_run_spends_no_tokens(self, mock_run: mock.MagicMock, mock_popen: mock.MagicMock) -> None:
        """--dry-run must plan without invoking subprocess."""
        argv = [
            "--dry-run",
            "--binary",
            "zig-out/bin/nullclaw",
            "--input",
            "synthetic",
        ]

        result = run.main(argv)

        mock_run.assert_not_called()
        mock_popen.assert_not_called()

        # dry_run helper must also avoid subprocess when called directly.
        with mock.patch("subprocess.run") as direct_run, mock.patch(
            "subprocess.Popen"
        ) as direct_popen:
            output = run.dry_run(argv)
            direct_run.assert_not_called()
            direct_popen.assert_not_called()

        self.assertIsNotNone(result)
        self.assertIsNotNone(output)


if __name__ == "__main__":
    unittest.main()