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
