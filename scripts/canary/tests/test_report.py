"""RED-phase tests for scripts.canary.report.

Contract (to be implemented in report.py):

    TOKEN_BLOWUP_THRESHOLD_FACTOR: float
        Treatment token total may not exceed baseline by more than this
        factor without offsetting benefit (default 3.0).

    build_report(run_data: dict) -> str
        Aggregated canary results → markdown GO/NO-GO report.  run_data shape:

        {
          "metadata": {
            "git_sha": str,
            "build_mode": str,
            "provider": str,
            "model": str,
            "non_streaming": bool,
            "scratch_home": str,
            "scratch_ws_baseline": str,
            "scratch_ws_treatment": str,
          },
          "isolation": {
            "live_db_hash_before": str,
            "live_db_hash_after": str,
            "response_cache_enabled": bool,
          },
          "by_class": {
            "replayed_tool_failure": {
              "baseline": <parser_result_dict>,
              "treatment": <parser_result_dict>,
            },
            "memory_dependent": {...},
            "simple_qa": {...},
          },
          "memory_inventory": {
            "lesson_count": int,
            "sessions": [str],
            "lessons": [{
              "key": str,
              "utility_score": float,
              "utility_score_source": str,
              "excerpt": str,
            }],
          },
        }

    evaluate_go_no_go(run_data: dict) -> dict
        Returns at least:
        {
          "decision": "GO" | "NO-GO" | "INCONCLUSIVE",
          "kill_signals": [str, ...],
          "reasons": [str, ...],
        }

Kill signals (any one → NO-GO):
    live_db_changed
    judge_still_streaming      — treatment judge_skipped["streaming"] > 0
    reflection_no_useful_lessons
    token_blowup
    unknown_line_drift
"""

from __future__ import annotations

import unittest

from scripts.canary import report

INPUT_CLASSES = (
    "replayed_tool_failure",
    "memory_dependent",
    "simple_qa",
)


def _empty_parser_result() -> dict:
    """Minimal parser_result_dict matching scripts.canary.parser.parse_log output."""
    return {
        "reflection_invoked": 0,
        "judge_invoked": 0,
        "lesson_saved": 0,
        "lesson_rejected": {},
        "lesson_recalled": 0,
        "lesson_recalled_details": [],
        "reflection_skipped": {},
        "reflection_verdict_null": {},
        "success_attribution_applied": 0,
        "success_attribution_withheld": {},
        "judge_decision_continue": 0,
        "judge_stop_goal_achieved": 0,
        "judge_no_progress_force_fail": 0,
        "judge_verdict_null": {},
        "judge_ineligible": {},
        "judge_skipped": {},
        "estimated_tokens_total": 0,
        "unknown_lines": [],
    }


def _parser_result(
    *,
    reflection_invoked: int = 0,
    judge_invoked: int = 0,
    estimated_tokens_total: int = 0,
    judge_skipped: dict | None = None,
    unknown_lines: list | None = None,
) -> dict:
    result = _empty_parser_result()
    result["reflection_invoked"] = reflection_invoked
    result["judge_invoked"] = judge_invoked
    result["estimated_tokens_total"] = estimated_tokens_total
    if judge_skipped is not None:
        result["judge_skipped"] = dict(judge_skipped)
    if unknown_lines is not None:
        result["unknown_lines"] = list(unknown_lines)
    return result


def _by_class_pair(
    *,
    baseline_tokens: int = 100,
    treatment_tokens: int = 120,
    treatment_judge_invoked: int = 1,
    treatment_reflection_invoked: int = 0,
    treatment_judge_skipped: dict | None = None,
    baseline_unknown_lines: list | None = None,
    treatment_unknown_lines: list | None = None,
) -> dict:
    return {
        "baseline": _parser_result(
            estimated_tokens_total=baseline_tokens,
            unknown_lines=baseline_unknown_lines or [],
        ),
        "treatment": _parser_result(
            reflection_invoked=treatment_reflection_invoked,
            judge_invoked=treatment_judge_invoked,
            estimated_tokens_total=treatment_tokens,
            judge_skipped=treatment_judge_skipped,
            unknown_lines=treatment_unknown_lines or [],
        ),
    }


def _minimal_run_data(**overrides) -> dict:
    """Clean GO fixture: isolated DB, judge fired, lessons saved, no drift."""
    data = {
        "metadata": {
            "git_sha": "abc123def456",
            "build_mode": "Debug",
            "provider": "glm",
            "model": "glm-4-flash",
            "non_streaming": True,
            "scratch_home": "/tmp/nullclaw-canary-20260706/home",
            "scratch_ws_baseline": "/tmp/nullclaw-canary-20260706/baseline-ws",
            "scratch_ws_treatment": "/tmp/nullclaw-canary-20260706/treatment-ws",
        },
        "isolation": {
            "live_db_hash_before": "sha256:deadbeef_before",
            "live_db_hash_after": "sha256:deadbeef_before",
            "response_cache_enabled": False,
        },
        "by_class": {
            cls: _by_class_pair(
                baseline_tokens=100,
                treatment_tokens=120,
                treatment_judge_invoked=1,
            )
            for cls in INPUT_CLASSES
        },
        "memory_inventory": {
            "lesson_count": 2,
            "sessions": ["canary-tool-fail-1", "canary-memory-loop-1"],
            "lessons": [
                {
                    "key": "lesson.shell_path",
                    "utility_score": 0.75,
                    "utility_score_source": "delayed_outcome",
                    "excerpt": "Use absolute python3 path in cron.",
                },
                {
                    "key": "lesson.retry_backoff",
                    "utility_score": 0.5,
                    "utility_score_source": "delayed_outcome",
                    "excerpt": "Retry transient HTTP with backoff.",
                },
            ],
        },
    }
    for key, value in overrides.items():
        if key == "by_class" and isinstance(value, dict):
            data["by_class"].update(value)
        elif key == "isolation" and isinstance(value, dict):
            data["isolation"].update(value)
        elif key == "memory_inventory" and isinstance(value, dict):
            data["memory_inventory"].update(value)
        elif key == "metadata" and isinstance(value, dict):
            data["metadata"].update(value)
        else:
            data[key] = value
    return data


class TestBuildReport(unittest.TestCase):
    """build_report produces markdown with required sections."""

    def test_build_report_returns_markdown(self) -> None:
        """build_report returns non-empty markdown with expected section headers."""
        md = report.build_report(_minimal_run_data())
        self.assertIsInstance(md, str)
        self.assertGreater(len(md), 0)
        for heading in ("Isolation", "Judge", "Reflection", "GO/NO-GO"):
            self.assertIn(heading, md, f"missing section heading {heading!r}")

    def test_report_includes_isolation_proof(self) -> None:
        """Markdown includes live-db hashes and response-cache state."""
        run_data = _minimal_run_data()
        md = report.build_report(run_data)
        iso = run_data["isolation"]
        self.assertIn(iso["live_db_hash_before"], md)
        self.assertIn(iso["live_db_hash_after"], md)
        self.assertIn("response_cache_enabled", md.lower())

    def test_report_names_all_three_input_classes(self) -> None:
        """Per-class breakdown mentions every input class."""
        md = report.build_report(_minimal_run_data())
        for cls in INPUT_CLASSES:
            self.assertIn(cls, md, f"missing input class {cls!r}")


class TestEvaluateGoNoGo(unittest.TestCase):
    """evaluate_go_no_go applies kill-signal rules from the design spec."""

    def test_go_when_clean(self) -> None:
        """Clean run → GO with no kill signals."""
        result = report.evaluate_go_no_go(_minimal_run_data())
        self.assertEqual(result["decision"], "GO")
        self.assertEqual(result["kill_signals"], [])
        self.assertIsInstance(result["reasons"], list)

    def test_no_go_on_live_db_changed(self) -> None:
        """Live memory.db hash drift is the hardest safety kill."""
        run_data = _minimal_run_data(
            isolation={
                "live_db_hash_before": "sha256:before",
                "live_db_hash_after": "sha256:after_pollution",
            },
        )
        result = report.evaluate_go_no_go(run_data)
        self.assertEqual(result["decision"], "NO-GO")
        self.assertIn("live_db_changed", result["kill_signals"])

    def test_no_go_on_judge_still_streaming(self) -> None:
        """Treatment judge_skipped['streaming'] > 0 means non-streaming route failed."""
        run_data = _minimal_run_data(
            by_class={
                "replayed_tool_failure": _by_class_pair(
                    treatment_judge_skipped={"streaming": 1},
                ),
            },
        )
        result = report.evaluate_go_no_go(run_data)
        self.assertEqual(result["decision"], "NO-GO")
        self.assertIn("judge_still_streaming", result["kill_signals"])

    def test_no_go_on_no_useful_lessons(self) -> None:
        """Judge/reflection fired on tool-failure class but no lessons persisted."""
        tool_fail = _by_class_pair(treatment_judge_invoked=2)
        run_data = _minimal_run_data(
            by_class={"replayed_tool_failure": tool_fail},
            memory_inventory={"lesson_count": 0, "sessions": [], "lessons": []},
        )
        result = report.evaluate_go_no_go(run_data)
        self.assertEqual(result["decision"], "NO-GO")
        self.assertIn("reflection_no_useful_lessons", result["kill_signals"])

    def test_no_go_on_token_blowup(self) -> None:
        """Treatment tokens > TOKEN_BLOWUP_THRESHOLD_FACTOR × baseline → NO-GO."""
        threshold = report.TOKEN_BLOWUP_THRESHOLD_FACTOR
        baseline_tokens = 100
        blowup_tokens = int(baseline_tokens * threshold * 5)
        run_data = _minimal_run_data(
            by_class={
                "simple_qa": _by_class_pair(
                    baseline_tokens=baseline_tokens,
                    treatment_tokens=blowup_tokens,
                    treatment_judge_invoked=1,
                ),
            },
        )
        result = report.evaluate_go_no_go(run_data)
        self.assertEqual(result["decision"], "NO-GO")
        self.assertIn("token_blowup", result["kill_signals"])

    def test_no_go_on_unknown_line_drift(self) -> None:
        """Non-empty unknown_lines in any arm signals observability format drift."""
        run_data = _minimal_run_data(
            by_class={
                "memory_dependent": _by_class_pair(
                    baseline_unknown_lines=["judge some_new_thing foo=1"],
                ),
            },
        )
        result = report.evaluate_go_no_go(run_data)
        self.assertEqual(result["decision"], "NO-GO")
        self.assertIn("unknown_line_drift", result["kill_signals"])


class TestReportConstants(unittest.TestCase):
    """Named constants are importable and testable."""

    def test_token_blowup_threshold_is_positive_float(self) -> None:
        """TOKEN_BLOWUP_THRESHOLD_FACTOR is a named, positive multiplier."""
        self.assertIsInstance(report.TOKEN_BLOWUP_THRESHOLD_FACTOR, float)
        self.assertGreater(report.TOKEN_BLOWUP_THRESHOLD_FACTOR, 1.0)


if __name__ == "__main__":
    unittest.main()