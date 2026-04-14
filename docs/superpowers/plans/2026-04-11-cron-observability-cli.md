# Cron Observability CLI — Expose the Framework

**Status: COMPLETE AND VALIDATED** (framework landed 2026-04-11 to 2026-04-14; end-to-end scheduler-path validation closed 2026-04-14)
**Branch:** `feat/cron-subagent`
**Depends on:** commits `3ff18d8`, `d833a3e`, `4ec6291`, `271e939` (scheduler observability framework)
**Implementation commits:** `acc9a5b`, `325ec8e`, `979430d`, `bdb7002`, `4d85d57`, `8256b06`, `1ff4c8c`, `a618371`, `b8267e1`, `fcaecd4`, `de2ff27`

## Final State

This plan is no longer just "implemented in code"; it is closed operationally.

- Scheduler-owned verification and repair are exposed in the CLI and persisted in `cron_jobs`.
- `cron runs`, `cron degraded`, and `cron run-by-trace` are available for operator inspection.
- Early failure classification is normalized across skill, shell, and agent jobs as `exec_error`.
- Scheduled shell and agent runs persist `trace_id` on both success and early exec-error paths.
- Read-only inspection commands work in the restricted shell path without requiring schema writes.
- UTF-8 `skill_args` are accepted safely, which removed the CJK breakage in weather/commute jobs.

Operational rollout completed outside the repo as well:

- `news`, `weather`, `commute`, and `doughcon` were migrated to scheduler-owned `skill_contract`.
- All 23 live cron jobs in those four families now use `verification_mode=skill_contract` and `repair_policy=retry_once`.
- The live skill copies and the source mirror under `/home/yanggf/a/claw-skills` were kept in sync for the migrated files.

Validation status:

- Real scheduled production runs validated `news` and `doughcon` with `status=ok`, `exit_code=0`, `verified=1`, and populated `trace_id`.
- Temporary no-delivery scheduler-path jobs validated `weather` and `commute` through the real gateway queue worker, then were removed.
- Final temporary validation rows:
  - `weather` → trace `job-de9f9c2c-f41d-426c-8062-157757ac5e29:2296`
  - `commute` → trace `job-936285ba-fcbc-4ce4-9994-1764f1d975e8:2297`
- Schedule and job count were confirmed clean after removal of the temporary jobs.

## Problem

The scheduler observability framework added `verification_mode`, `repair_policy`, `failure_class`, `repair_action`, `verified`, `trace_id` to the data model and wired `classifySkillRun`, retry-once, and alert-on-degraded into the runtime. **None of it is reachable from the CLI.** Operators cannot configure verification at add-time, see the new columns in `cron runs <id>`, query degraded runs across jobs, or correlate a trace ID back to its run. This plan closes the gap without changing the data model or runtime logic.

---

## Scope — 5 items

### Item 1 — `--verify` / `--repair` flags on `add-skill`, `add-agent`, `add`, and `update`

**Files:** `src/main.zig`, `src/cron.zig`, `src/cron/types.zig`, `src/gateway.zig`

**Step 1a: extend the CLI option structs** (`src/main.zig` lines 842–855)

```zig
const CronAddAgentOptions = struct {
    model: ?[]const u8 = null,
    session_target: yc.cron.SessionTarget = .isolated,
    delivery: yc.cron.DeliveryConfig = .{},
    tz_offset_s: i32 = 0,
    verification_mode: yc.cron.VerificationMode = .none,  // new
    repair_policy: yc.cron.RepairPolicy = .none,          // new
};

const CronAddSkillOptions = struct {
    skill_args: ?[]const u8 = null,
    deliver_to: ?[]const u8 = null,
    account_id: ?[]const u8 = null,
    timeout_secs: ?u32 = null,
    tz_offset_s: i32 = 0,
    verification_mode: yc.cron.VerificationMode = .none,  // new
    repair_policy: yc.cron.RepairPolicy = .none,          // new
};
```

Add a matching `CronAddShellOptions` struct (currently inline in `runCron` for `add`; extract it now so the 4 commands are symmetric) with just `{ tz_offset_s, verification_mode, repair_policy }`.

**Step 1b: parse the flags** — in `parseCronAddSkillOptions`, `parseCronAgentOptions`, and the shell `add` parsing block, add two branches:

```zig
} else if (i + 1 < sub_args.len and std.mem.eql(u8, sub_args[i], "--verify")) {
    options.verification_mode = yc.cron.VerificationMode.parse(sub_args[i + 1]);
    i += 1;
} else if (i + 1 < sub_args.len and std.mem.eql(u8, sub_args[i], "--repair")) {
    options.repair_policy = yc.cron.RepairPolicy.parse(sub_args[i + 1]);
    i += 1;
```

`VerificationMode.parse` and `RepairPolicy.parse` already exist in both `src/cron.zig` and `src/cron/types.zig`; they return `.none` on unknown input (permissive, matching other parsers like `SessionTarget.parse`).

**Step 1c: extend `cliAddSkillJob` / `cliAddAgentJob` / `cliAddJob`** (`src/cron.zig`) — add two trailing parameters `verification_mode: VerificationMode`, `repair_policy: RepairPolicy`. Before `dbSaveJob(db, job)`, set:

```zig
job.verification_mode = verification_mode;
job.repair_policy = repair_policy;
```

No schema migration needed — `cron_jobs.verification_mode` and `repair_policy` already exist (migration in `ensureCronTable` at lines 2296–2297) and `dbSaveJob` already binds them (lines 2417–2419). We're populating them from a non-default source for the first time.

**Step 1d: extend `CronJobPatch`** (`src/cron.zig:230` AND `src/cron/types.zig:100`) — add:

```zig
verification_mode: ?VerificationMode = null,
repair_policy: ?RepairPolicy = null,
```

Both copies must stay in sync (existing pattern for the enum duplication).

**Step 1e: extend `cliUpdateJob`** (`src/cron.zig:4554`) — add two parameters, serialize into the REST body when non-null, set in the `CronJobPatch` literal, and in the direct-DB fallback set `job.verification_mode` / `job.repair_policy` before `dbSaveJob`.

**Step 1f: extend the gateway update handler** (`src/gateway.zig:3420`) — parse `verification_mode` / `repair_policy` from the incoming JSON body (same style as `session_target`), set them on both `CronJobPatch` literals (the DB-direct one at `3437` and the legacy one at `3485`).

**Step 1g: extend `CronScheduler.updateJob`** — trivial patch-apply for the two new fields.

**Step 1h: update `CRON_SUBCOMMANDS` metadata and usage text** (`src/main.zig:42` and `cron_usage` heredoc at `951`) — extend help for `add`, `add-agent`, `add-skill`, `update` to mention `--verify` and `--repair`. The `CRON_SUBCOMMANDS` list itself doesn't change for Item 1.

**Tests:**
1. `parseCronAddSkillOptions parses --verify and --repair` — assert options struct has correct enum values.
2. `cliAddSkillJob persists verification_mode and repair_policy` — add, then re-load via `dbLoadJobSpec`, assert values round-trip.
3. `cliUpdateJob updates verification_mode and repair_policy` — add with defaults, update with both flags, re-load, assert changed.
4. `parseCronAddSkillOptions unknown --verify value falls back to none` — parser permissiveness.

**LOC:** ~250 (most is CLI parsing + doc strings).

---

### Item 2 — Extend `cron runs <id>` output with observability columns

**Files:** `src/cron.zig`

**Step 2a: extend `dbListRunsJson`** (`src/cron.zig:5791`)

```sql
SELECT id, job_id, started_at, finished_at, status, output,
       exit_code, failure_class, repair_action, verified, trace_id
FROM cron_runs WHERE job_id=?1 ORDER BY finished_at DESC LIMIT ?2
```

Append 5 JSON fields. Use `c.sqlite3_column_type(stmt, N) == SQLITE_NULL` checks for `failure_class`, `repair_action`, `trace_id` (nullable); `verified` and `exit_code` default to 0 for pre-migration rows.

**Step 2b: extend the human-readable formatter in `cliListRuns`** (`src/cron.zig:4647`)

Extend the SELECT in the same way. Extend the log line:

```zig
log.info("  [{d}] {s} at {d} ({s}){s}", .{ count, status_str, finished, formatted, suffix });
```

where `suffix` is built as:
- if `verified == 0` (pre-migration): empty string
- otherwise: ` v=N` followed by ` fc=<class>` (if non-null) and ` ra=<action>` (if non-null)

Use a stack `[128]u8` buffer + `std.fmt.bufPrint`. Allocation-free.

**Tests:**
1. `dbListRunsJson emits observability columns` — insert 3 rows with verified = 0/1/2/3, failure_class, trace_id; assert JSON contains expected fields.
2. `cliListRuns formatter hides v=0 and shows v=2 with fc/ra` — insert rows, capture log output via testing helper, assert suffix.

**LOC:** ~100 (SQL + JSON + formatter + 2 tests).

---

### Item 3 — `cron degraded` command

**Files:** `src/cron.zig`, `src/main.zig`

**New function:** `cliListDegradedRuns(allocator, hours, job_filter, json_out) !void`

```sql
SELECT job_id, finished_at, verified, failure_class, repair_action, exit_code, trace_id
FROM cron_runs
WHERE verified >= 2
  AND finished_at > ?1
  [AND job_id = ?2]
ORDER BY finished_at DESC
LIMIT 200;
```

**Flags:**
```
nullclaw cron degraded [--hours N] [--job <id>] [--json]
  --hours N   look-back window (default: 24)
  --job ID    restrict to a single job
  --json      machine-readable
```

**Human output:**
```
2026-04-10 02:00:00  cct2        v=2  fc=content_invalid  ra=retried_failed  trace=cct2-a1b2
2026-04-09 18:00:00  news-daily  v=3  fc=timeout          ra=—               trace=news-daily-c3d4
```

Column widths: left-align `job_id` to 20 chars (truncate with `…` if longer), right-align `v=N` column to width 4, `fc=` column to width 20, `ra=` column to width 18. Simple `std.fmt` padding.

**Step 3a: add `degraded` to `CRON_SUBCOMMANDS`** (`src/main.zig:42`).

**Step 3b: add to `cron_usage` heredoc** (`src/main.zig:951`) with inline description.

**Step 3c: add dispatch case** in `runCron`.

**Tests:**
1. `cliListDegradedRuns filters by verified >= 2` — insert 4 rows (verified 0/1/2/3), assert only 2 rows returned.
2. `cliListDegradedRuns filters by hours window` — insert rows at now-1h and now-48h, assert default 24h window returns only the recent one.
3. `cliListDegradedRuns filters by --job` — insert rows for 2 jobs, assert filter restricts correctly.

**LOC:** ~140.

---

### Item 4 — `cron run-by-trace <trace_id>` command

**Files:** `src/cron.zig`, `src/main.zig`

**New function:** `cliFindRunByTrace(allocator, trace_id, json_out) !void`

```sql
SELECT id, job_id, started_at, finished_at, status, exit_code,
       verified, failure_class, repair_action, output
FROM cron_runs
WHERE trace_id = ?1
ORDER BY finished_at DESC
LIMIT 10;
```

Exact match only (no prefix matching — trace IDs are job IDs which are short and unambiguous).

**Exit code:** `1` if no match (so shell pipelines can detect). Use `std.process.exit(1)` after log.

**Step 4a: add `run-by-trace` to `CRON_SUBCOMMANDS`**.

**Step 4b: add to `cron_usage`**.

**Step 4c: add dispatch case**.

**Tests:**
1. `cliFindRunByTrace returns matching row` — insert row with `trace_id = "test-123"`, call, assert output contains `test-123`.
2. `cliFindRunByTrace exits 1 on no match` — integration test via Child process would be heavyweight; instead expose a pure helper `findRunByTraceInternal` that returns an `ArrayList` and test that.

**LOC:** ~90.

---

### Item 5 — Skill trace marker helper

**Files:** `~/.nullclaw/skills/lib/trace_marker.py` (new), `~/.nullclaw/skills/SKILLS.md` (update)

```python
"""Emit a job trace marker for content_has_trace verification.

Skills cron-scheduled with --verify content_has_trace must print the
NULLCLAW_JOB_ID value somewhere in stdout. Call emit_trace() as the
last line of a successful run (after delivery confirmation) so that
aborts during delivery fail verification correctly.

Usage:
    from trace_marker import emit_trace
    emit_trace()
"""
import os
import sys


def emit_trace(stream=sys.stdout):
    """Print [trace:<NULLCLAW_JOB_ID>] to stream. No-op if env var unset."""
    job_id = os.environ.get("NULLCLAW_JOB_ID")
    if job_id:
        print(f"[trace:{job_id}]", file=stream, flush=True)
```

**Why stdout:** `classifySkillRun` in `src/gateway.zig` searches `stdout` for `spec.id`. Stderr would silently fail verification.

**Why the marker format contains the job ID as a substring:** `std.mem.indexOf(u8, stdout, spec.id)` just needs the job ID to appear anywhere — `[trace:<id>]` satisfies that while being greppable and unambiguous.

**SKILLS.md update** — one paragraph under a new "Content verification" subsection:

```markdown
## Content verification (`content_has_trace`)

Skills scheduled with `nullclaw cron add-skill ... --verify content_has_trace`
must print the `NULLCLAW_JOB_ID` environment variable somewhere in stdout
to pass verification. Use the `trace_marker` helper:

    from trace_marker import emit_trace  # from ../lib
    emit_trace()  # emits [trace:<job_id>] to stdout

Place the call after delivery confirmation so a mid-delivery abort
fails verification correctly.
```

**Tests:** none (4 lines of deterministic Python with env var fallback).

**LOC:** ~15.

---

## Non-goals

- No `cron-diagnose` skill — CLI primitives first; a wrapper can come later.
- No schema migrations — all columns already exist.
- No REST API structural changes — only adding field parsing to the existing `update` handler.
- No changes to `classifySkillRun` logic.
- No new verification modes.
- No refactor of all existing CLI arg structs — only extend the three that need new flags.

---

## File-by-file change summary

| File | Item | Change | LOC |
|------|------|--------|-----|
| `src/main.zig` | 1, 3, 4 | Extend `CronAdd*Options` structs; add `--verify`/`--repair` parsing; add `degraded` and `run-by-trace` to `CRON_SUBCOMMANDS` + `cron_usage`; add dispatch cases | ~180 |
| `src/cron.zig` | 1, 2, 3, 4 | Extend `cliAdd*Job` + `cliUpdateJob` signatures; extend `CronJobPatch`; extend `dbListRunsJson` + `cliListRuns`; add `cliListDegradedRuns`; add `cliFindRunByTrace`; extend `CronScheduler.updateJob` | ~400 |
| `src/cron/types.zig` | 1 | Extend `CronJobPatch` with 2 fields | ~4 |
| `src/gateway.zig` | 1 | Parse `verification_mode`/`repair_policy` in update handler; set on both `CronJobPatch` literals | ~30 |
| `~/.nullclaw/skills/lib/trace_marker.py` | 5 | New file | ~15 |
| `~/.nullclaw/skills/SKILLS.md` | 5 | One paragraph | ~15 |

Plus tests (~250 LOC in `src/cron.zig` and `src/main.zig`).

**Total new Zig:** ~860 LOC (mostly CLI parsing, formatting, and test boilerplate).

---

## Build order

Each item is a standalone commit.

1. **Item 1** (flags + patch field + gateway) — verify round-trip: add → list → DB → re-export → re-load. This is the blocking prerequisite for the framework to be configurable at all.
2. **Item 2** (runs output) — immediately usable for diagnosing any existing row.
3. **Item 3** (degraded) — operator query workflow.
4. **Item 4** (run-by-trace) — trace correlation.
5. **Item 5** (trace_marker.py) — skill author ergonomics.

Item 1 is the largest and rightfully sits first — without it, the rest is observing state that nobody can configure.

---

## Validation

After each commit:
- `zig fmt --check src/`
- `zig build`
- `zig build test --summary all` — baseline expected failures: `session.test` (tunnel config), `daemon.test.schedulerThread` (missing test prompt file). Both pre-existing and unrelated.

After all 5 items:
- End-to-end: convert one cct2 job to `--verify content_has_trace --repair retry_once`, trigger a failure (kill the upstream API or use a bad skill arg), confirm `cron degraded --hours 1` surfaces it, confirm `cron run-by-trace <id>` retrieves it, confirm operator alert fires.

---

## Risks (addressed)

1. **`CronJobPatch` missing fields** — confirmed during plan review; Item 1d and 1e cover both copies and both code paths (gateway REST, direct DB).
2. **Pre-migration `cron_runs` rows have NULL in new columns** — formatter hides `v=0` (default int) and uses `SQLITE_NULL` checks on nullable text columns.
3. **Flag name collisions** — `--verify` and `--repair` don't collide with any existing cron flag.
4. **CLI backward compatibility** — all new flags optional with safe defaults.
5. **`parse()` permissiveness — revisited.** Original plan accepted permissive parsing for consistency with `SessionTarget.parse`. Codex review (see disposition below) correctly flagged that permissive parsing on `cron update` can silently overwrite an existing policy with `.none` on a typo. **Resolved**: added `VerificationMode.parseStrict` and `RepairPolicy.parseStrict` (mirroring the precedent already set by `SessionTarget.parseStrict`) and wired all four CLI add/update sites through strict parsing with clear error messages. The permissive `parse` helpers remain for DB/gateway load paths where values are known-valid.
6. **Test isolation for SQLite** — existing tests use `std.testing.tmpDir` + unique DB paths (see `feedback_testing.md`). Follow the same pattern.

---

## Gemini review feedback — disposition

| Feedback | Action |
|---|---|
| Missing `CRON_SUBCOMMANDS` + `cron_usage` updates for new subcommands | **Accepted** — added to Items 1, 3, 4 |
| `CronCliOptions` struct to avoid 10+ positional args | **Accepted, scoped** — extending existing option structs rather than introducing a new one; keeps refactor blast radius small |
| Extend flags to `add-agent` and `add` (shell) for consistency | **Accepted** — Item 1 covers all 4 add commands + update |
| Hide `v=0` for pre-migration rows | **Confirmed** — already in plan |
| Symbol-based status (`✓`/`!`/`✘`) instead of `v=N` | **Rejected** — terminal compatibility risk, greppability loss |

---

## Codex review feedback — disposition

Post-implementation review (commit under review, not yet landed). All three findings accepted and fixed before commit.

| Finding | Severity | Action |
|---|---|---|
| `--verify`/`--repair` silently downgrade typos to `.none` (worst on `update`, which overwrites existing policy) | P2 | **Accepted** — added `parseStrict` to both enums in `src/cron.zig` and `src/cron/types.zig`; added `parseCronVerifyArg`/`parseCronRepairArg` helpers in `src/main.zig` that print allowed values and exit 1 on invalid input; wired all four call sites (`add`, `add-agent`, `add-skill`, `update`). Two new unit tests exercise both the valid-value paths and the error paths. |
| `cron degraded` only returns `verified >= 2`, so shell/agent runs with `status='error'` are invisible (they write `verified=0` because `dbCompleteJob` is called with `run_result = null` for non-skill jobs) | P2 | **Accepted** — widened `cliListDegradedRuns` filter to `(verified >= 2 OR status = 'error')`; added `status` to SELECT, JSON output, and human-readable output; updated the header and empty-state messages. |
| `add-skill` parser unconditionally consumed `--verify`/`--repair` tokens, breaking any skill that uses those flag names itself | P3 | **Accepted** — introduced a `--` separator in `parseCronAddSkillOptions`. Scheduler-owned flags are parsed before `--`; everything after `--` is appended verbatim to `skill_args`. Usage heredoc and one-line usage print both updated. Regression test covers: pre-separator `--verify exit_only` reaches the scheduler, post-separator `--verify deep` and `--repair reload` reach the skill, the bare `--` token does not leak. |

---

## Post-implementation diagnosis (2026-04-13)

### `cron runs` returns empty despite `last_status=ok`

**Symptom:** `nullclaw cron runs <job-id> --json` returns `[]` for all jobs, even though `cron list` shows `[ok]` status.

**Root cause:** The gateway process (PID 785) started Apr 1 and is running a binary from before commit `f0bdce2` (Apr 7), which added `cron_runs` history insertion via `dbCompleteJob`. The running binary predates the entire `cron_runs` feature — it updates `last_status`/`last_output` in memory and in `cron_jobs`, but never inserts history rows.

**Execution path analysis:**
- The DB-direct scheduler path (`gateway.zig:3992`) calls `classifySkillRun` → `complete()` → `dbCompleteJob`, which inserts into `cron_runs`.
- The legacy in-memory path (`cron.zig:1203`) updates `job.last_run_secs`/`job.last_status` directly and never calls `dbCompleteJob`.
- Both paths exist in the current source. The stale binary was built before the DB-direct path was wired.

**Fix:** Restart the gateway to pick up the current binary. No code changes needed.

**Lesson:** Gateway restarts are required after any binary rebuild that changes cron execution paths. This reinforces the need for a gateway self-restart mechanism (see `project_gateway_restart.md`).

### UTF-8 skill args rejected as `UnsafeSkillArgs` (2026-04-14)

**Symptom:** Three scheduled jobs (two `weather`, one `commute`) fired at 07:18/07:20 local with `last_status=error`. `cron_runs` rows showed the unclassified-failure fingerprint: `status='error'`, `exit_code=0`, `failure_class=NULL`, `verified=0`, `trace_id=NULL`, `output=NULL`. Manually running the jobs reproduced `error: skill resolution failed: UnsafeSkillArgs`.

**Root cause:** `validateSkillArgsSafe` (`src/cron.zig:1645`) enforced an ASCII-only byte allowlist. Any byte ≥ 0x80 raised `UnsafeSkillArgs`, so every Traditional Chinese argument (`--location 新北市`, `--from 淡水安泰登峰`, etc.) was rejected at resolution time. The failing jobs all had CJK args; other weather/commute jobs with ASCII-only args stayed green.

**Fix (commit `1ff4c8c`):** Accept bytes `0x80…0xFF` in the allowlist and require the full input to be well-formed UTF-8 via `std.unicode.utf8ValidateSlice`. Shell metacharacters are all ASCII (<0x80), so multi-byte UTF-8 sequences cannot form shell syntax. Regression test covers Traditional Chinese, Japanese, Korean, invalid UTF-8 rejection, and the escape-hatch guard (`新北市 | rm` still rejected).

### Early skill failures stored as unclassified errors (2026-04-14)

**Symptom:** The `cron_runs` rows for the CJK failures above (rows 8/12/13 on the live DB) wrote `exit_code=0, failure_class=NULL, verified=0, trace_id=NULL` — indistinguishable from a scheduler-side abort. Operators running `cron degraded` couldn't see them because the row carried no `failure_class` signal, only `status='error'`.

**Root cause:** Both the DB-direct scheduler path (`gateway.zig` runQueueWorker skill branch) and the manual `cron run` path (`cron.zig` cliRunJob) called `dbCompleteJob(..., run_result=null, trace_id=null, ...)` on early failures (skill resolution, spawn, output collect, wait). The only path that populated `RunResult` was post-classification, after `classifySkillRun`. Early failures exited before classification.

**Fix (commit `a618371`):**
- New helper `execErrorRunResult()` in `src/cron.zig` returning `{exit_code=1, failure_class="exec_error", verified=3}`.
- Gateway skill branch: pass `cron_mod.execErrorRunResult()` and `run_trace_id` at all four early-failure sites. Hoist `run_trace_id` allocation above `resolveSkillExec` so resolution failures also carry the trace.
- Failure alerts now include `trace={id}` for operator correlation.
- `cliRunJob` skill/shell/agent branches: same substitution for manual runs (which are logged with `manual=1`).
- Regression test proves `dbCompleteJob` persists `exit_code=1`, `failure_class="exec_error"`, `verified=3`, `trace_id`, `manual=1` for the early-failure path.

**Validation:** After gateway restart with commit `1ff4c8c`, the three jobs produced fresh `cron_runs` rows with `status='ok'`, `verified=1`, `trace_id` set (rows 14/15/16 on the live DB). Commit `a618371` ensures the earlier failure mode is now recorded as `failure_class="exec_error"` instead of an unclassified `status='error'` row when it occurs again.

## Deferred follow-ups

### Switch inspection paths to pure read-only

**Status:** Parked. Not blocking. Pick up if/when convenient.

**What:** `cron list` and `cron show` open the cron DB with the same handle mode as the writer paths. Give pure-inspection call sites a `SQLITE_OPEN_READONLY` handle so they cannot accidentally mutate state, even if a future refactor introduces a stray `UPDATE`/`DELETE` on the inspection codepath.

**Why deferred:** Defensive hardening, not a correctness fix. No user-visible symptom, no data at risk today, no blocking dependency. Was flagged during the post-implementation audit of commit `8256b06` and consciously deferred with verdict "land as-is". Recorded here so it is not silently lost.

**Scope when picked up:**
- Audit `cron list` / `cron show` / any other read-only callers in `src/cron.zig` and `src/cron/db.zig` for shared open helpers.
- Add an `openCronDbReadOnly(path)` wrapper that passes `SQLITE_OPEN_READONLY` to `sqlite3_open_v2`.
- Switch the inspection callers; leave writer callers alone.
- Test: a write attempt through the read-only handle must return `SQLITE_READONLY`.
