"""Parse nullclaw agent stderr for agent_reflection / agent_judge events."""

from __future__ import annotations

import re
from typing import Any

_ANSI_SGR = re.compile(r"\x1b\[[0-9;]*m")
_ANSI_OSC = re.compile(r"\x1b\].*?(?:\x07|\x1b\\)")
_LOG_ENVELOPE = re.compile(
    r"(debug|info|warning|error)\((agent_reflection|agent_judge)\):\s*(?P<msg>.*)$"
)
_KV_TOKEN = re.compile(r"(\w+)=(\S+)")


def _strip_ansi(line: str) -> str:
    line = _ANSI_OSC.sub("", line)
    line = _ANSI_SGR.sub("", line)
    return line


def _parse_kv_tokens(text: str) -> dict[str, Any]:
    fields: dict[str, Any] = {}
    for match in _KV_TOKEN.finditer(text):
        key, raw = match.group(1), match.group(2)
        if raw == "true":
            fields[key] = True
        elif raw == "false":
            fields[key] = False
        else:
            try:
                fields[key] = int(raw)
            except ValueError:
                fields[key] = raw
    return fields


def _inc(counter: dict[str, int], key: str) -> None:
    counter[key] = counter.get(key, 0) + 1


def _empty_result() -> dict[str, Any]:
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


def _add_tokens(result: dict[str, Any], fields: dict[str, Any]) -> None:
    if "estimated_tokens" in fields:
        result["estimated_tokens_total"] += int(fields["estimated_tokens"])


def _dispatch_event(result: dict[str, Any], scope: str, msg: str) -> None:
    fields = _parse_kv_tokens(msg)

    if scope == "agent_reflection":
        if msg.startswith("reflection invoked"):
            result["reflection_invoked"] += 1
            _add_tokens(result, fields)
            return
        if msg.startswith("lesson quality gate rejected"):
            _inc(result["lesson_rejected"], "quality_gate")
            return
        if msg.startswith("lesson sanitize failed"):
            _inc(result["lesson_rejected"], "sanitize_failed")
            return
        if msg.startswith("lesson session cap rejected"):
            _inc(result["lesson_rejected"], "session_cap")
            return
        if msg.startswith("lesson not saved memory absent"):
            _inc(result["lesson_rejected"], "memory_absent")
            return
        if msg.startswith("lesson store failed"):
            _inc(result["lesson_rejected"], "store_failed")
            return
        if msg.startswith("lesson key alloc failed"):
            _inc(result["lesson_rejected"], "key_alloc_failed")
            return
        if msg.startswith("lesson saved"):
            result["lesson_saved"] += 1
            return
        if msg.startswith("success attribution applied"):
            result["success_attribution_applied"] += 1
            return
        if msg.startswith("success attribution withheld"):
            reason = fields.get("reason", "unknown")
            _inc(result["success_attribution_withheld"], str(reason))
            return
        if msg.startswith("reflection skipped"):
            reason = fields.get("reason", "unknown")
            _inc(result["reflection_skipped"], str(reason))
            return
        if msg.startswith("reflection verdict null"):
            reason = fields.get("reason", "unknown")
            _inc(result["reflection_verdict_null"], str(reason))
            _add_tokens(result, fields)
            return
        if msg.startswith("lesson recalled"):
            result["lesson_recalled"] += 1
            detail = dict(fields)
            if "session_scoped" in detail:
                detail["session_scoped"] = bool(detail["session_scoped"])
            result["lesson_recalled_details"].append(detail)
            return

    if scope == "agent_judge":
        if msg.startswith("judge invoked"):
            result["judge_invoked"] += 1
            _add_tokens(result, fields)
            return
        if msg.startswith("judge decision continue"):
            result["judge_decision_continue"] += 1
            return
        if msg.startswith("judge stop goal achieved"):
            result["judge_stop_goal_achieved"] += 1
            return
        if msg.startswith("judge no progress force fail"):
            result["judge_no_progress_force_fail"] += 1
            return
        if msg.startswith("judge verdict null"):
            reason = fields.get("reason", "unknown")
            _inc(result["judge_verdict_null"], str(reason))
            return
        if msg.startswith("judge ineligible"):
            reason = fields.get("reason", "unknown")
            _inc(result["judge_ineligible"], str(reason))
            return
        if msg.startswith("judge skipped"):
            reason = fields.get("reason", "unknown")
            _inc(result["judge_skipped"], str(reason))
            return

    result["unknown_lines"].append(msg)


def parse_log(text: str) -> dict[str, Any]:
    """Parse captured stderr and extract agent_reflection / agent_judge events."""
    result = _empty_result()

    for raw_line in text.splitlines():
        line = _strip_ansi(raw_line)
        match = _LOG_ENVELOPE.search(line)
        if match is None:
            continue
        scope = match.group(2)
        msg = match.group("msg").strip()
        _dispatch_event(result, scope, msg)

    return result