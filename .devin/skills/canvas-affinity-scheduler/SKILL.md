---
name: canvas-affinity-scheduler
description: Use whenever working with Canvas's AFFINITY scheduler (io.canvasmc.canvas.tick.*), the CRS (Canvas Region-Specific) scheduler, region tick pool configuration, EDF scheduling algorithm, task pinning, work stealing, steal threshold, gridExponent / region size tuning, or paper-global.yml threaded-regions config. Triggers on "AFFINITY", "affinity scheduler", "CRS", "CRSThreadPool", "io.canvasmc.canvas.tick", "tick pool", "EDF", "FIFO", "gridExponent", "threaded-regions config", "region size", "tick threads", "work stealing", "steal threshold", "TickRegionScheduler", "RegionScheduleHandle", "ticksToSprint".
triggers:
  - user
  - model
subagent: true
argument-hint: "[config-option]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas AFFINITY Scheduler (CRS)

Canvas ships its own region scheduler called **AFFINITY**
(`io.canvasmc.canvas.tick.*`), replacing Folia's scheduler. DeepWiki refers to
it as the **CRS (Canvas Region-Specific) Scheduler**. It is EDF-based
(Earliest Deadline First), supports task pinning, work stealing, and CPU
affinity. Configured via `paper-global.yml` → `threaded-regions.scheduler` =
`AFFINITY`.

Sources: DeepWiki `CraftCanvasMC/Canvas` (CRS Scheduler, TickRegionScheduler);
local `io.canvasmc.canvas.tick.AffinitySchedulerThreadPool`,
`StealingQueueSchedulerThreadPool` (deprecated), `SchedulerUtil`,
`ScheduledHandleTickState`, `ServerRegionTickManager`,
`GlobalConfiguration.RegionScheduler`.

## Scheduler Type Selection

`TickRegionScheduler.SchedulerType` enum (patch `0001` base + `0011` fixup adds
`AFFINITY`):

| Type | Class | Pinning | Profiling | Notes |
|------|-------|---------|-----------|-------|
| `EDF` | `EDFSchedulerThreadPool` (ConcurrentUtil) | No | No | Folia default; simple EDF |
| `WORK_STEALING` | `StealingScheduledThreadPool` (ConcurrentUtil) | No | No | NUMA-aware, even scheduling |
| `AFFINITY` | `AffinitySchedulerThreadPool` (Canvas) | Yes | Yes | Canvas-original; CPU affinity, work stealing, task pinning |

`SchedulerUtil.decideScheduler(schedulerType, initialThreads, threadFactory)`
instantiates the chosen pool. Only `AFFINITY` gets an `AffinityHandler`
(profiler hooks); others get `NullHandler`.

Set in `paper-global.yml`:
```yaml
threaded-regions:
  scheduler: AFFINITY   # or EDF, WORK_STEALING
  threads: -1           # auto = core count
```

## AFFINITY Internals

### AffinitySchedulerThreadPool

`io.canvasmc.canvas.tick.AffinitySchedulerThreadPool extends Scheduler`. Based
off `EDFSchedulerThreadPool` (ConcurrentUtil). Key properties:

- **EDF ordering**: `TICK_COMPARATOR_BY_TIME` sorts by `scheduledStart` then `id`
- **CPU affinity**: optional (`enableAffinitySchedulerCpuAffinity`), Linux-only, 1 core per tick thread required
- **NUMA**: not supported
- **Intermediate tasks**: optional (`enableMidTickTasks`) — run mid-tick tasks while awaiting deadline
- **Work stealing**: optional (`enableWorkStealing`) — local queues per runner + global queue
- **Task pinning**: via `TickThreadRunner.link(task)` / `unlink()` — dedicates a runner to a task

Constants:
```java
DEFAULT_STEAL_THRESH_MILLIS = 3L
DEFAULT_RUN_TASKS_BUFFER_MILLIS = 0.1   // 100us
```

### TickThreadRunner

Each runner is a `Runnable` on its own thread. States:

| State | Meaning |
|-------|---------|
| `STATE_IDLE` | No tasks; parked |
| `STATE_AWAITING_TICK` | Waiting to tick a task, no intermediate tasks |
| `STATE_EXECUTING_TICK` | Executing a tick |
| `STATE_EXECUTING_TASKS` | Running mid-tick tasks |

Each runner has a `localQueue` (work-stealing partition) and a `linked`
field (the pinned task, or null). `link(task, isSwapping)` dedicates the runner
to `task`; `unlink()` releases. `isLinkedTo(task)` checks pinning.

### Work Stealing

When `enableWorkStealing = true`:
- Each runner has a `localQueue` (heap-ordered by EDF deadline)
- `poll(runner)` checks local + global queues for overdue tasks, then steals
  from a round-robin victim runner if its head `isStealable(now)`
- `isStealable(now)`: `(scheduledStart - now) + stealThresh <= 0` — a task is
  stealable once it has missed its deadline by `stealThresh` nanos
- `stealThresh` = `stealThresholdMillis * 1_000_000` (default 3ms)
- When disabled, all tasks go to the single `globalQueue`

### Task Pinning Mechanics

Pinning dedicates a `TickThreadRunner` to a single region's tick task:

1. `runner.link(scheduleHandle)` — sets `linked = task`; runner only runs that task
2. `returnTask(runner, ...)`: if `runner.linked != null`, returns the linked
   task's state (pinned path); other tasks on the runner eventually exceed
   steal threshold and get stolen by other runners
3. `runner.unlink()` — releases the pin

Pinning filters (from `package-info.java`):
- A pinned task on a non-pinned thread is not picked up until it exceeds steal
  threshold, then the pinned thread takes it
- A pinned thread only runs pinned tasks; other tasks migrate away via stealing

Pinning is used exclusively by the region profiler (see
`/canvas-region-profiling`). It carries a performance penalty — only enable
during active profiling.

## TickRegionScheduler + RegionScheduleHandle

`TickRegionScheduler.RegionScheduleHandle` is the schedulable tick task for a
region. It contains:

- `getCurrentTick()` — current tick count
- `getScheduledStart()` — scheduled start time (for EDF ordering)
- `region` — the `TickRegions.TickRegionData` (world, chunks, entities)

`TickRegionScheduler.getCurrentTickingTask()` — the handle currently ticking on
this thread. `ServerRegionTickManager.ensureScheduleHandle(handle, reason)`
throws if `handle != getCurrentTickingTask()`.

### ScheduledHandleTickState

`io.canvasmc.canvas.tick.ScheduledHandleTickState` — per-handle tick state:

- `scheduleHandle` — the `RegionScheduleHandle`
- `tickCountToSprintTo` — sprint target (or `UNSET`)
- `runsGameElements` — pause/play flag
- `tickStart(nanos)` — processes queued actions, checks overloaded deadline, returns sprint delay
- `tickEnd(nanos)` — records end time for overload detection

### Sprinting Ticks (ticksToSprint)

```java
// ServerRegionTickManager.ServerRegionHandle
handle.sprint(int ticks);   // Action.StartSprinting(ticks)
handle.walk();               // Action.StopSprinting
handle.pause();              // Action.Pause — stops game elements
handle.play();               // Action.Play — resumes game elements
```

`startSprinting(howLongInTicks)`:
- Sets `tickCountToSprintTo = scheduleHandle.getCurrentTick() + howLongInTicks`
- Records `startSprintNanos`
- `tickSprint()` returns `1L` (rapid) instead of `getTimeBetweenTicks()` until
  `currentTick >= tickCountToSprintTo`, then logs finish time and clears state

Use sprinting to rapidly process ticks (catch-up, testing). Actions are queued
via `postAction(Action)` and processed at the start of each tick
(`processAllActions()`), then state is broadcast to players.

## Configuration (paper-global.yml → threaded-regions)

| Key | Default | Purpose |
|-----|---------|---------|
| `scheduler` | — | `EDF` / `WORK_STEALING` / `AFFINITY` |
| `threads` | `-1` (auto) | Tick pool thread count. Auto-detects core count. |
| `gridExponent` | `4` | Region size = `2^gridExponent` chunks per side. Default 4 = 16x16 chunks. |

### AFFINITY-specific (GlobalConfiguration.regionScheduler.affinityScheduler)

| Key | Default | Purpose |
|-----|---------|---------|
| `stealThresholdMillis` | `3` | Max delay (ms) before a task is stealable by another thread |
| `runTasksBufferMillis` | `0.1` | Buffer before tick deadline to stop intermediate tasks |
| `enableWorkStealing` | `true` | Local queues + steal; false = global queue only |
| `enableMidTickTasks` | `true` | Run intermediate tasks while awaiting deadline |
| `enableAffinitySchedulerCpuAffinity` | `false` | Pin tick threads to CPU cores (Linux only) |
| `tickRegionAffinity` | `[]` | CPU IDs for affinity; needs 1 core per tick thread |

### Region scheduler general (GlobalConfiguration.regionScheduler)

| Key | Default | Purpose |
|-----|---------|---------|
| `overloadedLogMillis` | `5000` | Logs warning if region misses deadline by this much |
| `defaultTickRate` | `20.0` | TPS; vanilla 20 |
| `guardSeverity` | `THROW` | TickGuard severity: `SILENT` / `LOG` / `THROW` |

### Tuning guidance

- **More threads** — helps when many regions are active (spread players). Diminishing returns past core count.
- **Larger gridExponent** — bigger regions = fewer boundaries = less cross-region sync, but less parallelism.
- **Smaller gridExponent** — smaller regions = more parallelism, but more boundary overhead.
- **Lower stealThresholdMillis** — reduces deadline delay, increases stealing frequency.
- **Higher runTasksBufferMillis** — safer (tick starts on time), less intermediate work done.
- **CPU affinity** — 1 core per tick thread; reduces context switching on dedicated hardware.

## CRSThreadPool Instantiation

DeepWiki refers to `CRSThreadPool`; the local implementation is
`AffinitySchedulerThreadPool`. It is instantiated only when `schedulerType ==
AFFINITY` in `SchedulerUtil.decideScheduler()`. The constructor receives:

- `initialThreads` — from `threaded-regions.threads`
- `threadFactory` — names threads `Region Scheduler Thread #N`
- `runTaskBuff`, `stealThresh` — from affinity config
- `linkingSupported` — `SchedulerUtil::doesSupportRegionProfiler` (requires
  `>= 2` core threads, else pinning disabled)
- `enableWorkStealing`, `enableAffinity`, `enableIntermediateTasks`
- `onException` — crash report + `scheduler.halt()` + `stopServer()` (fail-fast)

**Profiling requirement**: `doesSupportRegionProfiler()` returns true only if
the scheduler is `AffinitySchedulerThreadPool` **and** core threads `>= 2`.
With `< 2` threads, pinning would deadlock the server (no runner left for other
regions), so region profiling is disabled.

## How It Differs from Folia's Scheduler

- Canvas rewrote the scheduler for performance (EDF + work stealing + CPU affinity + pinning).
- The **API surface** (RegionScheduler/EntityScheduler/GlobalRegionScheduler/AsyncScheduler) is the same — plugins don't notice.
- The **internal** tick pool, region assignment, and task dispatch are Canvas-original.
- Canvas adds a **task pinning** system for region profiling (see `/canvas-region-profiling`).
- `StealingQueueSchedulerThreadPool` is `@Deprecated(forRemoval = true)` — legacy; prefer `AffinitySchedulerThreadPool`.

## Finding the Code

```bash
grep -rl "io.canvasmc.canvas.tick" canvas-server/src/minecraft/java/ 2>/dev/null
grep -rl "AffinitySchedulerThreadPool" canvas-server/src/main/java/ 2>/dev/null
grep -rl "SchedulerType" canvas-server/minecraft-patches/base/ 2>/dev/null
```

**Always grep the current source** — the package layout may shift between versions.

## When Modifying AFFINITY

1. **Read the current source first** — `grep -r "io.canvasmc.canvas.tick" canvas-server/src/main/java/`
2. **Identify the patch** — which source patch file contains the class? Check `canvas-server/minecraft-patches/base/`
3. **Edit in `canvas-server/src/main/java/`** after `applyAllPatches`
4. **Rebuild**: `./rbp.sh`
5. **Test runtime**: `./gradlew runDev` — watch TPS, region tick times in logs

### Add a new config option
1. Find `GlobalConfiguration.RegionScheduler.AffinityScheduler` (grep for `affinityScheduler`)
2. Add the field + `option("key").docs(...)` block
3. Wire it into `AffinitySchedulerThreadPool` constructor or logic
4. Rebuild patches, test

### Change scheduling algorithm
1. `SchedulerUtil.decideScheduler()` switch — add a new `SchedulerType` case
2. Add to the enum in patch `0001` / `0011`
3. Ensure `SchedulerHandler` implementation (Null or custom) is set
4. Test with uneven player distribution

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew runDev
# In console: watch region tick times, TPS, thread pool utilization
# "Starting AFFINITY region scheduler" / "Region profiling marked as supported"
```

## Performance Tuning

### Benchmark patterns

Scheduler behavior is hard to unit-test — measure it at runtime with `runDev`
and a realistic load. Key metrics:

- **TPS** — overall; watch for drops when many regions are active.
- **Per-region tick time** — use Spark with `--region` pinning (see
  `/canvas-region-profiling`) to isolate a hot region.
- **Region deadline misses** — console logs `"Region surrounding ... missed
  deadline"` when `overloadedLogMillis` is exceeded; lower that threshold to
  catch overload earlier.
- **Thread pool utilization** — are all tick threads busy, or are some idle
  while others are overloaded? Idle threads + overloaded regions ⇒ work
  stealing is disabled or steal threshold is too high.

Benchmark recipe:
1. Start `./gradlew runDev` with `scheduler: AFFINITY`, `threads: -1` (auto).
2. Spread players across distant chunks (multiple regions).
3. `/spark profiler start` (global) or `--region ~ ~` (pinned) for a sample.
4. Compare tick-time distributions across thread counts (`threads: 2, 4, 8,
   auto`) — keep the config that minimizes deadline misses.
5. Repeat after changing `gridExponent` (region size) — boundary overhead
   scales with region count.

### Measuring scheduler overhead

Scheduler overhead = time spent in dispatch/steal/poll vs. actual tick work.
Use Spark's flame graph (see `/canvas-region-profiling` → Flame Graph
Interpretation):

- Frames in `io.canvasmc.canvas.tick.*` (poll, steal, link/unlink) are
  overhead.
- Frames in `Level.tick`, `Entity.tick`, `BlockEntity` are actual work.
- If overhead > ~10% of a region's tick budget, consider: fewer threads
  (less stealing contention), larger `gridExponent` (fewer regions), or
  `enableWorkStealing: false` if regions are well-balanced.

### Optimal thread count

- **Auto (`-1`)** is usually best — matches core count.
- More threads than cores → context-switch overhead; only helps if tick work
  is I/O-bound (it shouldn't be — I/O belongs on `AsyncScheduler`).
- Fewer threads than active regions → work stealing must balance; ensure
  `enableWorkStealing: true` and a reasonable `stealThresholdMillis`.
- **`< 2` threads disables profiling** (`doesSupportRegionProfiler()` returns
  false) — pinning would deadlock with one runner.
- CPU affinity (`enableAffinitySchedulerCpuAffinity: true`) needs exactly 1
  core per tick thread; set `tickRegionAffinity` to the CPU IDs.

## Scheduler Comparison — AFFINITY vs Folia's default

| Aspect | AFFINITY (Canvas) | EDF (Folia default) | WORK_STEALING |
|--------|-------------------|---------------------|---------------|
| Pinning (profiling) | Yes | No | No |
| Work stealing | Yes (configurable) | No | Yes (NUMA-aware) |
| CPU affinity | Yes (Linux) | No | No |
| Mid-tick tasks | Yes (configurable) | No | No |
| Profiling support | Yes (`>= 2` threads) | No (`NullHandler`) | No (`NullHandler`) |
| `cancel()` | Unsupported | Unsupported | Unsupported |
| Best for | Production + profiling | Simple, low-overhead | NUMA hardware, no profiling needed |

**Trade-offs**:
- AFFINITY adds overhead (local queues, steal checks, pinning state) but
  enables region profiling and CPU pinning. Use it in production where you may
  need to profile a hot region without restarting.
- EDF is the simplest pool — lowest dispatch overhead, but no work stealing so
  an overloaded region blocks its thread with no relief.
- WORK_STEALING balances load without AFFINITY's profiling hooks — good for
  dedicated servers that never profile.

The **API surface is identical** across all three — plugins don't notice the
difference. Only internal dispatch and profiling capability change.

## Work Stealing Tuning

### When to adjust steal threshold

`stealThresholdMillis` (default `3`) controls how long a task can miss its
deadline before another runner may steal it.

- **Lower it** (e.g. `1`) when regions are unevenly loaded — overloaded
  regions get relief sooner. Cost: more steal attempts (overhead).
- **Raise it** (e.g. `5–10`) when regions are well-balanced — reduces
  unnecessary steal attempts. Risk: a briefly-overloaded region won't get
  relief until the threshold elapses.
- **Disable stealing** (`enableWorkStealing: false`) only when regions are
  guaranteed balanced (single player, or evenly spread players) — otherwise
  one hung region blocks its thread entirely.

### How to measure steal frequency

There is no built-in steal counter — instrument it or infer from behavior:

1. **Spark flame graph** — frames in `poll` → `steal` paths indicate stealing
   is active. Frequent steal frames ⇒ threshold too low or load imbalanced.
2. **Deadline misses** — if misses persist with stealing enabled, either the
   threshold is too high or there aren't enough threads.
3. **Add temporary logging** in `AffinitySchedulerThreadPool.poll()` /
   `isStealable()` (debug build) to count steals per tick — remove before PR.
4. **Thread dump** — if one runner is `STATE_EXECUTING_TICK` while others are
  `STATE_IDLE`, stealing isn't happening (disabled or threshold too high).

Rule of thumb: a small amount of stealing under uneven load is healthy;
constant stealing under balanced load means the threshold is too low or
`gridExponent` is too small (too many tiny regions).

## Pitfalls

1. **Don't assume Folia's scheduler internals** — Canvas rewrote it. Grep the actual source.
2. **Config changes need runtime testing** — scheduler behavior is hard to unit-test; use `runDev`.
3. **Thread count > cores** — context-switch overhead. Auto (`-1`) is usually best.
4. **gridExponent changes affect all worlds** — region boundaries are global, not per-world.
5. **`< 2` threads disables profiling** — `doesSupportRegionProfiler()` returns false; pinning would deadlock.
6. **CPU affinity needs 1 core per thread** — `affinitySet.cardinality() < threads` throws.
7. **`cancel()` unsupported** — both AFFINITY and StealingQueue throw `UnsupportedOperationException`.
