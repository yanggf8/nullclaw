# Self-Improvement Canary v3 — instructive induce + deterministic save/recall tests

**Date:** 2026-07-07
**Status:** design corroborated (Codex, source-checked) — ready for plan
**Builds on:** canary v2 (merged 8a4a67ff). The v2 metric structure (two-turn save-then-recall, reflect-only treatment, loop_closed = turn_a_saved AND turn_b_recalled_lesson) is CORRECT and stays. v3 fixes WHY turn_a_saved is reliably false: the induce signal is too weak/artificial for the reflection model to judge worth_saving=true, and adds deterministic CI coverage of the save/recall halves.

## The problem v3 fixes

Live v2 runs show turn_a_saved=false because the reflection model returns worth_saving=FALSE — stderr proves reflection RUNS (reflection invoked, ~316 tokens) but no lesson is saved and nothing is rejected by the quality gate. Codex root-caused it:
- `canary_fail` is a content-free always-failing tool ("canary_fail forced failure", canary.zig:199). It proves a tool failed, NOT that future behavior should change → not a "lesson worth remembering."
- The agent's stated lesson doesn't reliably reach reflection: buildReflectionPrompt (reflection.zig:130-151) only gives the model user_goal + compact tool summaries + a 256-byte-truncated Short outcome. The lesson only reaches reflection if it's early in the final answer.
So worth_saving=false is the reflection MODEL's legitimate judgment of a weak signal — NOT a broken save path. We must NOT force worth_saving=true (that distorts the canary — the loop intentionally delegates "worth remembering?" to the model). Instead: give an HONEST, strong learning signal the model naturally judges worth saving.

## Three parts

### Part 1 — Instructive-failure induce tool (make worth_saving=true fire honestly)

Replace the content-free `canary_fail` with a tool whose failure teaches a concrete, generalizable rule. It fails (still a learning signal / turn_tool_failure_seen) but with an INSTRUCTIVE error message, e.g.:
"permission denied: the canary-topic task cannot use this tool; it requires answering directly from the learned rule. Do not retry this tool for canary-topic — remember: canary-topic follow-ups must be answered directly, not via the tool."
This is a real tool-contract lesson (the agent learns a boundary), which the reflection model is far more likely to judge worth_saving=true and produce a durable, generalizable lesson that passes lessonPassesQualityGate (reflection.zig:108). The tool still returns ToolResult.fail (so turn_tool_failure_seen is set, root.zig:1989).

### Part 2 — Induce prompt: force a compact final answer carrying the lesson

Turn A induce prompt asks the agent to, after the tool fails, answer in ONE SHORT SENTENCE stating the learned rule. Because Short outcome is truncated to 256 bytes (reflection.zig:145), a one-sentence lesson-carrying final answer makes the lesson visible to the reflection judge without gaming the JSON. This is support, not the core mechanism (the instructive tool error is the primary signal).

### Part 3 — Deterministic save + recall unit/integration tests (pull reliability into CI)

The live canary is inherently probabilistic (depends on the model's worth_saving judgment). Add DETERMINISTIC tests so the save and recall halves are proven in CI regardless of the model:
- **Save-plumbing test:** call applyReflectionVerdict with a synthetic verdict worth_saving=true + a quality-gate-passing lesson on a test Agent with a scratch memory; assert reflection_lessons_saved incremented AND a lesson: entry exists in memory. (applyReflectionVerdict is already unit-tested — root.zig:12164; extend/mirror that pattern.) This proves: given a worth_saving verdict, the save works.
- **Recall test:** seed a lesson: entry directly into a scratch memory, run a turn (or call the enrichment path), assert reflectionMetrics().recalled_lesson == true (top recalled key starts with "lesson:"). memory enrichment/topRecalledKey (memory_loader.zig:332/434). This proves: given a saved lesson, recall works.
These are pure/deterministic (may need a test provider for the turn, or test the enrichment path directly), run in CI, and isolate "does the plumbing work" (deterministic) from "does the model save a strong-enough signal" (probabilistic live).

## Stance (do NOT game worth_saving)

The canary must remain honest: reflection_no_save is a VALID outcome when the model declines to save. v3 does not force a save — it provides a strong, honest signal (instructive tool failure) that the model will naturally judge worth saving, so the live end-to-end loop can actually be exercised. The deterministic tests cover the plumbing; the live run proves the full model-mediated loop only when the signal is strong enough. If the model STILL declines on a genuinely instructive failure, reflection_no_save is reported honestly.

## Scope / files

- src/canary.zig: instructive-failure tool (replace CanaryFailTool's error + possibly rename), induce prompt one-sentence-answer, plus the two deterministic tests. Recall test may live in canary.zig or root.zig depending on which enrichment path is cleanest.
- No metric-structure change (v2's two-turn/loop_closed/kill-signals stay). No root.zig production change expected (reuse applyReflectionVerdict/reflectionMetrics as-is); if the save/recall tests need a small test hook, keep it minimal and test-only.

## Testing & rollout

- Deterministic save + recall tests (pure/CI): the load-bearing new coverage.
- Existing canary tests unchanged/green.
- Validation per commit: zig build test -Dchannels=none -Dengines=base,sqlite --summary all --test-timeout 60s; full zig build test --summary all before merge.
- After merge: a live re-run (gated, spends tokens) to see if the instructive induce now produces turn_a_saved=true → loop_closed=true on treatment (baseline false) — the first POSITIVE canary read. Through the pipeline (Codex corroborates plan, Grok codes, Claude reviews each diff).

Deferred/separate (unchanged): LLM-verdict prose over-reads reflection_no_save as "broken" — tighten the verdict prompt; vertex.zig same escaping bug; pace turns; simple_qa 9960-token anomaly.
