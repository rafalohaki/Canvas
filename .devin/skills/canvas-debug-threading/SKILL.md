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

## Deadlock Analysis

Deadlocks in region threading usually involve a tick thread blocked on a
lock held by another tick thread (or an async task), or a pinned runner with
no other runner to steal work.

### Detecting a deadlock

1. **Watchdog fires** — `FoliaWatchdogThread` logs the hung thread + region
   and dumps its stack. A deadlock shows multiple threads BLOCKED on locks.
2. **Thread dump** — `jstack <pid>`; look for a **lock cycle**:
   - Thread A BLOCKED on lock L1 (held by Thread B)
   - Thread B BLOCKED on lock L2 (held by Thread A)
3. **All region threads BLOCKED** — if every `Region Scheduler Thread #N` is
   BLOCKED, the tick pool is fully deadlocked — the server is effectively hung.
4. **Pinned runner hang** — if profiling is active and the pinned region's
   tick hangs, Canvas fail-fasts (server halt) by design; this is not a
   recoverable deadlock.

### Diagnosing the lock cycle

```bash
jstack <pid> > dump.txt
# Find BLOCKED threads and their lock owners
grep -B2 -A15 "BLOCKED" dump.txt
# Match "waiting to lock <0x...>" with "locked <0x...>" in another thread
```

Each `jstack` entry shows `- waiting to lock <0xADDR>` and the lock's owner
thread id. Trace the cycle: A→B→C→A.

### Common deadlock causes in Canvas

| Cause | Pattern | Fix |
|-------|---------|-----|
| Lock across regions | Region A's tick acquires lock L, then schedules on region B (blocks waiting for B's tick) which needs L | Never hold a cross-region lock while scheduling on another region; release before scheduling |
| `scheduleLock` held during tick | `AffinitySchedulerThreadPool.scheduleLock` held while a tick runs | Don't hold `scheduleLock` during tick execution (Canvas doesn't; verify your additions) |
| Pinned runner + 1 thread | Profiling pinned the only runner; no runner left for other regions | `doesSupportRegionProfiler()` requires `>= 2` threads; don't override |
| Sync I/O on tick thread | Tick thread blocks on DB/HTTP holding an implicit region lock | Move I/O to `AsyncScheduler` |
| `Object.wait()` on tick thread | Tick thread waits for a notify that never comes | Use scheduler-based delays, not `wait()` |

### Fix pattern

Break the cycle by removing one lock dependency. Prefer:
- **No cross-region locks** — pass data via schedulers/queues (see
  `/canvas-region-threading` → Cross-Region Communication), not shared locks.
- **Lock ordering** — if a lock is unavoidable, acquire locks in a consistent
  global order across all threads.
- **Timeouts** — use `tryLock(timeout)` instead of `lock()` so a stuck thread
  logs and recovers instead of hanging forever.

## Race Condition Detection

Races in Canvas usually mean wrong-thread access to region-owned data or
shared mutable state touched by multiple tick threads without synchronization.

### Patterns for finding races

1. **Set `guardSeverity: THROW`** — surfaces wrong-thread access immediately
   with a stack trace. `SILENT`/`LOG` hide races.
2. **Add `TickGuard.guard(...)` / `ensureTickThread`** at suspected access
   points — the throw pinpoints the offender.
3. **Stress with boundary crossings** — many races only trigger when a region
   splits/merges or an entity crosses a boundary. Load-test with movement
   (see `/canvas-chunk-system` → Load Testing).
4. **`ConcurrentModificationException`** — a shared collection mutated by two
   threads. Identify the collection, find all access points, determine which
   threads. If both are tick threads on different regions, the collection
   should be region-local, not shared.
5. **Silent corruption** — duplicated items, desynced blocks, vanished
   entities. Set `THROW`, add assertions, run until it throws.

### Tools (ThreadSanitizer equivalent)

The JVM has no direct ThreadSanitizer, but these help:

- **`TickGuard` + `THROW` severity** — the primary race detector for
  region-ownership violations. It's a runtime assertion, not a static analyzer.
- **`VarHandle` opaque/volatile semantics** — `TickThreadRunner` uses
  `setOpaque`/`setVolatile` for state transitions. If you add shared state,
  use the correct memory ordering; a missing volatile is a race.
- **JCIP annotations (`@GuardedBy`, `@Immutable`)** — grep the source for
  existing usage; follow the same discipline for new shared state.
- **`jstack` under load** — repeated thread dumps during stress can reveal
  threads interleaving on shared state (two threads in the same synchronized
  block at different times).
- **Java Flight Recorder (JFR)** — `java -XX:StartFlightRecording=...` can
  reveal lock contention and allocation hotspots that hint at races.
- **Static analysis** — SpotBugs / SonarQube can flag unsynchronized shared
  field access; run them on Canvas source if available.

### Race-prone constructs to audit

- Shared `Map`/`List` across regions (use `ConcurrentHashMap` /
  `COWArrayList` or make it region-local).
- `volatile` without immutable payload (visibility ≠ thread-safety for
  mutable contents).
- Double-checked locking without `volatile`.
- Caching `Entity`/`World`/region references across ticks (they move).

## Watchdog Tuning

`FoliaWatchdogThread` (patch `0007`) monitors region tick threads. Tuning
its thresholds per workload prevents both false alarms and missed hangs.

### Configuration

```bash
grep -rn "watchdog\|Watchdog" canvas-server/src/minecraft/java/ 2>/dev/null
grep -rn "watchdog" canvas-server/minecraft-patches/base/0007-*.patch
```

Find the timeout config key in `paper-global.yml` (grep current source — the
key name may shift between versions).

### Threshold guidance by workload

| Workload | Timeout | Rationale |
|----------|---------|-----------|
| Default survival server | Default (grep source) | Catches true hangs without false alarms on heavy ticks |
| Heavy-tick server (large farms, many entities) | Raise it | Legitimate ticks may exceed default; avoid false watchdog dumps |
| Low-population / testing | Lower it | Catches bugs faster in dev; false alarms are acceptable |
| Profiling active (pinned region) | Keep default | A pinned-region hang triggers fail-fast (server halt), not just a watchdog log — don't raise it to mask real hangs |

### What the watchdog does (and doesn't)

- **Does**: log a warning + dump the hung thread's stack when a region tick
  exceeds the timeout.
- **Does NOT** always kill the server — it logs and may continue. A hung
  thread that never recovers will eventually block all regions (if work
  stealing is disabled) or degrade throughput.
- **Pinned region hang** → fail-fast server halt (by design), not just a
  watchdog log. Don't suppress this.

### Tuning steps

1. Grep the current config key + default value.
2. Run your typical workload; if watchdog fires on legitimate heavy ticks,
   raise the threshold.
3. If it never fires but you suspect hangs, lower it temporarily to surface
   them.
4. Pair with `overloadedLogMillis` (region scheduler config) — that catches
   deadline misses before they become full watchdog timeouts.

## Pitfalls

1. **Intermittent bugs** — region boundaries shift; a bug may only trigger when a player crosses a boundary. Test with movement.
2. **No exception ≠ safe** — unguarded off-thread access may silently corrupt. Add `TickGuard.guard(...)` / `ensureTickThread` assertions. Set `guardSeverity: THROW`.
3. **Watchdog ≠ crash** — watchdog logs but doesn't always kill; check console carefully for `Folia Watchdog Thread` messages.
4. **Thread names change** — don't hardcode thread name checks; use `TickThread.isTickThreadFor(...)`.
5. **`SILENT` hides bugs** — `guardSeverity: SILENT` suppresses region checks; never use in production.
6. **Pinned region hang = fail-fast** — if profiling is active and the pinned region hangs, the server halts (by design).
7. **`cancel()` unsupported** — AFFINITY/StealingQueue tasks throw on cancel; design tasks to be non-cancellable.
