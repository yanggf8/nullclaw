# Self-Improvement Loop Observability (evaluation-hardening slice)

**Date:** 2026-07-05
**Status:** design corroborated (Codex, 2 rounds) — ready for plan

## Purpose

nullclaw has two shipped-but-dormant self-improvement loops, both default OFF:
- **Judge-gated continuation loop** (`agent.judge_after_turn`) — a per-turn "done?" LLM judge that decides continue-vs-stop.
- **After-turn reflection/lesson loop** (`agent.reflect_after_turn`) — after a turn, an LLM produces a `{worth_saving, lesson, failure_class}` verdict; passing lessons are stored (category `lesson`) and recalled into future turns via a dedicated memory tier; `utility_score` weights recall ranking.

Both are fully implemented and tested but have **never run with the flags on**, so their real-world value is unproven. Before deciding whether to enable them (Codex: enabling+evaluating is a prerequisite gate for building more self-improvement machinery), we must be able to **measure** them. Today we cannot: both loops run silently, their counters are test-only, their extra LLM tokens bypass accounting, and `utility_score` is not exposed. This slice builds that measurement layer.

Non-goal: this slice does NOT enable the loops, tune defaults, or run the canary. It only makes them observable. It also does not build the canary harness or workload-class tagging (external, later).

## Constraints

Zig 0.16.0 runtime. Binary-size / ~1MB RSS discipline. Deterministic, 0-leak tests. Vtable-driven with a strict provider boundary — minimize blast radius, especially at the provider vtable. Log scalars only; never log prompts, final answers, lesson text, or memory content (privacy). Estimated cost must never corrupt the existing accurate cost figures.

## Architecture

Primary surface: **structured `std.log`** (greppable from `journalctl --user -u nullclaw`), mirroring the `.outbound_dispatch` scoped-log pattern in `src/channels/dispatch.zig:12`. Two new scoped domains: **`.agent_judge`** and **`.agent_reflection`**. No new `observability.zig` union variants, no storage schema, no provider vtable change.

Three targets → **three independent commits**, each through the TDD pipeline:

### Commit 1 — Decision logging (`.agent_judge` / `.agent_reflection`)

Add scalar-only scoped log lines at every currently-silent decision point. Fields: reason enums, counts, `model`, estimated tokens, `duration_ms`, booleans, outcome. **Never** prompt/answer/lesson/memory text.

Sites (all in `src/agent/root.zig` unless noted):
- Judge fires; `verdict.goal_achieved` true/false (~2917–2949)
- Judge decides CONTINUE (`judge_continue_count += 1`, ~2937) vs STOP / force-logic-fail (~2941/2943/2948)
- Judge **skipped because streaming** (`judgeEnabledForCandidate`, ~2069)
- Judge **ineligible** — continuation cap / loop budget (`canJudgeContinueCandidate`, ~2073)
- Judge verdict **null** — provider/parse failure (`reflectOnTurnForJudge`, ~2096)
- Candidate **no-progress force-fail** (~2931)
- After-turn reflection **invoked** (`finishTurnReflection`, ~2041)
- After-turn reflection **skipped** — disabled / no learning signal (~2042/2046)
- Lesson **saved** (`reflection_lessons_saved += 1`, ~2027)
- Lesson **rejected** — quality-gate fail / per-session cap / sanitize null (~2018–2021)
- Lesson **not saved** — `mem == null` / key-alloc / store failure (~2021–2028)
- Success attribution **applied vs withheld** (`recordSuccess`, ~2035–2037)
- Lesson **recalled** — lesson tier / `recordRecall` (`memory_loader.zig` ~210)

Also log `duration_ms` measured around each loop `chatWithSystem` call (see Commit 2), with `kind=judge|reflection`, `model`, `estimated_tokens`, outcome.

### Commit 2 — Estimated token/cost + latency accounting

The judge/reflection LLM calls go through `provider.chatWithSystem` (returns text only, no usage), so their tokens are unaccounted. Estimate them; keep estimates **strictly separate** from real turn cost.

- Two new `Agent` fields: `reflection_estimated_tokens: usize`, `reflection_estimated_cost_usd: f64`.
- Estimate `prompt_tokens = estimate_text_tokens(prompt)` + `completion_tokens = estimate_text_tokens(full_response)` (the FULL returned text, not the `MAX_RESPONSE_BYTES`-capped parse slice). Cost via `TokenUsage.fromProviders(model, usage).cost()`.
- **ESTIMATE-ON = chat success (DECIDED).** Estimate whenever `chatWithSystem` RETURNS text — even if the JSON then fails to parse (verdict null). The provider consumed/billed those tokens regardless of parse outcome, so the canary's cost answer must include them; counting only parsed calls would under-report real cost and understate the loop's expense. Only a FAILED chat call (returns an error, no text) skips estimation. Test both: chat-fail → no advance; chat-ok-but-bad-JSON → estimate DOES advance, verdict is null.
- **All accounting lives at the `Agent` boundary in `root.zig`.** `reflection.reflectOnTurn()` has no `Agent` receiver and `reflection.zig` cannot cleanly import `estimate_text_tokens` from `root.zig` (root already imports reflection — circular; and `compaction.zig` also imports root, so reflection can't route through it either). **Resolution (Option B, corroborated):** leave `reflection.reflectOnTurn()` UNCHANGED; move the after-turn provider call up into `finishTurnReflection()` in `root.zig` via a new root-side helper `runReflectionLlmCall(arena, model, prompt)` returning `ReflectionLlmCallResult { verdict, est_prompt_tokens, est_completion_tokens, duration_ms }`. `reflectOnTurnForJudge` also returns this struct. Both fold estimates into the Agent counters via `recordReflectionEstimate`. (Earlier draft said "reflectOnTurn returns a struct" — that is wrong; reflectOnTurn stays as-is, accounting is done in root.)
- **RESET SEMANTICS (required):** `reflection_estimated_tokens` / `reflection_estimated_cost_usd` are PER-TURN — reset to 0 at turn entry (the `root.zig:2181` block that already zeroes `judge_continue_count`), then `+=` per loop LLM call within the turn (including multiple judge continuations). A canary needs per-turn overhead deltas; cumulative-without-reset makes turn-N include prior turns. `reflection_turn_invocations` stays cumulative (session diagnostic); it is NOT the token counter.
- **Never** touch `total_tokens`, `total_cost_usd`, `last_turn_usage`, or the `tokens_used` observer metric. No double-count: finalization picks judge OR after-turn reflection (`root.zig:3002`), never both; judge continuations count per-call (correct).
- Measure `duration_ms` around each `chatWithSystem` call; return it in the struct for logging (Commit 1 consumes it).

### Commit 3 — `utility_score` exposure in `memory` CLI

- `memory search --json`: surface the **existing** `RetrievalCandidate.utility_score` (`engine.zig:84`), currently omitted from JSON (`main.zig:3625`). No extra queries.
- `memory get` / `memory list`: print `utility_score` via `Memory.fetchUtilityScore` (`memory/root.zig:554`), **explicitly labeled** as sqlite-derived / neutral-fallback because it returns a neutral `0.5` on non-sqlite backends (`memory/root.zig:552`). Per-entry fetch = N queries; acceptable for small CLI limits, documented.
- **Out of scope (documented follow-up):** raw recall/success counts. Only the smoothed score is exposed by the vtable; true hit-rate would need a new getter. Note in the spec; do not build here.

## Testing

Every commit ships RED tests first, then implementation (TDD pipeline). Existing ~40 agent tests must stay green; the key invariant that protects them: estimated counters stay OUT of `total_tokens`/`total_cost_usd`/`last_turn_usage`/`tokens_used`.

- **Commit 1:** logs are hard to assert directly (no log-capture helper in repo). Test the *decision state* instead: assert the counters/branch outcomes that the logs describe (e.g. judge-skipped-when-streaming already has a test at `root.zig:12409` — extend to assert the skip path; lesson-rejected path sets no `reflection_lessons_saved` increment). Where a branch has no observable state, add a minimal state hook (e.g. a `usize` counter) rather than asserting log text. Enumerate per-site: does it have observable state, or does it need a counter to be testable?
- **Commit 2:** RED tests: (a) after a reflection call with flags on, `reflection_estimated_tokens > 0` and `reflection_estimated_cost_usd > 0`; (b) `total_tokens`/`total_cost_usd`/`last_turn_usage` are UNCHANGED by the reflection call (the separation invariant — this is the load-bearing test); (c) a failed `chatWithSystem` does not advance the estimate; (d) judge-path and after-turn-path each count once; both-in-one-turn is impossible (assert finalization picks one). Use the existing reflection mock provider (`reflection.zig:181 ReflectionMockProvider`) for determinism.
- **Commit 3:** RED tests: (a) `memory search --json` includes a `utility_score` field; (b) `memory get`/`list` output includes utility_score labeled as sqlite-derived; (c) on a non-sqlite backend the value is the neutral fallback and is labeled as such (no misleading precision). Use existing memory CLI test patterns.

Validation per commit: `zig build test -Dchannels=cli -Dengines=base,sqlite --summary all --test-timeout 60s` (needs sqlite for utility_score); full `zig build test --summary all` before merge. Known-ignored: signal-channel WSL2 timeout.

## Rollout

Three commits on one branch (crash-fix precedent). Each: RED tests → implement → verify GREEN + 0 leaks → review diff. Full suite before merge. Nothing enables the loops — that's the canary, a separate follow-up once this lands.
