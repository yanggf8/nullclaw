"""Canary run aggregation, GO/NO-GO evaluation, and markdown reporting."""

from __future__ import annotations

from typing import Any

TOKEN_BLOWUP_THRESHOLD_FACTOR: float = 3.0

INPUT_CLASSES = (
    "replayed_tool_failure",
    "memory_dependent",
    "simple_qa",
)


def _get_by_class(run_data: dict) -> dict:
    return run_data.get("by_class", {})


def _get_arm_result(run_data: dict, cls: str, arm: str) -> dict:
    pair = _get_by_class(run_data).get(cls, {})
    return pair.get(arm, {})


def _sum_tokens(run_data: dict, arm: str) -> int:
    total = 0
    for cls in INPUT_CLASSES:
        result = _get_arm_result(run_data, cls, arm)
        total += int(result.get("estimated_tokens_total", 0))
    return total


def _any_unknown_lines(run_data: dict) -> bool:
    for cls in INPUT_CLASSES:
        for arm in ("baseline", "treatment"):
            lines = _get_arm_result(run_data, cls, arm).get("unknown_lines", [])
            if lines:
                return True
    return False


def _any_treatment_judge_streaming(run_data: dict) -> bool:
    for cls in INPUT_CLASSES:
        skipped = _get_arm_result(run_data, cls, "treatment").get("judge_skipped", {})
        if skipped.get("streaming", 0) > 0:
            return True
    return False


def _tool_failure_no_useful_lessons(run_data: dict) -> bool:
    inventory = run_data.get("memory_inventory", {})
    if int(inventory.get("lesson_count", 0)) != 0:
        return False
    treatment = _get_arm_result(run_data, "replayed_tool_failure", "treatment")
    judge_invoked = int(treatment.get("judge_invoked", 0))
    reflection_invoked = int(treatment.get("reflection_invoked", 0))
    return judge_invoked > 0 or reflection_invoked > 0


def _token_blowup(run_data: dict) -> bool:
    baseline_total = _sum_tokens(run_data, "baseline")
    treatment_total = _sum_tokens(run_data, "treatment")
    if baseline_total <= 0:
        return treatment_total > 0
    limit = baseline_total * TOKEN_BLOWUP_THRESHOLD_FACTOR
    return treatment_total > limit


def evaluate_go_no_go(run_data: dict) -> dict:
    """Apply kill-signal rules and return decision metadata."""
    kill_signals: list[str] = []
    reasons: list[str] = []

    isolation = run_data.get("isolation", {})
    hash_before = isolation.get("live_db_hash_before", "")
    hash_after = isolation.get("live_db_hash_after", "")
    if hash_before != hash_after:
        kill_signals.append("live_db_changed")
        reasons.append(
            f"Live memory.db hash changed ({hash_before!r} → {hash_after!r})."
        )

    if _any_treatment_judge_streaming(run_data):
        kill_signals.append("judge_still_streaming")
        reasons.append(
            "Treatment arm still skipped judge due to streaming route."
        )

    if _tool_failure_no_useful_lessons(run_data):
        kill_signals.append("reflection_no_useful_lessons")
        reasons.append(
            "Tool-failure class invoked judge/reflection but no lessons persisted."
        )

    if _token_blowup(run_data):
        kill_signals.append("token_blowup")
        baseline_total = _sum_tokens(run_data, "baseline")
        treatment_total = _sum_tokens(run_data, "treatment")
        reasons.append(
            f"Treatment tokens ({treatment_total}) exceed "
            f"{TOKEN_BLOWUP_THRESHOLD_FACTOR}× baseline ({baseline_total})."
        )

    if _any_unknown_lines(run_data):
        kill_signals.append("unknown_line_drift")
        reasons.append("Unrecognized log lines detected in parser output.")

    if kill_signals:
        decision = "NO-GO"
    else:
        decision = "GO"
        reasons.append("No kill signals detected; canary passed isolation and observability checks.")

    return {
        "decision": decision,
        "kill_signals": kill_signals,
        "reasons": reasons,
    }


def _fmt_bool(value: Any) -> str:
    return "true" if value else "false"


def _sum_metric(run_data: dict, arm: str, key: str) -> int:
    total = 0
    for cls in INPUT_CLASSES:
        total += int(_get_arm_result(run_data, cls, arm).get(key, 0))
    return total


def _merge_counter(run_data: dict, arm: str, key: str) -> dict[str, int]:
    merged: dict[str, int] = {}
    for cls in INPUT_CLASSES:
        counter = _get_arm_result(run_data, cls, arm).get(key, {})
        if not isinstance(counter, dict):
            continue
        for reason, count in counter.items():
            merged[reason] = merged.get(reason, 0) + int(count)
    return merged


def build_report(run_data: dict) -> str:
    """Render aggregated canary results as markdown."""
    metadata = run_data.get("metadata", {})
    isolation = run_data.get("isolation", {})
    inventory = run_data.get("memory_inventory", {})
    evaluation = evaluate_go_no_go(run_data)

    lines: list[str] = []

    lines.append("# NullClaw Self-Improvement Canary Report")
    lines.append("")
    lines.append("## Metadata")
    lines.append("")
    lines.append(f"- **git_sha**: `{metadata.get('git_sha', 'unknown')}`")
    lines.append(f"- **build_mode**: {metadata.get('build_mode', 'unknown')}")
    lines.append(f"- **provider**: {metadata.get('provider', 'unknown')}")
    lines.append(f"- **model**: {metadata.get('model', 'unknown')}")
    lines.append(
        f"- **non_streaming**: {_fmt_bool(metadata.get('non_streaming', False))}"
    )
    lines.append(f"- **scratch_home**: `{metadata.get('scratch_home', '')}`")
    lines.append(
        f"- **scratch_ws_baseline**: `{metadata.get('scratch_ws_baseline', '')}`"
    )
    lines.append(
        f"- **scratch_ws_treatment**: `{metadata.get('scratch_ws_treatment', '')}`"
    )
    lines.append("")

    lines.append("## Isolation")
    lines.append("")
    lines.append(
        f"- **live_db_hash_before**: `{isolation.get('live_db_hash_before', '')}`"
    )
    lines.append(
        f"- **live_db_hash_after**: `{isolation.get('live_db_hash_after', '')}`"
    )
    lines.append(
        "- **response_cache_enabled**: "
        f"{_fmt_bool(isolation.get('response_cache_enabled', False))}"
    )
    lines.append("")

    lines.append("## Per-Class Breakdown")
    lines.append("")
    for cls in INPUT_CLASSES:
        lines.append(f"### {cls}")
        lines.append("")
        for arm in ("baseline", "treatment"):
            result = _get_arm_result(run_data, cls, arm)
            lines.append(f"**{arm}**")
            lines.append(f"- judge_invoked: {result.get('judge_invoked', 0)}")
            lines.append(
                f"- reflection_invoked: {result.get('reflection_invoked', 0)}"
            )
            lines.append(
                f"- estimated_tokens_total: {result.get('estimated_tokens_total', 0)}"
            )
            unknown = result.get("unknown_lines", [])
            if unknown:
                lines.append(f"- unknown_lines: {len(unknown)}")
            lines.append("")

    lines.append("## Judge")
    lines.append("")
    for arm in ("baseline", "treatment"):
        lines.append(f"### {arm}")
        lines.append(f"- judge_invoked: {_sum_metric(run_data, arm, 'judge_invoked')}")
        lines.append(
            f"- judge_decision_continue: "
            f"{_sum_metric(run_data, arm, 'judge_decision_continue')}"
        )
        lines.append(
            f"- judge_stop_goal_achieved: "
            f"{_sum_metric(run_data, arm, 'judge_stop_goal_achieved')}"
        )
        lines.append(
            f"- judge_no_progress_force_fail: "
            f"{_sum_metric(run_data, arm, 'judge_no_progress_force_fail')}"
        )
        skipped = _merge_counter(run_data, arm, "judge_skipped")
        if skipped:
            lines.append(f"- judge_skipped: {skipped}")
        lines.append("")

    lines.append("## Reflection")
    lines.append("")
    for arm in ("baseline", "treatment"):
        lines.append(f"### {arm}")
        lines.append(
            f"- reflection_invoked: "
            f"{_sum_metric(run_data, arm, 'reflection_invoked')}"
        )
        lines.append(
            f"- lesson_saved: {_sum_metric(run_data, arm, 'lesson_saved')}"
        )
        lines.append(
            f"- lesson_recalled: {_sum_metric(run_data, arm, 'lesson_recalled')}"
        )
        rejected = _merge_counter(run_data, arm, "lesson_rejected")
        if rejected:
            lines.append(f"- lesson_rejected: {rejected}")
        lines.append("")

    lines.append("## Memory Inventory")
    lines.append("")
    lines.append(f"- **lesson_count**: {inventory.get('lesson_count', 0)}")
    sessions = inventory.get("sessions", [])
    if sessions:
        lines.append(f"- **sessions**: {', '.join(str(s) for s in sessions)}")
    else:
        lines.append("- **sessions**: (none)")
    lines.append("")
    lessons = inventory.get("lessons", [])
    if lessons:
        lines.append("| key | utility_score | utility_score_source | excerpt |")
        lines.append("| --- | ---: | --- | --- |")
        for lesson in lessons:
            lines.append(
                f"| `{lesson.get('key', '')}` "
                f"| {lesson.get('utility_score', 0)} "
                f"| {lesson.get('utility_score_source', '')} "
                f"| {lesson.get('excerpt', '')} |"
            )
    else:
        lines.append("(no lessons)")
    lines.append("")

    baseline_tokens = _sum_tokens(run_data, "baseline")
    treatment_tokens = _sum_tokens(run_data, "treatment")
    lines.append("## Cost / Latency")
    lines.append("")
    lines.append(f"- **estimated_tokens (baseline)**: {baseline_tokens}")
    lines.append(f"- **estimated_tokens (treatment)**: {treatment_tokens}")
    if baseline_tokens > 0:
        ratio = treatment_tokens / baseline_tokens
        lines.append(f"- **token_ratio**: {ratio:.2f}")
    lines.append("")

    lines.append("## GO/NO-GO")
    lines.append("")
    lines.append(f"**Decision**: {evaluation['decision']}")
    lines.append("")
    kill_signals = evaluation.get("kill_signals", [])
    if kill_signals:
        lines.append("**Kill signals**:")
        for signal in kill_signals:
            lines.append(f"- `{signal}`")
    else:
        lines.append("**Kill signals**: (none)")
    lines.append("")
    eval_reasons = evaluation.get("reasons", [])
    if eval_reasons:
        lines.append("**Reasons**:")
        for reason in eval_reasons:
            lines.append(f"- {reason}")
    lines.append("")

    return "\n".join(lines)