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

## Pitfalls

1. **Don't assume Folia's scheduler internals** — Canvas rewrote it. Grep the actual source.
2. **Config changes need runtime testing** — scheduler behavior is hard to unit-test; use `runDev`.
3. **Thread count > cores** — context-switch overhead. Auto (`-1`) is usually best.
4. **gridExponent changes affect all worlds** — region boundaries are global, not per-world.
5. **`< 2` threads disables profiling** — `doesSupportRegionProfiler()` returns false; pinning would deadlock.
6. **CPU affinity needs 1 core per thread** — `affinitySet.cardinality() < threads` throws.
7. **`cancel()` unsupported** — both AFFINITY and StealingQueue throw `UnsupportedOperationException`.
