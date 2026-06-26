---
name: canvas-debug-threading
description: Use whenever debugging Canvas region threading bugs — IllegalStateException from wrong-thread access, watchdog timeouts, region tick hangs, data corruption from races, ConcurrentModificationException from wrong-thread access, scheduler misuse patterns, or thread dump analysis for region threads. Triggers on "IllegalStateException", "wrong thread", "threading bug", "watchdog", "region hang", "data race", "tick thread", "debug threading", "region crash", "ConcurrentModification", "TickGuard", "ensureTickThread", "FoliaWatchdogThread", "thread dump".
triggers:
  - user
  - model
subagent: true
argument-hint: "[error-type]"
allowed-tools:
  - read
  - grep
  - glob
  - exec
---

# Canvas Debug Threading

Debug region threading violations, watchdog timeouts, race conditions, and
scheduler misuse in Canvas.

Sources: DeepWiki `CraftCanvasMC/Canvas` (Region Threading, Watchdog);
local `io.canvasmc.canvas.util.TickGuard`,
`io.papermc.paper.threadedregions.FoliaWatchdogThread` (patch `0007`),
`io.canvasmc.canvas.tick.SchedulerUtil`.

## Common Symptoms & Root Causes

### `IllegalStateException` from `ensureTickThread` / `TickGuard`

**Cause**: Accessing region-owned data from the wrong thread. The exception
reason string identifies the guard point.

**Guard sources**:
- `TickThread.ensureTickThread(level, chunkX, chunkZ, reason)` — direct throw
- `TickGuard.guard(chunkX, chunkZ, level, reason)` — severity-controlled
  (`THROW` default, `LOG`, `SILENT`)
- `ServerRegionTickManager.ensureScheduleHandle(handle, reason)` — wrong
  schedule handle
- `RegionizedServer.ensureGlobalTickThread(reason)` — not on global tick thread

**Find the violation**:
```bash
# The stack trace shows the offending call. Trace back to:
# 1. What thread are we on? (Thread.currentThread().getName())
# 2. What region owns the data? (TickThread.isTickThreadFor(level, x, z))
# 3. Why wasn't it scheduled on the right scheduler?
```

**Fix**: Wrap the access in the correct scheduler (`RegionScheduler` /
`EntityScheduler` / `GlobalRegionScheduler`). If the call site is uncertain,
add `TickGuard.guard(...)` or `TickThread.ensureTickThread(...)` at the entry.

**Tip**: If `guardSeverity = LOG` or `SILENT`, violations may not throw —
temporarily set `THROW` in `paper-global.yml` to surface them.

### Watchdog timeout / region tick hang

**Cause**: A region's tick is taking too long (infinite loop, blocking I/O,
lock contention, deadlocked tick thread).

**Canvas watchdog**: `FoliaWatchdogThread` (patch `0007`) — monitors region
tick threads. `RunningTick` records tick start + handle + thread; on timeout
it calls `WatchdogThread.dumpThread(...)` to log the stack.

**Debug**:
```bash
./gradlew runDev
# Watch console for watchdog messages — they identify the hung thread + region
# Get a thread dump: kill -3 <pid> (or jstack <pid>)
```

**Fix**: Find the blocking call in the stack trace, move it to
`AsyncScheduler` or optimize. Common blockers: synchronous DB queries, HTTP
calls, `Thread.sleep`, lock acquisition across regions.

### `ConcurrentModificationException`

**Cause**: Two threads modifying a shared collection without synchronization.
In Canvas this usually means wrong-thread access to a region-owned collection
(entity lists, TE lists, chunk collections).

**Debug**: Identify the collection, find all access points, determine which
threads. If both access points are on tick threads, they're likely on
different regions sharing a collection that should be region-local.

**Fix**: Synchronize access, use concurrent collections (`COWArrayList` —
Canvas uses this extensively), or ensure single-region ownership. Don't share
mutable region data across regions.

### Silent data corruption (no exception)

**Cause**: Off-thread write to region data that isn't guarded by
`ensureTickThread` / `TickGuard` (or `guardSeverity = SILENT`).

**Hardest to debug** — no exception, just wrong behavior (duplicated items,
desynced blocks, vanished entities).

**Debug**:
1. Set `guardSeverity: THROW` in `paper-global.yml`
2. Add `TickThread.ensureTickThread(...)` assertions at suspected access points
3. Run until it throws — the stack trace reveals the offender

### Scheduler misuse patterns

| Pattern | Symptom | Fix |
|---------|---------|-----|
| `Bukkit.getScheduler().runTask(...)` | `UnsupportedOperationException` / does not exist | Use `RegionScheduler` / `EntityScheduler` / `GlobalRegionScheduler` |
| `RegionScheduler` for entity work | Entity moved to another region; wrong thread | Use `EntityScheduler` — follows entity |
| `AsyncScheduler` accessing world | `IllegalStateException` or silent corruption | Schedule on `RegionScheduler` for that location |
| Cached entity reference used off-thread | Entity in different region now | Use `EntityScheduler`; never cache entity + use async |
| Assuming `Bukkit.isPrimaryThread()` | Always false; logic never runs | Remove the check; always schedule correctly |
| `cancel()` on AFFINITY/StealingQueue task | `UnsupportedOperationException` | Tasks aren't cancellable; design around it |

## Debugging Workflow

1. **Reproduce reliably** — find the action that triggers the bug
2. **Read the stack trace** — what thread, what method, what data
3. **Identify the region** — `TickThread.isTickThreadFor(level, chunkX, chunkZ)`
4. **Trace the call path** — how did we get here? async? wrong scheduler? cached reference?
5. **Add assertions** — `TickGuard.guard(...)` / `ensureTickThread` at entry points to catch it earlier
6. **Fix the scheduling** — use the correct scheduler, not direct access
7. **Verify**: `./gradlew runDev`, reproduce the scenario, confirm fix

## Finding the Offending Code

```bash
# Search for direct world/entity access from potentially-async contexts
grep -rn "world\.\|level\.\|entity\." canvas-server/src/minecraft/java/ | grep -i "async\|runAsync\|CompletableFuture"

# Find missing ensureTickThread / TickGuard guards
grep -rn "ensureTickThread\|TickGuard" canvas-server/src/minecraft/java/ | wc -l
# Compare with total region-data access points — gaps are suspect

# Check for legacy scheduler calls (should not exist)
grep -rn "Bukkit\.getScheduler\|getScheduler\(\)\.runTask" canvas-server/src/minecraft/java/

# Find TickGuard usage and severity config
grep -rn "TickGuard\|guardSeverity" canvas-server/src/main/java/io/canvasmc/canvas/
```

## Thread Dump Analysis

```bash
# Get PID
jps | grep -i canvas

# Thread dump
jstack <pid> > thread-dump.txt

# Look for:
# - Region tick threads (named "Region Scheduler Thread #N")
# - BLOCKED/WAITING threads (lock contention)
# - Stack traces in Canvas packages (io.canvasmc.*)
grep -A 20 "io.canvasmc" thread-dump.txt

# Identify which region a thread is ticking
grep -B 5 "io.canvasmc.canvas.tick" thread-dump.txt
```

Region tick threads are named `Region Scheduler Thread #N` (AFFINITY) or
similar. The `TickThreadRunner` id maps to the thread. Use
`AffinitySchedulerThreadPool.getCurrentTickThreadRunner()` to find the runner
for the current thread at runtime.

## Watchdog Configuration

`FoliaWatchdogThread` (patch `0007`) monitors region tick threads. If a
region's tick exceeds the timeout, it logs a warning + dumps the thread stack.

```bash
# Find watchdog config keys
grep -rn "watchdog\|Watchdog" canvas-server/src/minecraft/java/ 2>/dev/null
grep -rn "watchdog" canvas-server/minecraft-patches/base/0007-Add-watchdog-thread.patch
```

The watchdog does **not** always kill the server — it logs and may continue.
Check console carefully for `Folia Watchdog Thread` messages. A hung tick
thread that never recovers will eventually block all regions (if work stealing
is disabled) or degrade throughput.

## Debug Logging Techniques

- **`TickGuard` with `LOG` severity** — surfaces region mismatches without
  crashing; useful in staging. Set `guardSeverity: LOG` in `paper-global.yml`.
- **`ScheduledHandleTickState.tickStart`** — logs "missed deadline" warnings
  when `overloadedLogMillis` exceeded; tune that value to catch overload early.
- **`SchedulerUtil.startScheduler()`** — logs "Region profiling marked as
  supported" / "not supported" at boot; confirms scheduler type + thread count.
- **`RegionProfiler.STATE`** — volatile reference to current profiling state;
  check at runtime to confirm pinning is active.
- Add temporary `LOGGER.warn` at suspected race points with
  `TickThread.getThreadContext()` + `getThreadContext()` to log thread + region.

## Region Tick Hang Diagnosis

1. **Check watchdog output** — identifies the hung thread + its region
2. **Thread dump** — look for the `Region Scheduler Thread` in `BLOCKED` state
3. **Stack trace** — find the blocking call (I/O, lock, loop)
4. **Is it pinned?** — if profiling is active, the pinned runner can't steal
   other work; a hang in a pinned region triggers fail-fast (server halt)
5. **Work stealing disabled?** — `enableWorkStealing: false` means one hung
   thread blocks its local queue entirely
6. **Fix** — move blocking work to `AsyncScheduler`, or reduce tick work

## Data Race Detection

- **`COWArrayList`** — Canvas uses copy-on-write for shared read-heavy state;
  if you add shared mutable state, prefer `COWArrayList` or `ConcurrentHashMap`
- **Volatile references** — profiler state uses volatile refs for visibility
  without explicit sync (`RegionProfiler.STATE`)
- **`VarHandle`** — `TickThreadRunner` uses `setVolatile`/`setOpaque` for state
  transitions; respect the memory ordering when adding new state
- **`scheduleLock`** — `AffinitySchedulerThreadPool` synchronizes on
  `scheduleLock` for task insert/link; don't hold it during tick execution

## Common Bug Patterns

### Pattern: Cached entity reference used off-thread
```java
// BUG: entity cached, used later from async
Entity cached = entity;
Bukkit.getAsyncScheduler().runNow(plugin, t -> {
    cached.teleport(...);  // WRONG — entity may be in a different region now
});
```
**Fix**: Use `EntityScheduler` — it follows the entity.

### Pattern: Block access from async
```java
// BUG
Bukkit.getAsyncScheduler().runNow(plugin, t -> {
    world.getBlockAt(x, y, z);  // WRONG — world data is region-owned
});
```
**Fix**: Schedule on `RegionScheduler` for that location.

### Pattern: Assuming main thread
```java
// BUG — there is no main thread in Canvas
if (Bukkit.isPrimaryThread()) { ... }  // always false
```
**Fix**: Remove the check; always schedule correctly.

### Pattern: Region data access from chunk gen callback
```java
// BUG — chunk gen runs on BalancedChunkSystem.WorkerThread, not a tick thread
level.getChunkSource().getChunkState(...).thenRun(() -> {
    entity.setPos(...);  // WRONG — not on the owning region's tick thread
});
```
**Fix**: Schedule the callback onto `RegionScheduler` /
`EntityScheduler` for the target location/entity.

## Verification After Fix

```bash
./gradlew applyAllPatches --no-configuration-cache
./gradlew :canvas-server:compileJava
./gradlew runDev
# Reproduce the original scenario — confirm no exception/corruption
# Run for extended time to catch intermittent races
# Test with player movement across region boundaries
```

## Pitfalls

1. **Intermittent bugs** — region boundaries shift; a bug may only trigger when a player crosses a boundary. Test with movement.
2. **No exception ≠ safe** — unguarded off-thread access may silently corrupt. Add `TickGuard.guard(...)` / `ensureTickThread` assertions. Set `guardSeverity: THROW`.
3. **Watchdog ≠ crash** — watchdog logs but doesn't always kill; check console carefully for `Folia Watchdog Thread` messages.
4. **Thread names change** — don't hardcode thread name checks; use `TickThread.isTickThreadFor(...)`.
5. **`SILENT` hides bugs** — `guardSeverity: SILENT` suppresses region checks; never use in production.
6. **Pinned region hang = fail-fast** — if profiling is active and the pinned region hangs, the server halts (by design).
7. **`cancel()` unsupported** — AFFINITY/StealingQueue tasks throw on cancel; design tasks to be non-cancellable.
