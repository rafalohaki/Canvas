---
name: canvas-region-profiling
description: Use whenever working with Canvas's region profiler — Spark profiler integration, task pinning system, region isolation for profiling, per-region tick timing, profiler removal patches, CRSThreadPool thread count requirement, pinned region fail-fast behavior, or region split/merge repinning. Triggers on "profiler", "region profiling", "Spark", "task pinning", "tick timing", "per-region", "Remove-Vanilla-Profiler", "profiler removal", "profile region", "RegionProfiler", "RegionScheduleHandlePinner", "REGION_PROFILING_HOLD", "fail-fast", "doesSupportRegionProfiler".
triggers:
  - user
  - model
model: sonnet
argument-hint: "[profile-target]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Region Profiling

Canvas introduces a full **Spark profiler** compatible with region threading,
replacing Folia's limited profiling engine. It uses a **task pinning** system
to isolate regions for accurate profiling. Spark tracks threads, not regions —
so Canvas pins a region to a dedicated tick runner thread to make per-region
profiling possible.

Sources: DeepWiki `CraftCanvasMC/Canvas` (Region Profiler V2, Task Pinning);
local `io.canvasmc.canvas.spark.profiler.package-info` (authoritative design
doc), `RegionProfiler`, `RegionScheduleHandlePinner`,
`SchedulerUtil.doesSupportRegionProfiler`.

## Key Patches

| Patch | Purpose |
|-------|---------|
| `0008-Remove-Vanilla-Profiler` | Removes Minecraft's vanilla profiler (incompatible with region threading) |
| `0009-Remove-Dead-Old-Watchdog-Code` | Cleans up old watchdog code replaced by Canvas's |
| `0007-Add-watchdog-thread` | Canvas watchdog (`FoliaWatchdogThread`) for region thread hangs |

See `PROFILER_REMOVAL_README.MD` in `canvas-server/` for removal details.

## Task Pinning System

For accurate profiling, Canvas **pins** regions to dedicated tick runners.
This isolates a region's work so its timing isn't mixed with other regions on
the same thread.

**Mechanics** (from `package-info.java`):
- An API marks a `TickThreadRunner` as a dedicated processor for a selected
  area of chunks being profiled
- The runner's `linked` field is set to the region's `RegionScheduleHandle`
  via `runner.link(handle)`; the runner only runs that pinned task
- Other tasks on the pinned runner eventually exceed steal threshold and get
  stolen by other runners
- A pinned task on a non-pinned thread isn't picked up until it exceeds steal
  threshold, then the pinned thread takes it

**Trade-off**: task pinning introduces a **performance penalty** during
profiling because the pinned runner is isolated and cannot scale other work.
Only enable when actively profiling. The server limits pinning to a single
area at a time (Spark runs one profiler at once).

**API surface**:
- `RegionScheduleHandlePinner.RegionPinner(fromPos, toPos, level)` — area-based pinning
- `RegionScheduleHandlePinner.GlobalTickPinner` — global tick pinning
- `pin(BiConsumer<RegionScheduleHandle, TickThreadRunner> finalizer)` — starts pinning
- `unpin(Consumer<SchedulableTick> finalizer)` — stops pinning, cleans up tickets

## Region Isolation for Profiling

1. **Define area** — `RegionPinner` takes `from`/`to` block positions (2 or 4 args)
2. **Validate** — area must be within world border; max 512 chunks
3. **Load chunks** — places `TicketType.REGION_PROFILING_HOLD` tickets
   (`ChunkMap.FORCED_TICKET_LEVEL`), non-persistent like `forced`
4. **Async load** — `level.canvas$loadOrRunAtChunksAsync(..., Priority.HIGHEST, callback)`
5. **Pin** — callback runs on the owning region's tick thread; retrieves the
   `RegionScheduleHandle` + `TickThreadRunner`, calls `finalizer` which links
   the runner to the handle
6. **Profile** — Spark tracks the pinned thread; `RegionProfiler.STATE`
   provides the active `TickThreadRunner` for thread-name matching
7. **Unpin** — `unpin(...)` removes tickets, unlinks the runner

`RegionProfiler.STATE` is a volatile reference to the current `ProfilingState`
(handle, threadRunner, handlePinner). Spark swaps between REGEX pattern
matching (`"Region Scheduler Thread #\d+"`) and thread-name matching based on
whether a region is pinned.

## Per-Region Tick Timing

Spark reports are **per-thread**, not per-region. Because the pinned region
runs on a dedicated thread, the Spark report for that thread equals the
pinned region's timing. When no region is pinned, Spark defaults to the
standard REGEX pattern matching all region scheduler threads.

Spark integration modifies `SamplerModule` to add a `--region` argument:
```
/spark profiler start --region ~ ~          # 2 args (from)
/spark profiler start --region ~ ~ ~ ~      # 4 args (from + to)
/spark profiler stop
```
The `--region` extension does **not** replace the existing `spark` command —
it works alongside it for targeted profiling.

## CRSThreadPool Thread Count Requirement

`SchedulerUtil.doesSupportRegionProfiler()`:
```java
if (scheduler instanceof AffinitySchedulerThreadPool) {
    return scheduler.getCoreThreads().length >= 2;  // < 2 → pinning would kill server
}
return false;  // only AFFINITY supports profiling
```

- **`>= 2` threads required** — with `< 2` threads, pinning one runner leaves
  no runner for other regions → deadlock. Region profiling is disabled.
- **AFFINITY scheduler only** — `EDF` and `WORK_STEALING` return false (no
  pinning support, `NullHandler`).
- **`-DCanvas.DisableRegionProfiler=true`** — system property to force-disable.

At boot, `SchedulerUtil.startScheduler()` logs "Region profiling marked as
supported in this environment" or "not supported". Check this to confirm.

## Pinned Region Fail-Fast Behavior

From `package-info.java` (Region Death section):

> Upon death of a region, we immediately fail-fast and kill the server. This
> should **NEVER** happen under any circumstances.

The fail-fast model is intentionally aggressive: profiling results are either
valid or the server halts — no undefined state in between. This catches bugs
quickly.

Additionally, `SchedulerUtil.decideScheduler` AFFINITY case installs an
`onException` handler: any uncaught exception in scheduler internals triggers
a crash report + `scheduler.halt()` + `MinecraftServer.stopServer()`.

## Region Split / Merge Repinning

Regions behave unpredictably due to player interaction. The profiled area is
kept loaded via `REGION_PROFILING_HOLD` tickets, but splits/merges can still
occur. Canvas hooks these via `SchedulerUtil.AffinityHandler`:

- **Split** (`onRegionSplit`): The original region is unpinned; the new region
  containing the center chunk (`RegionPinner.getCenter()`) is repinned.
  `tryTransferPinningState(from.handle, into.get(center).handle)` unlinks the
  old runner and links it to the new handle (`isSwapping = true`).
- **Merge** (`onRegionMerge`): Unpin `from`, repin `to` via
  `tryTransferPinningState(from.handle, to.handle)`.
- **Destroy / Inactive** (`onRegionDestroy` / `onRegionInactive`): Unlink the
  runner from the handle. (Destroy/inactive only happen as a result of
  split/merge.)

`gatherChunksToProfile()` stores the chunk list so the correct region can be
identified after a split by checking which new region contains those chunks.

## Spark Profiler Integration

- Canvas modifies `me.lucko.spark.paper.common.command.modules.SamplerModule`
  to add the `--region` argument
- `FoliaWorldInfoProvider` / `FoliaTickStatistics` — Spark plugins adapted for
  region threading (per-region tick stats)
- `RegionProfiler` — Canvas-original; manages profiling state, thread matching
- When pinned: Spark uses thread-name matching against the pinned
  `TickThreadRunner.getRunnerThread().getName()`
- When not pinned: Spark uses REGEX `"Region Scheduler Thread #\d+"`

## Finding the Code

```bash
# Spark profiler integration
grep -rl "spark\|Spark" canvas-server/src/main/java/io/canvasmc/canvas/spark/ 2>/dev/null

# Task pinning
grep -rl "RegionScheduleHandlePinner\|RegionProfiler" canvas-server/src/main/java/ 2>/dev/null

# Profiler support check
grep -rn "doesSupportRegionProfiler" canvas-server/src/main/java/io/canvasmc/canvas/tick/SchedulerUtil.java

# Watchdog
grep -rl "FoliaWatchdogThread\|watchdog" canvas-server/minecraft-patches/base/ 2>/dev/null

# Profiler removal
cat canvas-server/PROFILER_REMOVAL_README.MD
```

The `package-info.java` in `io.canvasmc.canvas.spark.profiler` is the
authoritative design document — read it first when modifying profiler code.

## When Modifying Profiler Code

1. **Read `package-info.java`** for the profiler package — it documents the design
2. **Vanilla profiler is removed** — don't add `Profiler.get().push(...)` calls; they won't compile (patch `0008`)
3. **Use Spark's API** for profiling hooks (grep current source for the API)
4. **Task pinning is opt-in** — don't enable it by default; it hurts performance
5. **Watchdog is Canvas's** — patch `0007` + `0009`; don't reference vanilla/Folia old watchdog code
6. **Fail-fast is intentional** — don't swallow errors in pinned region paths; let the server halt
7. **Concurrency** — use copy-on-write structures (`COWArrayList`), volatile refs for state; avoid explicit sync in hot paths

## Profiling a Region

1. Start dev server: `./gradlew runDev`
2. Confirm profiling support in console: "Region profiling marked as supported"
3. Start: `/spark profiler start --region ~ ~` (or with from/to coords)
4. Observe per-region tick times in Spark reports (the pinned thread's report)
5. Stop: `/spark profiler stop` — removes tickets, unlinks runner

## Verification

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew runDev
# Use Spark commands to profile, verify per-region timing works
# Confirm "Region profiling marked as supported" at boot (needs AFFINITY + >= 2 threads)
# Test split/merge: move around to trigger region changes during profiling
```

## Flame Graph Interpretation

Spark produces flame graphs (stack-sample based). Reading them for region
threading requires knowing which frames are overhead vs. real work.

### Reading a region-threading flame graph

- **X-axis** = sample count (width = time spent in that frame and its
  children); **Y-axis** = stack depth (caller at bottom, callee at top).
- **Width = cost** — a wide frame at any depth means significant time. Look
  for the widest frames at the top of the stack (the actual work) and at the
  bottom (the dispatch loop).
- **Pinned region** — when a region is pinned, the flame graph for that
  thread equals the pinned region's tick. Interpret it as per-region timing.
- **Unpinned (global)** — the flame graph aggregates all region scheduler
  threads; a wide frame may represent work across many regions.

### Key frame families

| Frame family | Meaning | Action if dominant |
|--------------|---------|--------------------|
| `Level.tick` / `Level.tickEntities` / `Level.tickBlockEntities` | Real tick work | Optimize the specific entity/TE type |
| `Entity.tick` / `<EntityType>.tick` | Per-entity tick | Reduce entity count or optimize that entity's logic |
| `BlockEntity` / `<TEType>.tick` | Tile entity tick | Reduce TEs or optimize TE logic |
| `io.canvasmc.canvas.tick.*` (poll, steal, link, unlink) | Scheduler overhead | Tune scheduler (see `/canvas-affinity-scheduler` → Performance Tuning) |
| `ChunkStatus.*` / `BalancedChunkSystem` | Chunk generation (async thread) | Tune chunk system (see `/canvas-chunk-system`) |
| `synchronized` / `ReentrantLock` frames | Lock contention | Reduce lock scope or eliminate cross-region locks |
| `Thread.onSpinWait` / `Thread.park` | Idle/waiting | Usually fine; if a tick thread is parked while regions are overloaded, work stealing may be disabled |

### Common misreads

- A wide `Level.tick` frame is **not** a bug — it's the tick doing its job.
  Drill into its children to find the expensive entity/TE.
- Scheduler overhead frames (`tick.*`) are expected in small amounts; only
  act if they dominate (> ~10% of the tick budget).
- Chunk-gen frames appear on `BalancedChunkSystem.WorkerThread`, not on
  region tick threads — don't confuse async gen cost with tick cost.

## Bottleneck Detection

Common bottleneck patterns and how to identify them from profiling data.

| Bottleneck | Flame graph signature | Fix |
|------------|----------------------|-----|
| Single expensive entity type | Wide `<EntityType>.tick` frame | Reduce count, optimize tick logic, or spread across regions |
| Tile entity explosion | Wide `BlockEntity` / `<TEType>` frame | Limit TEs per chunk, optimize TE tick |
| Lock contention | Wide `synchronized`/`ReentrantLock` frame on a tick thread | Narrow lock scope, use concurrent structures, eliminate cross-region locks |
| Scheduler overhead | Wide `tick.*` (poll/steal) frames | Tune `stealThresholdMillis`, `gridExponent`, thread count |
| Chunk gen starvation | Region tick threads idle, `BalancedChunkSystem` busy | Raise worker count, reduce gen demand (pre-gen, view distance) |
| Region imbalance | One pinned thread wide, others narrow | Players clustered — spread them, or lower `gridExponent` for more regions |
| Async I/O on tick thread | `Socket`/`File`/`DB` frames on a tick thread | Move I/O to `AsyncScheduler` |

### Isolating a bottleneck

1. **Pin the suspected hot region** — `/spark profiler start --region ~ ~`.
2. **Sample for 30–60s** under typical load.
3. **Read the flame graph** — find the widest top-level work frame.
4. **Drill down** — expand into children to find the specific entity/TE/lock.
5. **Cross-check** with `/spark health` (TPS, MSPT) and region deadline-miss
   logs.

## Profiling Data Export

Spark supports exporting profiling data for sharing and offline analysis.

### Export methods

- **Spark upload** — `/spark profiler stop` uploads the report to Spark's
  hosted viewer and returns a URL. Share the URL for review.
- **Raw export** — Spark can save the raw sample data locally; check
  `/spark profiler` subcommands (grep current Spark docs for the exact flag —
  it may shift between Spark versions).
- **Thread dump export** — `jstack <pid> > dump.txt` for lock/deadlock
  analysis alongside the Spark report.

### Sharing profiling data

- Include the **Spark URL** in the PR/issue when reporting a performance bug.
- Include the **server config** (`paper-global.yml` threaded-regions section)
  so reviewers can reproduce the scheduler setup.
- Note whether a region was **pinned** during profiling (affects
  interpretation — pinned = per-region, unpinned = aggregate).
- For region split/merge issues, include the console logs around the
  split/merge event.

### Privacy

- Spark uploads include stack traces and thread names — review for sensitive
  info (plugin names, internal package paths) before sharing publicly.
- Raw sample data may include world coordinates; redact if the server
  location is sensitive.

## Pitfalls

1. **No vanilla profiler** — patch `0008` removed it. Any code referencing `Profiler` won't compile.
2. **Task pinning is expensive** — only for active profiling, never in production default config.
3. **Watchdog is Canvas's** — patch `0007` + `0009`; don't mix with Folia's old watchdog.
4. **Per-region timing** — Spark reports are per-thread; pinning makes them per-region. Interpret accordingly.
5. **`< 2` threads disables profiling** — `doesSupportRegionProfiler()` returns false; pinning would deadlock.
6. **Only AFFINITY supports profiling** — `EDF` / `WORK_STEALING` get `NullHandler`; no pinning.
7. **Fail-fast on region death** — a pinned region dying halts the server by design; don't catch and continue.
8. **Max 512 chunks** — `RegionPinner` rejects areas larger than 512 chunks (`ERROR_TOO_MANY_CHUNKS`).
9. **Split/merge repinning** — profiling continues across region splits/merges via `tryTransferPinningState`; don't assume the handle stays the same.
