# Self-Improvement Canary — Phase 1 (offline replay, isolated)

**Date:** 2026-07-06
**Status:** design corroborated (Codex, source-checked — 6 defects found and folded in) — ready for plan

## Purpose

The two self-improvement loops (`judge_after_turn`, `reflect_after_turn`) are shipped but dormant (default OFF) and have never run with the flags on. The 2026-07-05 observability slice made them measurable. This canary answers one question empirically: **does enabling the loops improve outcomes, or just cost tokens/latency?** — WITHOUT risking the live gateway (real cron + Telegram traffic).

Non-goal: this does NOT enable the loops on the gateway, does not tune defaults, does not build new product features. It is an offline measurement harness plus a report. Phase 2 (time-boxed gateway enable on real traffic) is explicitly OUT OF SCOPE here and gated on user approval after reading the Phase-1 report.

## Corroboration-driven constraints (why the naive design fails)

Codex source-checked the first draft and found these (all verified against main @ f08baeb7). The design below incorporates every fix:

1. **Judge is disabled on streaming turns.** `nullclaw agent invoke` wraps the CLI, which sets `stream_callback` for streaming-capable providers → `isStreamingTurn()` true (`root.zig:2151`) → judge skipped (`root.zig:2155`, `3054`); streaming also passes `tools = null` (`root.zig:2595`). **FIX: the canary MUST force a non-streaming path** (disable streaming / use a non-streaming provider) or the judge produces near-total false negatives.
2. **Reflection only fires on a learning signal** — tool failure, exhausted loop, or a recalled key present (`root.zig:2107`). Successful-tool turns produce NO signal (`turn_tool_failure_seen` set only on `ok == false`, `root.zig:1977`). **FIX: canary inputs must be chosen/engineered to produce learning signals** (turns that had tool failures, or memory-dependent turns with a prior recalled lesson).
3. **`--workspace` isolates memory ONLY for local sqlite.** Redis/Postgres/API/ClickHouse ignore workspace_dir (`memory/engines/registry.zig:99-126`) and would touch shared/real stores. **FIX: Phase 1 REQUIRES a local sqlite (or hybrid) backend for the scratch workspace; assert/override the backend, never assume.**
4. **Estimate is log-only + approximate.** `agent invoke --json` returns only `session`/`response`/`turn_count` (`main.zig:520-525`); `reflection_estimated_*` surface only in debug logs (`root.zig:2137`, `3013`). Token count is `compaction.estimateTokens` against a hardcoded price table (`cost.zig:56`). **FIX: treat token/cost as APPROXIMATE log-derived telemetry, never "exact cost"; parse from logs.**
5. **Response cache can short-circuit baseline turns before reflection** (`root.zig:2513`); non-streaming judge bypasses cache. **FIX: control the cache** (disable response cache in the scratch config) so baseline vs treatment latency/token deltas aren't cache-contaminated.
6. **Lessons are session-scoped and skip vector sync.** Stored with `memory_session_id` (`root.zig:2081`); CLI sets it from `--session` (`cli.zig:763`); reflection store does NOT call `syncVectorAfterStore`. **FIX: the closed-loop (A saves lesson → B recalls it) test must reuse the SAME `--session`; rely on keyword/FTS recall, not vector.**

Also noted (not blocking, but the report must state): `reflect_model` does NOT create a separate provider route — reflection uses the current provider (`root.zig:2044`); utility_score is a delayed outcome proxy, not an immediate answer-quality metric.

## Plan-corroboration corrections (Codex, source-checked — 2 HARD contradictions in the draft above)

7. **There is NO `agent invoke --no-stream` flag.** "Disable streaming" is not achievable via a CLI flag. Non-streaming MUST come from a NON-STREAMING PROVIDER ROUTE: a compatible provider with `api_mode:"responses"` (`compatible.zig:1295`, `factory.zig:468`) makes `supportsStreaming()` false, or a built-in like `glm`/`zai` (`factory.zig:106/463`). TRAP: `max_streaming_prompt_bytes=0` does NOT work — the turn is classified as streaming before that fallback, so the judge stays skipped. The scratch config MUST select a non-streaming provider/model route.
8. **`agent invoke --json` swallows the child's stderr on success** (`main.zig:699-730`) — so `.agent_judge`/`.agent_reflection` logs are NOT capturable through the `invoke` wrapper. The harness MUST call the child form directly: `nullclaw agent -m <msg> -s <session> --workspace <scratch>` and capture stderr per arm. (Same underlying turn, just no JSON wrapper.)
9. **Debug build required.** The target logs are `debug`-level; a `ReleaseSmall` binary won't emit them. The canary must run against a `zig build` (Debug) binary, not the deployed ReleaseSmall gateway binary.
10. **Scratch config via `NULLCLAW_HOME`** (`config_paths.zig:15`) — generate `/tmp/nullclaw-canary-*/home/config.json` and run with `NULLCLAW_HOME=<scratch-home>`; never edit `~/.nullclaw/config.json`. Combine with `NULLCLAW_WORKSPACE`/`--workspace` for the scratch memory.db.

These supersede any "disable streaming / capture invoke logs" wording in the Architecture section below — read Architecture with corrections 7-10 applied: the invoke command is the child `agent -m` form, streaming is avoided by provider choice, and the config is a NULLCLAW_HOME scratch.

## Architecture

Codex's better Phase-1 shape (adopted): **offline replay of sampled real sessions**, not synthetic-only. Real traffic shape, zero gateway risk.

Components:
- **`scripts/canary/run.sh`** (or a small Zig/py driver) — orchestrates the whole run. No production-code changes to nullclaw; the canary is a driver over existing CLIs.
- **Input selection:** `nullclaw history list --json` + `nullclaw history show <id> --json` (backed by SessionStore `listSessions`/`loadMessagesDetailed`, `main.zig:4562/4695`) to sample real past user turns. PLUS a tiny curated synthetic set as a smoke test (engineered to force a tool-failure learning signal and a memory-dependent closed-loop pair).
- **Scratch isolation:** a throwaway config derived from the real one but with (a) memory backend forced to sqlite, (b) `--workspace /tmp/canary-ws-<stamp>` → own `memory.db` (`registry.zig:294`), (c) response cache disabled, (d) a NON-STREAMING PROVIDER ROUTE selected (there is no streaming-disable knob — use `api_mode:"responses"` or a built-in like `glm`/`zai`; see correction #7). Live `~/.nullclaw/memory.db`, config, and the gateway are NEVER touched.
- **Two arms per input:** baseline (`NULLCLAW_AGENT_JUDGE_AFTER_TURN=0 NULLCLAW_AGENT_REFLECT_AFTER_TURN=0`) and treatment (both `=1`), same input, non-streaming. **Each arm uses its OWN scratch workspace** (`baseline-ws-*` / `treatment-ws-*`) so persisted history + auto-saved memory from one arm never contaminates the other (confound found in corroboration: `persistCliTurn` cli.zig:197, `auto_save` recall root.zig:2438).
- **Treatment emits `judge invoked`, not `reflection invoked`:** with both flags on, the judge branch runs and `finishTurnReflection` is skipped (`root.zig:3109`); lessons still save via `applyReflectionVerdict`. Metrics/smoke criteria must accept `judge invoked` on the treatment arm.
- **All `agent`/`memory` canary commands run with `NULLCLAW_HOME=<scratch> NULLCLAW_WORKSPACE=<scratch-ws>`.** `history list/show` (input sampling) is read-only against the PRODUCTION store — documented, not isolated.
- **Signal capture:** run each invoke with a log level that emits the `.agent_judge`/`.agent_reflection` debug lines to a capture file; parse them for judge fire/continue/stop, lesson saved/rejected, reflection_estimated_tokens/duration_ms per turn. After the run, `nullclaw memory list --category lesson --json` + `utility_score` on the scratch DB to inventory saved lessons.
- **Closed-loop probe:** a same-`--session` A→B pair where B's ideal answer depends on a lesson A should have saved; check (from B's captured context/logs) whether A's lesson was recalled and whether B's answer differs baseline vs treatment.
- **Report:** `scripts/canary/report.md` (generated) — per input-class metrics + a GO/NO-GO recommendation for Phase 2, with kill signals (lesson pollution, judge burns continuations w/o improvement, token/latency blowup w/o quality gain).

## Metrics (per input class: replayed-tool-failure / memory-dependent / simple-QA)

- Judge: fire rate, continue rate, stop reason distribution, avg continuations, added turns.
- Reflection: invocations, lessons saved vs rejected (by reason), recall-hit on the closed-loop probe.
- Cost/latency (APPROXIMATE, log-derived): reflection_estimated_tokens delta baseline→treatment, wall-clock delta per invoke.
- Quality (qualitative + one probe): does the treatment answer on the closed-loop pair actually improve, or just cost more? (Human-readable diff in the report; not an automated score.)

## Testing

The canary is a driver script, but it must be tested — a broken harness produces a misleading report, which is worse than none.

- **Harness unit tests** (bash/py test or a Zig test if the driver is Zig): (a) scratch-config generation forces sqlite + disables cache + disables streaming (assert the generated config/env); (b) the log-parser correctly extracts judge/reflection scalar fields from a FIXTURE log sample (known `.agent_judge`/`.agent_reflection` lines → expected parsed counts) — this is the load-bearing test, since a wrong parser silently mismeasures; (c) baseline vs treatment env is set correctly per arm; (d) closed-loop A→B reuses the same `--session`.
- **Isolation test:** after a canary run, assert the live `~/.nullclaw/memory.db` mtime/content is UNCHANGED (the harness wrote only to the scratch DB) and the gateway process was untouched. This is a safety test — it must exist.
- **Smoke test:** the curated synthetic tool-failure prompt, run in treatment, MUST produce at least one `reflection_invoked` log line and one saved lesson in the scratch DB — proving the loops actually fire under the canary's non-streaming config (guards against the "judge never fires" defect regressing).
- **Dry-run mode:** the driver supports `--dry-run` that prints the exact invocations + scratch config without running them, so the plan can be reviewed and the harness tested without spending tokens.

Validation: harness tests pass; a `--dry-run` shows correct isolation (sqlite + scratch workspace + cache off + streaming off) and correct baseline/treatment env; the smoke test confirms the loops fire.

## Rollout

Phase 1 only. Deliverable = the harness (driver + parser + report generator) + its tests + a first report from a small sampled run. Phase 2 (time-boxed live gateway enable) is a SEPARATE future decision, gated on the user reading the Phase-1 report and explicitly approving. Nothing in Phase 1 modifies nullclaw production code or touches the gateway/real memory.
