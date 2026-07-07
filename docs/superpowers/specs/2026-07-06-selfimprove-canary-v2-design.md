# Self-Improvement Canary v2 — objective save-then-recall metric

**Date:** 2026-07-06
**Status:** design corroborated (Codex ×2, source-checked) — ready for plan
**Supersedes the metric design in:** `2026-07-06-selfimprove-canary-zig-design.md` (the canary itself stays; only the comparison metric changes). Modifies `src/canary.zig` + a small `src/agent/root.zig` snapshot addition.

## Why v1's metric was invalid

v1 compared the loops' INTERNAL counters (`reflection_estimated_tokens`) between arms. Baseline has the loops OFF, so its reflection tokens are always 0 — the comparison measures "did the loop run," not "did it help." The v1 LLM verdict flagged this itself: "the baseline isn't a working control, it's an inert placeholder." A naive alternative — pre-seed a lesson and check the answer contains it — is ALSO invalid: Codex confirmed memory recall (`enrichMessageWithRuntime`, root.zig:2489) is NOT gated by the loop flags, so both arms would recall a pre-seeded lesson equally. Both measure recall-in-general or loop-ran, not loop-impact.

## What v2 measures — the closed loop, mechanically

The loops' actual job: `reflect_after_turn` SAVES a lesson after a learning-signal turn; that lesson is RECALLED on a later turn. v2 measures that closed loop directly, per arm, on the same Agent + scratch memory + session:

- **Turn A** — a prompt that induces a tool failure (via the existing `CanaryFailTool`), a learning signal. Read `reflection_lessons_saved` before and after: `turn_a_saved = (after > before)`. Treatment (`reflect_after_turn` on) saves a `lesson:{hash}` (root.zig:2087/2089); baseline (flag off) reflection is skipped (root.zig:2115) → saves nothing. `reflection_lessons_saved` is an Agent-lifetime counter (root.zig:4327), so the delta is the right read.
- **Turn B** — a memory-dependent prompt, same agent/session. After the turn, read the agent's `last_recalled_top_key` (set from `topRecalledKey` after memory enrichment, root.zig:2495-2497): `turn_b_recalled_lesson = (key != null AND std.mem.startsWith(key, "lesson:"))`. The `lesson:` prefix is the reliable discriminator (root.zig:2087 stores lessons as `lesson:{hash}`; memory_loader.zig:70 treats `lesson:` keys as lessons). Treatment recalls the lesson it saved; baseline has none, so `key == null` (or not a lesson).

**Shared objective outcome** `loop_closed: bool = turn_a_saved AND turn_b_recalled_lesson`. Treatment should be true, baseline false — a valid, mechanical pass/fail caused by the loop, with NO dependence on the LLM echoing a marker (the rejected marker-in-answer approach depended on two model-compliance hopes: reflection preserving the token, then Turn B echoing it).

**RELIABILITY (corroboration #4 — the make-or-break):** there is NO source guarantee that a tool-failure Turn A saves a lesson — reflection may legitimately return `worth_saving=false` (root.zig:2073/2074), or the sanitized lesson may fail `lessonPassesQualityGate` (reflection.zig:108). So `turn_a_saved=false` does NOT mean the machinery is broken; it means "no lesson worth saving this run." The verdict MUST split these:
- `turn_a_saved == false` (treatment) → report as `reflection_no_save` / `induce_did_not_produce_lesson` — an inconclusive/flaky-induce signal, NOT `loop_never_closed`.
- `turn_a_saved == true AND turn_b_recalled_lesson == false` (treatment) → THAT is the real save→recall machinery failure → `loop_never_closed`.
De-risk the induce: engineer Turn A's prompt so reflection is very likely to return a durable `worth_saving` lesson (concrete, specific tool-boundary lesson), but treat this as probabilistic, not guaranteed. Corroborate `turn_a_saved` with `memory.list(.custom="lesson")` after Turn A (the canary already lists lesson entries, canary.zig:285) — belt-and-suspenders with the `reflection_lessons_saved` delta.
**Also required:** REMOVE the current pre-seed of `"canary-topic"` for the memory-dependent case (canary.zig:243) — with a pre-seeded lesson, BASELINE would also have a lesson to recall, invalidating the control. The primary closed-loop case must start with an EMPTY scratch memory so only treatment's Turn-A-saved lesson exists.

The `reflection_estimated_tokens` / `lessons_saved` counters remain — as DIAGNOSTICS (did the loop fire, what did it cost), not the comparison axis.

## Enabling change (small, in agent)

`last_recalled_top_key` is currently private on Agent; the `reflectionMetrics()` snapshot does not expose it (root.zig:4331 — only token/save/judge counters). v2 adds a recall signal to the snapshot: extend `ReflectionMetrics` with `recalled_lesson: bool` (computed as `last_recalled_top_key != null and startsWith(key, "lesson:")`), OR add a sibling accessor `pub fn lastRecalledLessonKey(self) ?[]const u8`. Prefer adding `recalled_lesson: bool` to the snapshot struct — same narrow-read pattern as the original `reflectionMetrics()` addition. This is the only production-code change outside canary.zig.

## Arm structure (src/canary.zig)

`runCanaryArm` runs TWO turns instead of one (Codex confirmed feasible on the same fresh-per-arm Agent/rt — just run both before collecting metrics):
- capture `lessons_saved` before Turn A;
- Turn A (induce prompt) → capture `lessons_saved` after → `turn_a_saved`;
- Turn B (recall prompt) → read snapshot `recalled_lesson` → `turn_b_recalled_lesson`;
- `loop_closed = turn_a_saved and turn_b_recalled_lesson`.

New `ArmMetrics` fields: `turn_a_saved: bool`, `turn_b_recalled_lesson: bool`, `loop_closed: bool`. Existing token/duration counters stay as diagnostics. Scope: the memory-dependent case is the one with a valid closed loop; tool-failure and simple-QA cases become diagnostic-only (they show "did the loop fire / cost", no outcome comparison — they have no shared checkable outcome). Keep them for cost/latency diagnostics or drop to just the memory-dependent case (YAGNI — the plan decides; leaning: keep one diagnostic non-memory case for cost context).

## Verdict & kill signals

Primary axis = `loop_closed` per arm. Rewritten kill signals (corroboration #4/#5 applied):
- `reflection_no_save` (inconclusive, NOT a hard NO-GO): treatment `turn_a_saved == false` — the induce turn didn't produce a saveable lesson this run (reflection said not-worth-saving or quality-gate rejected). Signals a flaky/weak induce prompt, not broken machinery. Re-run or strengthen the induce.
- `loop_never_closed` (hard NO-GO): treatment `turn_a_saved == true AND turn_b_recalled_lesson == false` — a lesson WAS saved but Turn B failed to recall it. THIS is the real save→recall machinery failure.
- `no_arm_difference`: treatment and baseline have the SAME `loop_closed` (both true or both false) — the loop makes no observable difference.
- `token_blowup` (diagnostic): compares total loop cost treatment vs baseline > factor. Total cost per arm = `last_turn_usage` (main-turn tokens, root.zig:390) ACCUMULATED across Turn A + Turn B PLUS `reflection_estimated_tokens` (the loop's extra calls — root.zig:2036/2060, which are NOT in last_turn_usage). last_turn_usage after Turn B is only the most recent turn, so the impl must SUM Turn A + Turn B main-turn usage into ArmMetrics. Baseline reflection_estimated_tokens is 0 (loops off), so this compares real added cost — a valid diagnostic, unlike v1's reflection-token-vs-0-as-primary.
Drop v1's `judge_never_fired` / `no_useful_lessons` as PRIMARY signals (counter-based proxies); keep as diagnostics in the summary.

The LLM verdict (`provider.chatWithSystem`, now working after the 20a2206a escaping fix) still writes the natural-language GO/NO-GO — now fed the `loop_closed` outcomes + diagnostics, so it reasons from a VALID comparison. buildMetricsSummary renders the new outcome fields.

## Testing (zig build test — all pure/offline; live turns stay builtin.is_test-guarded)

- Snapshot: `reflectionMetrics().recalled_lesson` reflects `last_recalled_top_key` (unit test on a test Agent, like the existing reflectionMetrics test; set last_recalled_top_key to a `lesson:x` key → recalled_lesson true; to a non-lesson key → false; to null → false).
- `loop_closed` + kill signals: table-driven pure test over synthetic ArmMetrics (turn_a_saved × turn_b_recalled_lesson combos, treatment vs baseline) → assert loop_closed, loop_never_closed, no_arm_difference, token_blowup.
- `buildMetricsSummary` renders turn_a_saved / turn_b_recalled_lesson / loop_closed (substring test).
- Existing canary isolation + kill-signal tests updated for the new fields (not weakened).

## Rollout

Modification of src/canary.zig + the ReflectionMetrics.recalled_lesson addition in root.zig, through the pipeline (Codex corroborates, Grok codes, Claude reviews each diff). After it lands + a full-suite pass, a live re-run (gated, spends tokens) validates whether treatment closes the loop and baseline doesn't — the first VALID canary read. Optional deferred: an LLM-judge pairwise answer-quality secondary signal (not in v2 scope — YAGNI until the objective read is trusted). Also still open (separate): vertex.zig same escaping bug; pace turns (transient provider_error).

## Live-run fix (2026-07-07) — treatment must be REFLECT-ONLY (judge OFF)

The first live v2 run (merged 211b83da) reported turn_a_saved=false everywhere DESPITE stderr showing `lesson saved lessons_saved=1`. Codex root-caused it (two rounds): the treatment arm had BOTH judge_after_turn AND reflect_after_turn on, and the JUDGE path makes the lesson-save time UNPREDICTABLE. When the judge returns goal_achieved=false and continues, that verdict is NOT saved (root.zig:3027-3039); only the final candidate's verdict is applied, and a forced-logic-failure finalization has worth_saving=false → no save (root.zig:2249-2256). So with judge on, the lesson may not be saved during Turn A at all (it gets deferred to a later turn when the judge finally accepts) → the post-Turn-A probe correctly sees turn_a_saved=false, but a lesson IS saved later. The loop WORKS; the judge just defers WHEN.

**FIX (design change): the save/recall canary treatment arm must be REFLECT-ONLY — reflect_after_turn=true, judge_after_turn=FALSE.** With judge disabled, finalization calls finishTurnReflection() synchronously before turn() returns (root.zig:3120-3121, 3147), the tool failure sets turn_tool_failure_seen (root.zig:1989, 2124), so Turn A reliably saves a lesson and the post-A probe sees it. This isolates the reflection save→recall loop (what this canary is FOR) from the judge's completion gating. The judge's continuation behavior should be a SEPARATE canary, not mixed into the save/recall measurement.

Concretely in runCanaryArm: treatment sets cfg.agent.reflect_after_turn = true and cfg.agent.judge_after_turn = FALSE (not both). baseline keeps both off. Everything else (two-turn A-induce/B-recall, turn_a_saved from post-A counter delta + lesson list, turn_b_recalled_lesson from post-B recalled_lesson, loop_closed) stays as-is. This is the only change needed; the metric structure was correct — the arm just used the wrong flag combination.

**SECOND FIX (corroboration found):** buildMetricsSummary's "Total baseline/treatment tokens" line only sums reflection_estimated_tokens (canary.zig ~143), but the token_blowup kill signal correctly sums main_turn_tokens + reflection_estimated_tokens (canary.zig ~105). So the summary total fed to the LLM verdict uses a DIFFERENT basis than token_blowup → misleads the verdict (explains the live run's "Total treatment tokens: 1867" not matching the per-scenario main_turn_tokens). FIX: make the summary total = main_turn_tokens + reflection_estimated_tokens per arm, same basis as token_blowup.

So the fix is TWO small changes in src/canary.zig: (1) treatment reflect-only (judge_after_turn=false), (2) summary total-tokens basis. No metric-window change needed (Codex confirmed post-A sampling is correctly timed once judge is off). No root.zig change.

(Deferred/separate: a judge-behavior canary; the vertex.zig escaping bug; pace turns. Also note the simple_qa main_turn_tokens=10033 anomaly from the live run — worth a look but not blocking.)
