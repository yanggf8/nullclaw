"""RED-phase tests for scripts.canary.parser.parse_log.

Contract (to be implemented in parser.py):
    parse_log(text: str) -> dict
        Parses captured stderr from nullclaw agent -m runs and extracts
        agent_reflection / agent_judge observability events.

        Returns counts per event type, estimated_tokens_total (summed across
        all token-bearing lines, not last-wins), unknown_lines for drift
        detection, and structured fields (e.g. session_scoped bool on recall).
"""

from __future__ import annotations

import os
import unittest

from scripts.canary import parser

FIXTURE_PATH = os.path.join(
    os.path.dirname(__file__),
    "..",
    "fixtures",
    "agent_reflection_judge.log",
)


def _load_fixture() -> str:
    with open(FIXTURE_PATH, encoding="utf-8") as fh:
        return fh.read()


class TestParseLog(unittest.TestCase):
    """Log parser extracts agent_reflection / agent_judge events from stderr."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.fixture_text = _load_fixture()
        cls.result = parser.parse_log(cls.fixture_text)

    def test_parses_reflection_invoked(self) -> None:
        """reflection_invoked count matches fixture (one invocation)."""
        self.assertEqual(self.result["reflection_invoked"], 1)

    def test_parses_judge_invoked(self) -> None:
        """judge_invoked count matches fixture (two lines in one invoke block)."""
        self.assertEqual(self.result["judge_invoked"], 2)

    def test_lesson_saved_and_rejected_counts(self) -> None:
        """lesson_saved and lesson_rejected (by reason) match fixture."""
        self.assertEqual(self.result["lesson_saved"], 1)
        self.assertEqual(self.result["lesson_rejected"]["quality_gate"], 1)

    def test_estimated_tokens_summed_not_last(self) -> None:
        """estimated_tokens_total sums ALL token-bearing lines, not last-wins.

        Fixture token lines:
          reflection invoked: 45
          reflection verdict null parse_fail: 30
          judge invoked (1st): 40
          judge invoked (2nd): 35
        Expected total: 150 (not 35 or any single value).
        """
        self.assertEqual(self.result["estimated_tokens_total"], 150)

    def test_ignores_unrelated_scopes(self) -> None:
        """info(memory)/info(agent)/stdout noise contribute nothing to counts."""
        # Unrelated lines must not inflate reflection/judge event counts.
        self.assertEqual(self.result["reflection_invoked"], 1)
        self.assertEqual(self.result["judge_invoked"], 2)
        self.assertEqual(self.result["lesson_saved"], 1)
        self.assertEqual(self.result["lesson_recalled"], 1)

    def test_strips_ansi(self) -> None:
        """ANSI-wrapped reflection skipped reason=disabled is still parsed."""
        self.assertEqual(
            self.result["reflection_skipped"]["disabled"],
            1,
        )

    def test_level_is_warning_not_warn(self) -> None:
        """warning(agent_reflection) lesson quality gate rejected is a rejection."""
        self.assertEqual(self.result["lesson_rejected"]["quality_gate"], 1)

    def test_unknown_line_drift_detected(self) -> None:
        """Unknown agent_judge message shape appears in unknown_lines."""
        unknown = self.result["unknown_lines"]
        self.assertEqual(len(unknown), 1)
        self.assertIn("judge some_new_thing foo=1", unknown[0])

    def test_session_scoped_bool_parsed(self) -> None:
        """lesson recalled session_scoped=true parses as bool True, not string."""
        recalls = self.result.get("lesson_recalled_details")
        self.assertIsNotNone(recalls)
        self.assertEqual(len(recalls), 1)
        self.assertIs(recalls[0]["session_scoped"], True)


if __name__ == "__main__":
    unittest.main()