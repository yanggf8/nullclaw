# Scheduler Observability and Verification Framework

**Status: COMPLETE** (implemented 2026-04-10)

**Goal:** Make the cron/skill execution path observable, diagnosable, and self-repairing. A skill that exits 0 while delivering an empty report or a degraded analysis is now detected, classified, and optionally repaired — not silently recorded as `ok`.

**Motivation (cct2 incident):** The skill exited 0, logged a glm-direct 429 on stderr, and produced `⚠️ 無法取得任何分析結果` on stdout. The scheduler recorded it as `ok`. No alert fired. Root cause: success was determined solely by `exit_code == 0`.

---

## What Changed

### New per-job fields

| Field | Type | Default | Meaning |
|-------|------|---------|---------|
| `verification_mode` | `VerificationMode` | `none` | How to classify a completed skill run beyond exit_code |
| `repair_policy` | `RepairPolicy` | `none` | Automated response when a run is degraded/failed |

**`VerificationMode` values:**
- `none` — no content check (legacy behaviour)
- `exit_only` — same as none (alias, explicit)
- `content_nonempty` — stdout must be non-empty after trimming whitespace
- `content_has_trace` — stdout must contain the job ID (`NULLCLAW_JOB_ID`) as a trace marker

**`RepairPolicy` values:**
- `none` — record result and move on
- `retry_once` — if verified != 1, re-spawn same command once; original failure_class preserved if retry also fails
- `alert_only` — if verified != 1, set repair_action="alert_sent" and fire operator alert

### New `cron_runs` columns

| Column | Type | Meaning |
|--------|------|---------|
| `exit_code` | INTEGER | Raw exit code from the child process |
| `failure_class` | TEXT | `timeout` \| `exec_error` \| `content_empty` \| `content_invalid` \| NULL |
| `repair_action` | TEXT | `retried_ok` \| `retried_failed` \| `alert_sent` \| NULL |
| `verified` | INTEGER | 0=unverified 1=ok 2=degraded 3=failed_verify |
| `trace_id` | TEXT | Job ID (matches `NULLCLAW_JOB_ID` injected at runtime) |

### Classification logic (`classifySkillRun`)

```
timed_out       → failure_class="timeout",       verified=3
exit_code != 0  → failure_class="exec_error",    verified=3
mode=none/exit_only → verified=1
mode=content_nonempty, stdout empty → failure_class="content_empty", verified=2
mode=content_nonempty, stdout present → verified=1
mode=content_has_trace, job_id not in stdout → failure_class="content_invalid", verified=2
mode=content_has_trace, job_id present → verified=1
```

### Retry loop

When `repair_policy=retry_once` and `verified != 1`:
1. Re-spawn the identical command
2. If retry succeeds: `repair_action="retried_ok"`, `verified=1`
3. If retry fails: `repair_action="retried_failed"`, original `failure_class` preserved, `verified` from retry

### Operator alert upgrade

Alert now fires on `verified >= 2` (degraded OR failed), not only on non-zero exit.
Alert message format: `[cron] skill '{name}' degraded: failure={class} repair={action} trace={job_id}\n{stderr_preview}`

### Timestamp fix

`finished_at` in `cron_runs` now reflects actual wall-clock time after the child exits, not dequeue time. Early-exit error paths (spawn/collect failures) use dequeue time as a fallback.

### Seed import fix

`loadJobsWithPolicy` (seed reload path) now restores all job fields from JSON: `one_shot`, `delete_after_run`, `session_target`, `verification_mode`, `repair_policy` — not only `tz_offset_s`. Previously, one-shot jobs became recurring and main-session agent jobs reset to isolated after a seed reload.

---

## Files Modified

| File | Changes |
|------|---------|
| `src/cron/types.zig` | Added `VerificationMode`, `RepairPolicy`, `RunResult`; added fields to `CronJob`, `CronJobSpec`, `NewJobSpec` |
| `src/cron/root.zig` | Re-exported new types |
| `src/cron.zig` | Added types (duplication pattern); schema migrations for `cron_runs` (+5 cols) and `cron_jobs` (+2 cols); `dbSaveJob`/`dbLoadJobSpec`/`dbCompleteJob` extended |
| `src/cron/db.zig` | `dbSaveJobDirect` extended; `vtableComplete` passthrough; `dbAtomicDequeue` propagation |
| `src/gateway.zig` | `classifySkillRun()`; retry loop; unified `complete` local struct with optional `run_result_opt`; alert upgrade; `start_ts`/per-branch timestamp; seed import field restoration |

---

## Applying to cct2 jobs

Set `verification_mode=content_has_trace` on cct2 cron jobs. A run producing output without the job ID in stdout is recorded as `verified=2` (`failure_class=content_invalid`) and triggers an operator alert. Pair with `repair_policy=retry_once` to auto-retry once before alerting.
