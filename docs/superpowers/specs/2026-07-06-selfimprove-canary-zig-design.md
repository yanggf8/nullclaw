# Self-Improvement Canary — native Zig subcommand (in-process)

**Date:** 2026-07-06
**Status:** design corroborated (Codex ×2 + Grok, source-checked) — ready for plan
**Supersedes:** the Python design (`2026-07-06-selfimprove-canary-design.md`) and its harness (`scripts/canary/`, removed in `dfefc1a9`). Reason: a pure-Zig project must not carry a Python runtime; in-process is also strictly simpler (no log parsing).

## Purpose

Measure whether enabling the two dormant self-improvement loops (`judge_after_turn`, `reflect_after_turn`, default OFF) actually helps, WITHOUT touching the live gateway, by running the loops IN-PROCESS in a native `nullclaw canary` subcommand and reading the metrics directly from the Agent. Then feed the raw metrics to the LLM (`provider.chatWithSystem`) to produce a natural-language verdict — the canary "talks to you," it does not just dump a report.

Non-goals: does NOT enable the loops on the gateway; does NOT run a static file report; does NOT add any new tech stack (native Zig, reusing existing Agent/Memory/provider). Phase 2 (time-boxed gateway enable on real traffic) remains out of scope, gated on a clean Phase-1 verdict.

## Why in-process beats the old subprocess+log-parse design

The Python harness shelled out to `nullclaw agent -m` and parsed `.agent_judge`/`.agent_reflection` stderr logs — fragile: Zig log envelope (`level(scope): msg`), ANSI stripping, per-invoke token summing, debug-build requirement, and `agent invoke --json` swallowing child stderr. In-process DELETES all of that: build an Agent, call `turn()`, read counters as fields. No parsing, no subprocess, no env dance, no debug-build dependency.

## Architecture

New top-level `nullclaw canary` subcommand: `Command.canary` enum entry + `parseCommand` map + dispatch arm in `src/main.zig` (~lines 20/130/225), logic in a new top-level `src/canary.zig` module (mirrors how `status.zig`/`doctor.zig` sit outside `health.zig` and consume a snapshot — `health.zig:149`, `status.zig:72`, `doctor.zig:145`).

### Metric access (corroborated decision — snapshot struct)

Add ONE narrow read API to Agent (not N getters, not moving canary into `agent/`):
```
pub const ReflectionMetrics = struct {
    reflection_estimated_tokens: usize,
    reflection_estimated_cost_usd: f64,
    judge_continue_count: u8,
    reflection_lessons_saved: usize,
    reflection_turn_invocations: usize,
};
pub fn reflectionMetrics(self: *const Agent) ReflectionMetrics { ... }
```
Matches the repo's existing snapshot pattern (`SessionSnapshot`/`snapshotSessions` at `session.zig:2069`; Agent's `tokensUsed`/`historyLen`/`snapshotActiveToolName` at `root.zig:4309/798`). The canary reads via this method — it does NOT touch private fields directly (they're technically reachable in-package, but that coupling is not the contract). One place to document reset semantics: `estimated_*` + `judge_continue_count` reset per turn (`root.zig:2264`), `reflection_lessons_saved` + `reflection_turn_invocations` are cumulative per Agent lifetime.

### Per-arm run (fresh Agent per arm — mandatory)

For each canary input, run TWO arms; because `reflection_lessons_saved`/`reflection_turn_invocations` are cumulative and `MAX_LESSONS_PER_SESSION=8` caps per Agent lifetime, each arm builds a FRESH Agent:
- **baseline:** Agent with `judge_after_turn=false, reflect_after_turn=false`.
- **treatment:** fresh Agent with both `true`.
Same input, same scratch Memory config, same provider/model, non-streaming. After `turn()`, read `agent.reflectionMetrics()` + response text + wall-clock (`std_compat.time.milliTimestamp()` around the turn) + query scratch Memory for `category="lesson"` count and `utility_score`.

### Isolation (SAFETY — the hard boundary; every leak vector from corroboration)

The canary MUST, before constructing the Agent/tools. **Corroborated correction: MUTATE the loaded Config in place** (do NOT make a by-value copy — a copy borrows `base`'s arena strings and dangles if base.deinit() runs; in-place keeps one `defer cfg.deinit()` owning the arena). `Config` fields live in `src/config.zig:196-262` (`.arena: ?*ArenaAllocator`, `.workspace_dir`, `.workspace_dir_override`, `.config_path`).

Sanitize field set (ALL of these — corroboration found workspace_dir alone is insufficient; config_path derives daemon/session/token/audit/channel state via backfillRuntimeDerivedFields):
```
cfg.workspace_dir = scratch_ws;
cfg.workspace_dir_override = scratch_ws;   // save() serializes from this; stale otherwise
cfg.config_path = scratch_config_path;     // else daemon state / session claim / token ledger / audit dir / channel config_dirs point at real ~/.nullclaw
cfg.memory.backend = "sqlite";             // postgres/redis/api ignore workspace_dir → would hit real store
cfg.memory.auto_save = false;              // avoid unintended writes
cfg.memory.search.store.sidecar_path = ""; // absolute sidecar path would bypass scratch
cfg.memory.response_cache.enabled = false; // sidecar db under workspace
cfg.memory.qmd.enabled = false;
cfg.security.audit.log_path = "audit.log"; // relative → under scratch config dir, not absolute real path
try cfg.backfillRuntimeDerivedFields();    // re-derives channel config_dirs etc. from new config_path
cfg.syncFlatFields();
```
Then:
- `initRuntime(alloc, &cfg.memory, scratch_ws)` (takes `*const MemoryConfig`, NOT full Config — corroborated) → `<scratch_ws>/memory.db` (`memory/root.zig:1002`, `registry.zig:294`); wire BOTH `agent.mem` and `agent.mem_rt` (recall learning signal needs `mem_rt` — `root.zig:2487`).
- MINIMAL tool set — a local `CanaryFailTool` only; do NOT call `tools.allTools` (MCP/subagent/delegate side effects, child processes).
- Do NOT set `stream_callback`/`stream_ctx` (CLI force-sets them at `cli.zig:795`; canary stays non-streaming so the judge fires — `root.zig:2151`).
Safety assertion: read the resolved db path via a new `MemoryRuntime.primaryDbPath()` accessor and assert it starts with scratch_ws AND does not contain `/.nullclaw/`; abort before running if it fails. Failure mode is operator mis-wiring, caught by the assertion.

### Input classes (must actually exercise the loops)

- **tool-failure:** a prompt that induces a tool failure (sets `turn_tool_failure_seen`) → gives the reflect arm a learning signal (else reflect SKIPS — `root.zig:2115`).
- **memory-dependent:** a prompt after a pre-seeded lesson so `mem_rt` recall fires (`last_recalled_top_key != null`).
- **simple-QA:** a benign prompt — expected to show the loops as pure overhead (control).
Note: the judge arm does NOT need a learning signal (judge runs regardless — `reflectOnTurnForJudge` has no gate); only the reflect-only path needs one.

### Output — natural-language verdict (talks to you)

Aggregate per-class metrics + kill-signal evaluation, then build a compact metrics summary and call `provider.chatWithSystem(system="you are evaluating a canary...", message=<metrics + kill-signals>, model, 0.0)` to get a natural-language GO/NO-GO verdict with reasoning. Print that verdict (conversational) as the primary output; a terse metrics table follows for reference. No hardcoded verdict prose — the agent writes it from the numbers (matches the no-hardcoded-branching / agent-assisted-output preference).

### Kill signals (computed in Zig, fed to the verdict)

- `judge_never_fired`: treatment shows judge enabled but `judge_continue_count==0` AND no judge activity across all inputs (non-streaming route failed → measured nothing) → hard NO-GO.
- `no_useful_lessons`: treatment tool-failure class ran the loop but scratch lesson count == 0.
- `token_blowup`: treatment `reflection_estimated_tokens` > baseline × factor (named const, e.g. 3.0).
- `judge_continuation_loop`: `judge_continue_count` hit its cap on multiple inputs (cost/latency risk).
- (Isolation is asserted directly, not a post-hoc signal: if the scratch path check fails, the canary aborts before running.)

## Testing

`zig build test` coverage (the whole point of going native — one test story):
- `reflectionMetrics()` returns the live field values (unit test on Agent).
- Isolation: a canary helper that builds the sanitized scratch config asserts backend==sqlite, workspace_dir under temp, and the resolved db path is not `~/.nullclaw`. (Pure, no live model.)
- Kill-signal evaluation: given synthetic per-arm metric structs, `evaluateKillSignals` returns the right signals (table-driven, no live model) — mirrors the Python report tests but in Zig.
- Fresh-agent-per-arm: a test that two arms don't share the cumulative `reflection_lessons_saved` counter.
- Verdict formatting: the metrics→summary builder produces the expected compact text from a metrics struct (no live LLM; the chatWithSystem call itself is the live part, exercised only in a gated integration run).
Use `builtin.is_test` guards to skip the live provider/turn in unit tests (project convention). A real end-to-end run (spends tokens) is a manual/gated step, not a CI test.

## Rollout

Deliverable: `Agent.reflectionMetrics()` + snapshot struct, `src/canary.zig`, `main.zig` routing, and the `zig build test` coverage above. The first LIVE run (spends tokens, needs the real provider) is a separate gated step after the code lands, surfaced for explicit user go-ahead. Nothing enables the loops on the gateway.
